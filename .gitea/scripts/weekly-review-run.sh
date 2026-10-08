#!/usr/bin/env bash
# Everything the weekly-release-review.yml workflow runs on the runner, one subcommand per step:
#
#   weekly-review-run.sh prepare   clone the repository, pick the latest release/hotfix branch, list its commits
#   weekly-review-run.sh sandbox   review every commit in the isolated container and write a fix for the ones with findings
#   weekly-review-run.sh open-pr   validate the fixes and open one draft pull request per branch (the only step that can push)
#   weekly-review-run.sh notify    send the opened pull requests to Telegram
#
# Run as `bash .gitea/scripts/weekly-review-run.sh <subcommand>`. It can also be sourced to reach the
# functions below directly, which is how the local tests drive them.
#
# Shape of one run: for the branch, each commit of the last week gets its own review session; a commit
# with findings at or above the threshold gets its own fix session; every fix becomes one commit of one
# pull request into that branch. The model works in the sandbox with no token and no route to Gitea;
# what crosses to this side is a patch per commit, and each patch is judged by triage-tools.py
# check-patch before anything is pushed.
#
# Expects from the job env: GITEA_HOST, GITEA_TOKEN. Optional: WEEKLY_ORG (default ONLYOFFICE),
# WEEKLY_REPO (default DocSpace-buildtools), WEEKLY_BRANCHES (comma-separated, default: the
# release/* or hotfix/* branch with the highest version number), WEEKLY_SINCE_DAYS (empty: from the end of the previous review of the branch, WEEKLY_FALLBACK_DAYS=7 days
# when there is none; a number fixes the window), WEEKLY_MAX_WINDOW_DAYS (35, the longest an anchored window
# may get), WEEKLY_WINDOW_MARGIN_MINUTES (120, overlap kept between two windows), WEEKLY_MAX_COMMITS (0 = every commit),
# WEEKLY_LARGE_COMMIT_LINES (2000, from there a review gets a bigger budget and timeout), WEEKLY_EXCLUDE_REF (commits reachable from it are not reviewed),
# WEEKLY_MIN_SEVERITY (medium), WEEKLY_MIN_CONFIDENCE (likely), WEEKLY_TOTAL_BUDGET_USD (60),
# WEEKLY_DRY_RUN ("true" validates everything and pushes nothing), WEEKLY_MAX_OPEN (1, open pull
# requests of this pipeline per base branch), WEEKLY_DEADLINE_MINUTES (220, no new commit is started
# after this long into the sandbox step, so the job timeout never kills a run that has results).

set -euo pipefail

WEEKLY_ORG="${WEEKLY_ORG:-ONLYOFFICE}"
WEEKLY_REPO="${WEEKLY_REPO:-DocSpace-buildtools}"
WEEKLY_SINCE_DAYS="${WEEKLY_SINCE_DAYS:-}"
WEEKLY_FALLBACK_DAYS="${WEEKLY_FALLBACK_DAYS:-7}"
WEEKLY_MAX_WINDOW_DAYS="${WEEKLY_MAX_WINDOW_DAYS:-35}"
WEEKLY_WINDOW_MARGIN_MINUTES="${WEEKLY_WINDOW_MARGIN_MINUTES:-120}"
WEEKLY_MAX_COMMITS="${WEEKLY_MAX_COMMITS:-0}"
WEEKLY_LARGE_COMMIT_LINES="${WEEKLY_LARGE_COMMIT_LINES:-2000}"
WEEKLY_MIN_SEVERITY="${WEEKLY_MIN_SEVERITY:-medium}"
WEEKLY_MIN_CONFIDENCE="${WEEKLY_MIN_CONFIDENCE:-likely}"
WEEKLY_TOTAL_BUDGET_USD="${WEEKLY_TOTAL_BUDGET_USD:-60}"
WEEKLY_MAX_OPEN="${WEEKLY_MAX_OPEN:-1}"
WEEKLY_DEADLINE_MINUTES="${WEEKLY_DEADLINE_MINUTES:-220}"
WEEKLY_BRANCH_PREFIX="claude-weekly/"
WEEKLY_GIT_NAME="${WEEKLY_GIT_NAME:-Claude Weekly Review}"
WEEKLY_GIT_EMAIL="${WEEKLY_GIT_EMAIL:-claude-weekly@noreply.${GITEA_HOST:-localhost}}"
WORK_DIR="work"

# Caps by characters, not bytes: bash's own ${var:0:n} slices bytes under a non-UTF-8 locale, which
# halves the cap and can sever a codepoint mid-sequence on this org's routinely-Cyrillic commit text.
_trim_chars() {
  python3 -c 'import sys
limit = int(sys.argv[1])
text = sys.stdin.buffer.read().decode("utf-8", "replace")[:limit]
sys.stdout.buffer.write(text.encode("utf-8"))' "$1"
}

# Commit text reaching an LLM prompt or a shell variable: same pipeline as the triage and review sides.
_sanitize() {
  # Drop newlines, backticks and dollars so the value cannot steer envsubst or the shell, cap by
  # characters, and escape & < > last so a cap can never leave a dangling entity.
  printf '%s' "$1" | tr '\n\r\t`$' '     ' | tr -s ' ' | _trim_chars "${2:-200}" \
    | sed 's/^ *//; s/ *$//; s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

_weekly_api() {
  local METHOD="$1" API_PATH="$2"
  shift 2
  curl -s --max-time 30 -X "$METHOD" -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" "https://$GITEA_HOST/api/v1$API_PATH" "$@"
}

_clone_url() {
  echo "${WEEKLY_CLONE_URL:-https://$GITEA_HOST/$WEEKLY_ORG/$WEEKLY_REPO}"
}

# One line per problem, appended: several stages can each have something a person should hear.
_weekly_notice() {
  echo "$1" >> pipeline-notice.txt
}

# A quiet week is the normal case, not a problem: the run ends green with the reason stated, and no
# notice is written, since a weekly "nothing happened" message would train everybody to ignore them.
_skip_run() {
  echo "::notice::Nothing to review: $1"
  echo "$1" > weekly-skip-reason.txt
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "skip=true" >> "$GITHUB_OUTPUT"
  return 0
}

# ============================================================================
# Prepare
# ============================================================================

# Prints the number of an open pull request of this pipeline into $1, or nothing. Returns 1 when the
# answer is unknown: an unreadable listing refuses rather than passes, so a second proposal for one
# branch cannot appear just because the API had a bad moment.
_open_weekly_pr() {
  local BASE="$1" PAGE=1 PAGE_JSON FOUND
  while [ "$PAGE" -le 10 ]; do
    PAGE_JSON=$(_weekly_api GET "/repos/$WEEKLY_ORG/$WEEKLY_REPO/pulls?state=open&limit=50&page=$PAGE" || true)
    jq -e 'type == "array"' <<< "$PAGE_JSON" > /dev/null 2>&1 || return 1
    [ "$(jq 'length' <<< "$PAGE_JSON")" = "0" ] && return 0
    FOUND=$(jq -r --arg prefix "$WEEKLY_BRANCH_PREFIX" --arg base "$BASE" \
      '[.[] | select((.head.ref // "" | startswith($prefix)) and (.base.ref // "") == $base)] | length' <<< "$PAGE_JSON")
    if [ "$FOUND" -ge "$WEEKLY_MAX_OPEN" ]; then
      echo "$FOUND"
      return 0
    fi
    PAGE=$((PAGE + 1))
  done
  return 1
}

# The newest pull request of this pipeline into BASE, whatever its state, as {number, created_at, body}.
# Prints nothing when there is none; returns 1 when the listing cannot be read.
_latest_weekly_pr() {
  local BASE="$1" PAGE=1 PAGE_JSON MATCHES="[]"
  while [ "$PAGE" -le 5 ]; do
    PAGE_JSON=$(_weekly_api GET "/repos/$WEEKLY_ORG/$WEEKLY_REPO/pulls?state=all&limit=50&page=$PAGE" || true)
    jq -e 'type == "array"' <<< "$PAGE_JSON" > /dev/null 2>&1 || return 1
    [ "$(jq 'length' <<< "$PAGE_JSON")" = "0" ] && break
    MATCHES=$(jq -c --argjson found "$MATCHES" --arg prefix "$WEEKLY_BRANCH_PREFIX" --arg base "$BASE" \
      '$found + [.[] | select((.head.ref // "" | startswith($prefix)) and (.base.ref // "") == $base) | {number, created_at, body: (.body // "")}]' <<< "$PAGE_JSON")
    PAGE=$((PAGE + 1))
  done
  jq -c 'sort_by(.created_at) | last // empty' <<< "$MATCHES"
}

# Every comment of a pull request as one JSON array; returns 1 when they cannot be read.
_pr_comments() {
  local NUMBER="$1" PAGE=1 ALL="[]" PAGE_JSON
  while [ "$PAGE" -le 10 ]; do
    PAGE_JSON=$(_weekly_api GET "/repos/$WEEKLY_ORG/$WEEKLY_REPO/issues/$NUMBER/comments?limit=50&page=$PAGE" || true)
    jq -e 'type == "array"' <<< "$PAGE_JSON" > /dev/null 2>&1 || return 1
    ALL=$(jq -c --argjson found "$ALL" '$found + .' <<< "$PAGE_JSON")
    [ "$(jq 'length' <<< "$PAGE_JSON")" -lt 50 ] && break
    PAGE=$((PAGE + 1))
  done
  printf '%s' "$ALL"
}

# The newest window-end timestamp among the markers in the text on stdin.
_newest_window_marker() {
  grep -oE 'weekly-review-window-end:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | sed 's/^weekly-review-window-end://' | sort | tail -n 1 || true
}

# Where the previous review of BASE ended: the marker in the body of the newest pull request of this pipeline
# or in the comment a later run left on it when it had nothing to propose. Prints nothing when there is no such
# pull request; returns 1 when the API cannot be read.
_window_anchor() {
  local LATEST NUMBER TEXT COMMENTS
  LATEST=$(_latest_weekly_pr "$1") || return 1
  [ -n "$LATEST" ] || return 0
  NUMBER=$(jq -r '.number' <<< "$LATEST")
  [[ "$NUMBER" =~ ^[0-9]+$ ]] || return 0
  TEXT=$(jq -r '.body' <<< "$LATEST")
  COMMENTS=$(_pr_comments "$NUMBER") || return 1
  TEXT+=$'\n'"$(jq -r '.[].body // ""' <<< "$COMMENTS")"
  _newest_window_marker <<< "$TEXT"
}

# Sets WINDOW_SINCE (a git --since value) and WINDOW_TEXT (the same, for people) for one branch. A fixed
# since_days always wins; otherwise the window starts where the previous review ended, so a week held back
# by an open pull request, a failed run or a late cron is picked up by the next run instead of being lost.
_choose_window() {
  local BRANCH="$1" ANCHOR="" ANCHOR_EPOCH NOW_EPOCH
  if [ -n "$WEEKLY_SINCE_DAYS" ]; then
    WINDOW_SINCE="$WEEKLY_SINCE_DAYS days ago"
    WINDOW_TEXT="of the last $WEEKLY_SINCE_DAYS days"
    return 0
  fi
  if ! ANCHOR=$(_window_anchor "$BRANCH"); then
    echo "::warning::Could not read where the previous review of $BRANCH ended - using the last $WEEKLY_FALLBACK_DAYS days"
    ANCHOR=""
  fi
  NOW_EPOCH=$(date -u +%s)
  # A marker in the future is ignored: anyone who can comment could plant one to suppress the next review.
  if [ -n "$ANCHOR" ] && ANCHOR_EPOCH=$(date -u -d "$ANCHOR" +%s 2> /dev/null) && [ "$ANCHOR_EPOCH" -le "$NOW_EPOCH" ]; then
    if [ $((NOW_EPOCH - ANCHOR_EPOCH)) -gt $((WEEKLY_MAX_WINDOW_DAYS * 86400)) ]; then
      WINDOW_SINCE="$WEEKLY_MAX_WINDOW_DAYS days ago"
      WINDOW_TEXT="of the last $WEEKLY_MAX_WINDOW_DAYS days (the previous review, $ANCHOR, is older than that)"
      _weekly_notice "weekly review of $BRANCH: the previous review ended $ANCHOR, more than $WEEKLY_MAX_WINDOW_DAYS days ago - only the last $WEEKLY_MAX_WINDOW_DAYS days are reviewed"
    else
      WINDOW_SINCE="$ANCHOR"
      WINDOW_TEXT="since $ANCHOR (the end of the previous review)"
    fi
  else
    WINDOW_SINCE="$WEEKLY_FALLBACK_DAYS days ago"
    WINDOW_TEXT="of the last $WEEKLY_FALLBACK_DAYS days"
  fi
}

# The latest release/* or hotfix/* branch of the clone, or the ones the operator named.
_list_candidate_branches() {
  local SRC="$1" BRANCH
  if [ -n "${WEEKLY_BRANCHES:-}" ]; then
    while IFS= read -r BRANCH; do
      [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "::warning::Ignoring branch name '$BRANCH'"; continue; }
      git -C "$SRC" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" > /dev/null \
        && echo "$BRANCH" || echo "::warning::Branch $BRANCH does not exist in $WEEKLY_REPO" >&2
    done < <(tr ',' '\n' <<< "$WEEKLY_BRANCHES" | sed 's/^ *//; s/ *$//' | grep -v '^$' || true)
    return 0
  fi
  # Only the branch with the highest version number: older release lines are no longer being worked on.
  # A hotfix wins a tie with a release of the same version. The version must open the name and be dotted
  # (v4.0.0, 4.0.1-rc1): a number anywhere else (hotfix/bug-12345, release/2026-q4) is not a version.
  local VERSION RANK
  while IFS= read -r BRANCH; do
    VERSION=""
    [[ "${BRANCH#*/}" =~ ^v?([0-9]+(\.[0-9]+)+) ]] && VERSION="${BASH_REMATCH[1]}"
    [ -n "$VERSION" ] || continue
    RANK=0
    [ "${BRANCH%%/*}" = "hotfix" ] && RANK=1
    printf '%s\t%s\t%s\n' "$VERSION" "$RANK" "$BRANCH"
  done < <(git -C "$SRC" for-each-ref --format='%(refname:lstrip=3)' 'refs/remotes/origin/release' 'refs/remotes/origin/hotfix' \
             | grep -E '^(release|hotfix)/[A-Za-z0-9._/-]+$' || true) \
    | sort -t$'\t' -k1,1V -k2,2n | tail -n 1 | cut -f3
}

# Writes one commit's row to commits.tsv, or its reason to skipped.tsv. Returns 0 either way.
_triage_commit() {
  local SRC="$1" SHA="$2" AUTHOR_EMAIL="$3" AUTHOR_NAME="$4" SUBJECT="$5" BRANCH_DIR="$6"
  local REASON="" LINES RAW SAFE_SUBJECT
  SAFE_SUBJECT=$(_sanitize "$SUBJECT" 150)
  if [ "$AUTHOR_EMAIL" = "$WEEKLY_GIT_EMAIL" ]; then
    REASON="written by this pipeline"
  elif [[ "$SUBJECT" == "Weekly review fixes for "* || "$SUBJECT" == "WIP: Weekly review fixes for "* ]]; then
    # A squash merge takes its author from whoever opened the pull request, not from the fix commits.
    REASON="the merge of this pipeline's own pull request"
  elif [ "$(git -C "$SRC" rev-list --parents -n 1 "$SHA" | wc -w | tr -d ' ')" -lt 2 ]; then
    REASON="the root commit has nothing to compare with"
  else
    # The size never skips a commit: a large one is reviewed in full, with a bigger budget (review_one_commit).
    LINES=$(git -C "$SRC" show --numstat --format= "$SHA" | awk '$1 ~ /^[0-9]+$/ { total += $1 + $2 } END { print total + 0 }')
    RAW=$(git -C "$SRC" diff-tree -r --raw --no-commit-id "$SHA")
    if [ -n "$RAW" ] && ! grep -qvE '^:160000 160000 ' <<< "$RAW"; then
      REASON="only submodule pointers changed"
    fi
  fi
  if [ -n "$REASON" ]; then
    printf '%s\t%s\t%s\n' "$SHA" "$REASON" "$SAFE_SUBJECT" >> "$BRANCH_DIR/skipped.tsv"
  else
    printf '%s\t%s\t%s\t%s\n' "$SHA" "$(_sanitize "$AUTHOR_NAME" 80)" "$SAFE_SUBJECT" "${LINES:-0}" >> "$BRANCH_DIR/commits.tsv"
  fi
  return 0
}

prepare_weekly_context() {
  [[ "$WEEKLY_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::Invalid repository name '$WEEKLY_REPO'"; return 1; }
  [[ -z "$WEEKLY_SINCE_DAYS" || "$WEEKLY_SINCE_DAYS" =~ ^[0-9]{1,3}$ ]] || { echo "::error::since_days must be empty or a number, got '$WEEKLY_SINCE_DAYS'"; return 1; }
  [[ "$WEEKLY_FALLBACK_DAYS" =~ ^[0-9]{1,3}$ && "$WEEKLY_MAX_WINDOW_DAYS" =~ ^[0-9]{1,3}$ && "$WEEKLY_WINDOW_MARGIN_MINUTES" =~ ^[0-9]{1,4}$ ]] \
    || { echo "::error::The window settings must be numbers"; return 1; }
  [[ "$WEEKLY_MAX_COMMITS" =~ ^[0-9]{1,3}$ ]] || { echo "::error::max_commits must be a number, got '$WEEKLY_MAX_COMMITS'"; return 1; }
  [[ "$WEEKLY_LARGE_COMMIT_LINES" =~ ^[0-9]{1,6}$ ]] || { echo "::error::large_commit_lines must be a number, got '$WEEKLY_LARGE_COMMIT_LINES'"; return 1; }
  # An unparsable budget reads as 0 in awk and would silently review nothing, so it is refused up front.
  [[ "$WEEKLY_TOTAL_BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "::error::total_budget_usd must be a number like 60 or 12.5, got '$WEEKLY_TOTAL_BUDGET_USD'"; return 1; }
  [[ "$WEEKLY_DEADLINE_MINUTES" =~ ^[0-9]{1,4}$ ]] || { echo "::error::deadline must be a number of minutes, got '$WEEKLY_DEADLINE_MINUTES'"; return 1; }
  case "$WEEKLY_MIN_SEVERITY" in low|medium|critical) ;; *) echo "::error::Invalid min severity '$WEEKLY_MIN_SEVERITY'"; return 1 ;; esac
  case "$WEEKLY_MIN_CONFIDENCE" in unsure|likely|sure) ;; *) echo "::error::Invalid min confidence '$WEEKLY_MIN_CONFIDENCE'"; return 1 ;; esac
  if [ -n "${WEEKLY_EXCLUDE_REF:-}" ] && ! [[ "$WEEKLY_EXCLUDE_REF" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "::error::Invalid exclude_ref '$WEEKLY_EXCLUDE_REF'"
    return 1
  fi

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR/branches"
  # Taken before the clone, and pushed back by a margin: a commit that lands while this run works, or one
  # whose committer date is a little older than its push, is then inside the next window instead of between two.
  WINDOW_END=$(date -u -d "$WEEKLY_WINDOW_MARGIN_MINUTES minutes ago" +%Y-%m-%dT%H:%M:%SZ)
  # The full history, not a shallow clone: the review reads old commits and compares them with the head.
  if ! git clone --quiet "$(_clone_url)" "$WORK_DIR/src"; then
    echo "::error::Could not clone $WEEKLY_ORG/$WEEKLY_REPO"
    return 1
  fi

  local BRANCHES_FILE="$WORK_DIR/branches.txt" INDEX=0 BRANCH BRANCH_DIR OPEN_PR COMMITS_FILE TOTAL
  : > "$BRANCHES_FILE"
  local RANGE_ARGS HELD_BACK=0
  while IFS= read -r BRANCH; do
    [ -n "$BRANCH" ] || continue
    if ! OPEN_PR=$(_open_weekly_pr "$BRANCH"); then
      echo "::warning::Could not read the open pull requests of $WEEKLY_REPO - skipping $BRANCH"
      _weekly_notice "weekly review skipped $BRANCH: its open pull requests could not be read"
      continue
    fi
    if [ -n "$OPEN_PR" ]; then
      echo "$BRANCH already has $OPEN_PR open pull request(s) from this pipeline - skipping it"
      # Nothing is lost: no end-of-review marker is written for a skipped week, so the next run that gets
      # past this check starts from the earlier marker and covers it. Said out loud because the PR is waiting.
      _weekly_notice "weekly review skipped $BRANCH: an earlier pull request of this pipeline is still open (merge or close it; the next run picks up from where the last review ended)"
      HELD_BACK=$((HELD_BACK + 1))
      continue
    fi

    BRANCH_DIR="$WORK_DIR/branches/pending"
    rm -rf "$BRANCH_DIR"
    mkdir -p "$BRANCH_DIR"
    : > "$BRANCH_DIR/commits.tsv"
    : > "$BRANCH_DIR/skipped.tsv"
    RANGE_ARGS=("origin/$BRANCH")
    [ -n "${WEEKLY_EXCLUDE_REF:-}" ] && RANGE_ARGS+=("^origin/$WEEKLY_EXCLUDE_REF")
    _choose_window "$BRANCH"
    echo "$BRANCH: reviewing the commits $WINDOW_TEXT"
    printf '%s\n' "$WINDOW_TEXT" > "$BRANCH_DIR/window.txt"
    printf '%s\n' "$WINDOW_END" > "$BRANCH_DIR/window-end.txt"

    # Oldest first, so the fixes line up in the order the commits landed.
    local SHA AUTHOR_EMAIL AUTHOR_NAME SUBJECT
    while IFS=$'\t' read -r SHA AUTHOR_EMAIL AUTHOR_NAME SUBJECT; do
      [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || continue
      _triage_commit "$WORK_DIR/src" "$SHA" "$AUTHOR_EMAIL" "$AUTHOR_NAME" "$SUBJECT" "$BRANCH_DIR"
    done < <(git -C "$WORK_DIR/src" log --no-merges --reverse --since="$WINDOW_SINCE" \
               --format='%H%x09%ae%x09%an%x09%s' "${RANGE_ARGS[@]}")

    TOTAL=$(wc -l < "$BRANCH_DIR/commits.tsv" | tr -d ' ')
    if [ "$TOTAL" -eq 0 ]; then
      echo "$BRANCH: nothing to review in the commits $WINDOW_TEXT ($(wc -l < "$BRANCH_DIR/skipped.tsv" | tr -d ' ') skipped)"
      rm -rf "$BRANCH_DIR"
      continue
    fi
    echo 0 > "$BRANCH_DIR/truncated.txt"
    if [ "$WEEKLY_MAX_COMMITS" -gt 0 ] && [ "$TOTAL" -gt "$WEEKLY_MAX_COMMITS" ]; then
      # The newest commits are kept: they are the ones nobody has had time to look at yet.
      COMMITS_FILE="$BRANCH_DIR/commits.tsv"
      tail -n "$WEEKLY_MAX_COMMITS" "$COMMITS_FILE" > "$COMMITS_FILE.tmp"
      mv "$COMMITS_FILE.tmp" "$COMMITS_FILE"
      echo $((TOTAL - WEEKLY_MAX_COMMITS)) > "$BRANCH_DIR/truncated.txt"
    fi

    INDEX=$((INDEX + 1))
    printf '%s\n' "$BRANCH" > "$BRANCH_DIR/branch.txt"
    mv "$BRANCH_DIR" "$WORK_DIR/branches/$INDEX"
    printf '%s\t%s\n' "$INDEX" "$BRANCH" >> "$BRANCHES_FILE"
    echo "$BRANCH: $(wc -l < "$WORK_DIR/branches/$INDEX/commits.tsv" | tr -d ' ') commit(s) to review"
  done < <(_list_candidate_branches "$WORK_DIR/src")

  if [ "$INDEX" -eq 0 ]; then
    if [ "$HELD_BACK" -gt 0 ]; then
      _skip_run "the latest branch was held back by an open pull request of this pipeline"
    else
      _skip_run "no release or hotfix branch has a commit to review in its window"
    fi
    return 0
  fi
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "skip=false" >> "$GITHUB_OUTPUT"
  return 0
}

# ============================================================================
# Isolated-container sandbox
# ============================================================================
# Same containment as triage-run.sh's and review-run.sh's sandbox sections - an internal network, a
# Squid proxy that lets through npm and the Anthropic API only, no token, no docker.sock - and
# deliberately a copy rather than a shared library: the three differ in what they copy in and how many
# sessions they run. Fixes to the shared parts (the DooD host-path resolution, the backgrounded exec
# so traps fire, the capability drop) are worth porting by hand in both directions.

name_weekly_resources() {
  local RUN_TAG="${GITHUB_RUN_ID:-$$}"
  NET_NAME="weekly-internal-$RUN_TAG"
  PROXY_NAME="weekly-proxy-$RUN_TAG"
  SANDBOX_NAME="claude-weekly-$RUN_TAG"
  mkdir -p claude-output
  : > "$WORK_DIR/cost.txt"
}

# Sandbox and proxy are siblings on the HOST daemon, not children of this job, so a cancelled job does not stop them.
cleanup_weekly_sandbox() {
  docker rm -f "$PROXY_NAME" "$SANDBOX_NAME" > /dev/null 2>&1 || true
  docker network rm "$NET_NAME" > /dev/null 2>&1 || true
  scrub_claude_output
}

# /output is a bind mount the model can write to, and the artifact upload and the patch reader both
# follow symlinks: anything that is not a plain file or a directory is removed on every exit path.
scrub_claude_output() {
  [ -d claude-output ] || return 0
  find claude-output \( -type l -o -type p -o -type s -o -type b -o -type c \) -delete 2>/dev/null || true
}

# Resolves the host path backing $PWD (docker -v resolves on the HOST under DooD); empty HOST_OUTPUT_DIR means callers fall back to docker cp.
resolve_weekly_output_dir() {
  HOST_OUTPUT_DIR=""
  local SELF_ID HOST_PWD
  # By container ID from cgroup, not hostname: this runner sets a custom --hostname unrelated to the real container ID.
  SELF_ID=$(grep -oE '[0-9a-f]{64}' /proc/self/cgroup 2>/dev/null | head -1 || true)
  [ -n "$SELF_ID" ] || SELF_ID="$(hostname)"
  HOST_PWD=$(docker inspect "$SELF_ID" --format '{{json .Mounts}}' 2>/dev/null | jq -er --arg pwd "$PWD" '
    [.[]? | select(.Destination? as $d | $pwd == $d or ($pwd | startswith($d + "/")))]
    | sort_by(-(.Destination | length)) | .[0]
    | if . then .Source + ($pwd | ltrimstr(.Destination)) else empty end
  ' 2>/dev/null || true)
  if [ -n "$HOST_PWD" ]; then
    HOST_OUTPUT_DIR="$HOST_PWD/claude-output"
  else
    echo "::warning::Could not resolve the host path backing $PWD via docker inspect - using docker cp instead of a bind mount for /output"
  fi
}

# Builds the isolated network, proxy and sandbox, copies the clone and weekly/ in and installs the CLI.
setup_weekly_sandbox() {
  docker network create --internal "$NET_NAME" > /dev/null
  mkdir -p /tmp/squid-weekly
  cat > /tmp/squid-weekly/squid.conf << 'EOF'
http_port 3128
acl allowed_dst dstdomain .npmjs.org api.anthropic.com
http_access allow allowed_dst
http_access deny all
EOF
  docker create --name "$PROXY_NAME" --network "$NET_NAME" ubuntu/squid:latest > /dev/null
  docker cp /tmp/squid-weekly/squid.conf "$PROXY_NAME":/etc/squid/squid.conf
  docker start "$PROXY_NAME" > /dev/null
  docker network connect bridge "$PROXY_NAME"
  # Wait for squid to accept connections: the npm install below is the first thing through the proxy.
  local WAITED=0
  if docker exec "$PROXY_NAME" bash -c 'true' 2>/dev/null; then
    until docker exec "$PROXY_NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/3128' 2>/dev/null; do
      WAITED=$((WAITED + 1))
      if [ "$WAITED" -ge 30 ]; then
        echo "::warning::Egress proxy still not listening on :3128 after ${WAITED}s - continuing anyway"
        break
      fi
      sleep 1
    done
    [ "$WAITED" -lt 30 ] && echo "Egress proxy ready after ${WAITED}s"
  else
    echo "::warning::No bash in the proxy image to probe :3128 with - falling back to a fixed wait"
    sleep 2
  fi

  # /output is the ONLY bind mount (when resolved) - a dedicated empty dir, never the job's workspace.
  local OUTPUT_MOUNT_ARGS=()
  [ -n "$HOST_OUTPUT_DIR" ] && OUTPUT_MOUNT_ARGS=(-v "$HOST_OUTPUT_DIR:/output")
  # Commit text is written by anyone with push access, so drop the default capability set and keep only what chown/npm need.
  local HARDENING_ARGS=(
    --cap-drop=ALL
    --cap-add=CHOWN --cap-add=FOWNER --cap-add=DAC_OVERRIDE
    --security-opt=no-new-privileges
    --pids-limit="${SANDBOX_PIDS_LIMIT:-1024}"
  )
  [ -n "${SANDBOX_MEMORY:-}" ] && HARDENING_ARGS+=(--memory="$SANDBOX_MEMORY")

  docker run -d --name "$SANDBOX_NAME" --network "$NET_NAME" \
    "${OUTPUT_MOUNT_ARGS[@]}" \
    "${HARDENING_ARGS[@]}" \
    -e ANTHROPIC_API_KEY \
    -e CLAUDE_CODE_VERSION \
    -e CLAUDE_MODEL \
    -e CLAUDE_EFFORT \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    -e "HTTP_PROXY=http://$PROXY_NAME:3128" \
    -e "HTTPS_PROXY=http://$PROXY_NAME:3128" \
    -e "http_proxy=http://$PROXY_NAME:3128" \
    -e "https_proxy=http://$PROXY_NAME:3128" \
    -e NO_PROXY=localhost,127.0.0.1 \
    -w /workspace \
    node:24 sleep infinity > /dev/null

  docker exec "$SANDBOX_NAME" mkdir -p /workspace/prompts /output
  docker cp "$WORK_DIR/src" "$SANDBOX_NAME":/workspace/repo
  # REVIEW.md and FIX.md reference /weekly/*-schema.json, and run_claude_session reads the schemas from there.
  docker cp weekly/. "$SANDBOX_NAME":/weekly/
  echo "Files inside container: $(docker exec "$SANDBOX_NAME" sh -c 'find /workspace -type f | wc -l')"

  docker exec "$SANDBOX_NAME" npm install -g --no-fund --no-audit --no-update-notifier --loglevel=error "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
  docker exec "$SANDBOX_NAME" sh -c 'echo "Running the weekly review with model: $CLAUDE_MODEL, effort: $CLAUDE_EFFORT (claude-code $(claude --version || echo unknown))"'
  # --dangerously-skip-permissions refuses to run as root, and docker cp leaves files root-owned.
  docker exec "$SANDBOX_NAME" chown -R node:node /workspace /output
  echo '{"projects":{"/workspace":{"hasTrustDialogAccepted":true},"/workspace/repo":{"hasTrustDialogAccepted":true},"/workspace/fix":{"hasTrustDialogAccepted":true}}}' > /tmp/claude-trust-weekly.json
  docker cp /tmp/claude-trust-weekly.json "$SANDBOX_NAME":/home/node/.claude.json
  docker exec "$SANDBOX_NAME" chown node:node /home/node/.claude.json
}

# Sum of what every session of this run has cost so far.
_spent_usd() {
  awk '{ total += $1 } END { printf "%.3f", total + 0 }' "$WORK_DIR/cost.txt" 2>/dev/null || echo 0
}

_budget_left() {
  awk -v spent="$(_spent_usd)" -v cap="$WEEKLY_TOTAL_BUDGET_USD" 'BEGIN { exit !(spent < cap) }'
}

# Copies an output file out of the sandbox when /output is not a bind mount.
_fetch_output() {
  [ -z "$HOST_OUTPUT_DIR" ] || return 0
  docker cp "$SANDBOX_NAME":"/output/$1" "./claude-output/$1" 2>/dev/null || true
}

# One claude -p session in the sandbox. Returns non-zero (after a warning) when it did not finish cleanly.
#   run_claude_session LABEL WORKDIR PROMPT_PATH SCHEMA_PATH MODEL BUDGET_USD TIMEOUT_SECS
# The result envelope lands in claude-output/LABEL.json and its debug log in claude-output/LABEL-debug.log.
run_claude_session() {
  local LABEL="$1" WORKDIR="$2" PROMPT="$3" SCHEMA="$4" MODEL="$5" BUDGET="$6" LIMIT="$7" rc=0
  local STARTED=$SECONDS
  # --disallowedTools Task: a spawned subagent starts with a fresh context instead of reusing the
  # cheap cached one, which trades money for wall-clock (see review-run.sh for the measured case).
  # timeout inside the container, so a hung session ends as a clean exit 124 instead of a job kill.
  docker exec --user node -w "$WORKDIR" -e CLAUDE_EFFORT "$SANDBOX_NAME" bash -c '
    set -euo pipefail
    timeout "$6" claude -p --model "$4" --effort "$CLAUDE_EFFORT" --max-budget-usd "$5" \
      --debug-file "/output/$1-debug.log" --output-format json --dangerously-skip-permissions --permission-prompts none \
      --disallowedTools "Task" \
      --json-schema "$(cat "$3")" \
      < "$2" > "/output/$1.json"
  ' _ "$LABEL" "$PROMPT" "$SCHEMA" "$MODEL" "$BUDGET" "$LIMIT" &
  local SESSION_PID=$!
  # Backgrounded and waited on, not foreground: POSIX defers trap delivery until the current
  # foreground command exits, so a cancelled job would otherwise keep the container running.
  trap 'docker stop -t 5 "$SANDBOX_NAME" > /dev/null 2>&1 || true' TERM INT
  wait "$SESSION_PID" || rc=$?
  trap 'exit 143' TERM; trap 'exit 130' INT

  _fetch_output "$LABEL.json"
  _fetch_output "$LABEL-debug.log"
  scrub_claude_output
  [ -s "claude-output/$LABEL.json" ] || echo '{}' > "claude-output/$LABEL.json"
  SESSION_COST=$(jq -r '.total_cost_usd // 0' "claude-output/$LABEL.json" 2> /dev/null | tr -d '\r' || true)
  [[ "$SESSION_COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] || SESSION_COST=0
  echo "$SESSION_COST" >> "$WORK_DIR/cost.txt"
  echo "  [$LABEL] finished after $((SECONDS - STARTED))s (exit $rc, \$$(jq -r '.total_cost_usd // 0 | (. * 1000 | round) / 1000' "claude-output/$LABEL.json" 2>/dev/null || echo '?'), run total \$$(_spent_usd))"

  # The answer normally sits in .result; a run that ended on the schema-forced object has it in .structured_output instead.
  if [ "$rc" -ne 0 ] || ! jq -e '.is_error == false and (((.result // "") | length > 0) or (.structured_output != null))' "claude-output/$LABEL.json" > /dev/null 2>&1; then
    if [ "$rc" -eq 124 ]; then
      echo "::warning::Session $LABEL hit the ${LIMIT}s timeout"
    else
      echo "::warning::Session $LABEL did not finish cleanly (exit $rc, subtype: $(jq -r '.subtype // "unknown"' "claude-output/$LABEL.json" 2>/dev/null || echo unparsable))"
    fi
    return 1
  fi
  return 0
}

# The text of a finished session's answer: .result, or the schema-forced object when .result is empty.
_session_text() {
  jq -r 'if (.result // "") != "" then .result else (.structured_output | tojson) end' "claude-output/$1.json"
}

# Renders a prompt template and copies it into the sandbox as /workspace/prompts/NAME.txt.
_install_prompt() {
  local TEMPLATE="$1" NAME="$2" RENDERED="$3"
  envsubst '$ORG_NAME $REPO_NAME $BRANCH $COMMIT_SHA $COMMIT_AUTHOR $COMMIT_SUBJECT $COMMIT_MESSAGE $REVIEW_RANGE $DIFF_SIZE_NOTE $FINDINGS' \
    < "$TEMPLATE" > "$RENDERED"
  docker cp "$RENDERED" "$SANDBOX_NAME":"/workspace/prompts/$NAME.txt"
  docker exec "$SANDBOX_NAME" chown node:node "/workspace/prompts/$NAME.txt"
}

# Puts the fix workspace back on the given commit, discarding whatever a session left behind. Fails
# when it could not, so a caller about to start a paid session can refuse to.
_reset_fix_workspace() {
  docker exec --user node -w /workspace/fix "$SANDBOX_NAME" bash -c \
    'git reset -q --hard "$1" && git clean -fdxq' _ "$1" > /dev/null 2>&1
}

# Adds the session that just finished to the cost of the commit being reviewed.
_add_commit_cost() {
  COMMIT_COST=$(awk -v total="${COMMIT_COST:-0}" -v session="${SESSION_COST:-0}" 'BEGIN { printf "%.4f", total + session }')
}

# Said once per run: every later commit would repeat it, and this is the one case where "every commit" was not met.
_note_run_limit_once() {
  grep -q 'later commits were not reviewed' pipeline-notice.txt 2>/dev/null \
    || _weekly_notice "weekly review: $1, later commits were not reviewed"
}

# Sets LIMIT_REASON and returns 0 when no new commit may be started: the money or the time is spent.
# The time limit is what keeps the job timeout from killing a run that still holds finished fixes.
_run_limit_reached() {
  LIMIT_REASON=""
  if ! _budget_left; then
    LIMIT_REASON="the budget of the run (\$$WEEKLY_TOTAL_BUDGET_USD) was spent"
  elif [ "$SECONDS" -ge $((WEEKLY_DEADLINE_MINUTES * 60)) ]; then
    LIMIT_REASON="the time limit of the run ($WEEKLY_DEADLINE_MINUTES minutes) was reached"
  else
    return 1
  fi
  return 0
}

# Turns the fix session's working tree into claude-output/LABEL.patch, relative to the head it started on.
_collect_fix_patch() {
  local LABEL="$1" BASE_HEAD="$2"
  docker exec --user node -w /workspace/fix "$SANDBOX_NAME" bash -c '
    # A session that committed or moved HEAD is put back first: only the tree is the output.
    git reset -q --soft "$2" || exit 1
    git add -A
    git diff --cached --binary --no-color "$2" > "/output/$1.patch"
  ' _ "$LABEL" "$BASE_HEAD" || return 1
  _fetch_output "$LABEL.patch"
  return 0
}

# result.json of one commit: what the commit was, what the review found, what the fix did.
_write_commit_result() {
  local CDIR="$1" STATUS="$2" REASON="$3"
  local SELECTED FIX="null" BELOW=0 CUT=0
  SELECTED=$(jq -c '.' "$CDIR/selected.json" 2>/dev/null || echo '[]')
  [ -s "$CDIR/fix.json" ] && FIX=$(jq -c '{title, summary, confidence, not_verified, results}' "$CDIR/fix.json" 2>/dev/null || echo null)
  if [ -s "$CDIR/counts.txt" ]; then
    # counts.txt is "kept qualifying total": below the threshold = total - qualifying, over the per-commit cap = qualifying - kept.
    BELOW=$(awk '{ print ($3 > $2) ? $3 - $2 : 0 }' "$CDIR/counts.txt")
    CUT=$(awk '{ print ($2 > $1) ? $2 - $1 : 0 }' "$CDIR/counts.txt")
  fi
  local REVIEW_SUMMARY=""
  [ -s "$CDIR/review.json" ] && REVIEW_SUMMARY=$(jq -r '.summary // ""' "$CDIR/review.json" 2>/dev/null | tr -d '\r' || true)
  jq -n --arg sha "$COMMIT_SHA" --arg subject "$COMMIT_SUBJECT" --arg author "$COMMIT_AUTHOR" \
    --arg status "$STATUS" --arg reason "$REASON" --argjson selected "$SELECTED" --argjson fix "$FIX" --argjson below "$BELOW" --argjson cut "$CUT" \
    --argjson lines "${COMMIT_LINES:-0}" --arg summary "$REVIEW_SUMMARY" --argjson cost "${COMMIT_COST:-0}" \
    '{sha: $sha, subject: $subject, author: $author, status: $status, reason: $reason, lines: $lines, review_summary: $summary, cost_usd: $cost,
      findings_selected: $selected, findings_below_threshold: $below, findings_cut: $cut, fix: $fix}' > "$CDIR/result.json"
}

# Reviews one commit and, when it has findings worth a fix, writes the fix. Never fatal: a commit that
# could not be reviewed is a line in the pull request, not a reason to stop the run.
# Expects COMMIT_SHA/COMMIT_SUBJECT/COMMIT_AUTHOR/BRANCH and the sandbox variables set.
review_one_commit() {
  local INDEX="$1" NUMBER="$2" CDIR="$3"
  local LABEL="b$INDEX-c$NUMBER"
  COMMIT_COST=0
  mkdir -p "$CDIR"

  if _run_limit_reached; then
    echo "::warning::$LIMIT_REASON - $COMMIT_SHA is not reviewed"
    _note_run_limit_once "$LIMIT_REASON"
    _write_commit_result "$CDIR" "not-reviewed" "$LIMIT_REASON before this commit"
    return 0
  fi

  COMMIT_MESSAGE=$(_sanitize "$(git -C "$WORK_DIR/src" log -1 --format=%B "$COMMIT_SHA" 2>/dev/null || true)" 1500)
  REVIEW_RANGE="$COMMIT_SHA^..$COMMIT_SHA"
  local REVIEW_BUDGET="${CLAUDE_MAX_BUDGET_USD:-1.5}" REVIEW_TIMEOUT="${REVIEW_CLI_TIMEOUT:-900}"
  DIFF_SIZE_NOTE=""
  if [ "${COMMIT_LINES:-0}" -ge "$WEEKLY_LARGE_COMMIT_LINES" ]; then
    # Triple budget, double timeout: a large commit is reviewed in full, never skipped or sampled.
    REVIEW_BUDGET=$(awk -v budget="$REVIEW_BUDGET" 'BEGIN { printf "%.2f", budget * 3 }')
    REVIEW_TIMEOUT=$((REVIEW_TIMEOUT * 2))
    DIFF_SIZE_NOTE="**This commit is large** ($COMMIT_LINES changed lines). Do not sample it: map it with \`git show --stat\`, then \`Read\` every changed production file at the branch head and review each one. Only generated files, lockfiles, translations and pure renames may be skimmed. In \`summary\`, state how many of the changed files you opened and name the riskiest ones you did not."
  fi
  export ORG_NAME="$WEEKLY_ORG" REPO_NAME="$WEEKLY_REPO" BRANCH COMMIT_SHA COMMIT_AUTHOR COMMIT_SUBJECT COMMIT_MESSAGE REVIEW_RANGE DIFF_SIZE_NOTE
  _install_prompt weekly/REVIEW.md "$LABEL-review" "$CDIR/review-prompt.txt"

  echo "Reviewing $COMMIT_SHA: $COMMIT_SUBJECT"
  local REVIEW_OK=true
  run_claude_session "$LABEL-review" /workspace/repo "/workspace/prompts/$LABEL-review.txt" /weekly/review-schema.json \
    "$CLAUDE_MODEL" "$REVIEW_BUDGET" "$REVIEW_TIMEOUT" || REVIEW_OK=false
  _add_commit_cost
  # The review session was asked not to edit anything; make sure the next one starts from the head anyway.
  docker exec --user node -w /workspace/repo "$SANDBOX_NAME" bash -c 'git reset -q --hard && git clean -fdxq' > /dev/null 2>&1 || true
  if [ "$REVIEW_OK" != "true" ]; then
    _write_commit_result "$CDIR" "review-failed" "the review session did not finish"
    return 0
  fi
  if ! _session_text "$LABEL-review" \
       | EXTRACT_JSON_SCHEMA=weekly/review-schema.json python3 .gitea/scripts/common.py extract-json > "$CDIR/review.json"; then
    echo "::warning::Could not read a valid review from $LABEL-review"
    _write_commit_result "$CDIR" "review-failed" "the review did not return valid output"
    return 0
  fi

  python3 .gitea/scripts/weekly-review-tools.py select --findings "$CDIR/review.json" --out "$CDIR/selected.json" \
    --text-out "$CDIR/findings.txt" --min-severity "$WEEKLY_MIN_SEVERITY" --min-confidence "$WEEKLY_MIN_CONFIDENCE" | tr -d '' > "$CDIR/counts.txt"
  local SELECTED_COUNT QUALIFYING_COUNT TOTAL_COUNT
  read -r SELECTED_COUNT QUALIFYING_COUNT TOTAL_COUNT < "$CDIR/counts.txt"
  echo "  $SELECTED_COUNT finding(s) selected ($QUALIFYING_COUNT at or above the threshold, $TOTAL_COUNT in all)"
  if [ "$SELECTED_COUNT" -eq 0 ]; then
    _write_commit_result "$CDIR" "clean" ""
    return 0
  fi

  FINDINGS=$(cat "$CDIR/findings.txt")
  export FINDINGS
  _install_prompt weekly/FIX.md "$LABEL-fix" "$CDIR/fix-prompt.txt"
  # The review session ran in the same container with full write access and read untrusted commit text,
  # so nothing it may have left in the fix workspace is trusted: the tree goes back to the branch head first.
  if ! _reset_fix_workspace "$FIX_HEAD"; then
    echo "::warning::Could not reset the fix workspace - no fix is attempted for $COMMIT_SHA"
    _write_commit_result "$CDIR" "fix-failed" "the fix workspace could not be reset"
    return 0
  fi

  echo "  Writing a fix for $SELECTED_COUNT finding(s)"
  local FIX_OK=true
  run_claude_session "$LABEL-fix" /workspace/fix "/workspace/prompts/$LABEL-fix.txt" /weekly/fix-schema.json \
    "${FIX_MODEL:-$CLAUDE_MODEL}" "${FIX_MAX_BUDGET_USD:-2}" "${FIX_CLI_TIMEOUT:-1200}" || FIX_OK=false
  _add_commit_cost
  # A session that timed out or errored leaves a half-finished edit in the tree. It would still be a
  # valid-looking patch, and a plausible broken fix is the one outcome worse than none: it is discarded unread.
  if [ "$FIX_OK" != "true" ]; then
    _reset_fix_workspace "$FIX_HEAD" || true
    _write_commit_result "$CDIR" "fix-failed" "the fix session did not finish"
    return 0
  fi
  if ! _session_text "$LABEL-fix" \
       | EXTRACT_JSON_SCHEMA=weekly/fix-schema.json python3 .gitea/scripts/common.py extract-json > "$CDIR/fix.json"; then
    echo "::warning::Could not read a valid fix description from $LABEL-fix"
    rm -f "$CDIR/fix.json"
    _reset_fix_workspace "$FIX_HEAD" || true
    _write_commit_result "$CDIR" "fix-failed" "the fix session did not return valid output"
    return 0
  fi
  local NOTES
  NOTES=$(jq -r '[.results[]? | .note // empty] | join("; ")' "$CDIR/fix.json" | tr -d '\r' | _trim_chars 300)
  # Every finding marked not_fixed means the session itself found nothing to fix; whatever it touched
  # anyway (a reformat, a scratch file) is not a fix and is dropped, however non-empty the tree is.
  if [ "$(jq '[.results[]? | select(.outcome == "fixed")] | length' "$CDIR/fix.json")" = "0" ]; then
    _reset_fix_workspace "$FIX_HEAD" || true
    _write_commit_result "$CDIR" "not-fixed" "${NOTES:-the fix session left every finding as it is}"
    return 0
  fi
  if ! _collect_fix_patch "$LABEL-fix" "$FIX_HEAD" || [ ! -s "claude-output/$LABEL-fix.patch" ]; then
    _reset_fix_workspace "$FIX_HEAD" || true
    _write_commit_result "$CDIR" "not-fixed" "${NOTES:-the fix session changed nothing}"
    return 0
  fi
  local FIX_CONFIDENCE
  FIX_CONFIDENCE=$(jq -r '.confidence // ""' "$CDIR/fix.json" | tr -d '\r')
  # The schema's enum is a request to the model, not a guarantee: the value is checked here.
  if [ "$FIX_CONFIDENCE" != "high" ] && [ "$FIX_CONFIDENCE" != "medium" ]; then
    _reset_fix_workspace "$FIX_HEAD" || true
    _write_commit_result "$CDIR" "not-fixed" "the fix session rated its own edit '${FIX_CONFIDENCE:-unstated}'"
    return 0
  fi
  cp "claude-output/$LABEL-fix.patch" "$CDIR/fix.patch"
  # Every fix is written against the branch head, never on top of an earlier one: a patch that is refused
  # on the runner then strands nothing else, and a failed step cannot fold one fix into the next.
  _reset_fix_workspace "$FIX_HEAD" || true
  _write_commit_result "$CDIR" "fixed" ""
  return 0
}

# All commits of one branch: puts the checkout and the fix workspace on the branch head, then loops.
review_branch() {
  local INDEX="$1"
  BRANCH=$(awk -F'\t' -v i="$INDEX" '$1 == i { print $2 }' "$WORK_DIR/branches.txt")
  # Exported for `docker exec -e BRANCH`, which reads it from the environment.
  export BRANCH
  local BRANCH_DIR="$WORK_DIR/branches/$INDEX"
  echo "=== $BRANCH ==="
  if ! docker exec --user node -w /workspace/repo -e BRANCH "$SANDBOX_NAME" bash -c \
       'git checkout -q --detach "origin/$BRANCH" && git clean -fdxq'; then
    echo "::warning::Could not check out $BRANCH in the sandbox"
    _weekly_notice "weekly review skipped $BRANCH: it could not be checked out in the sandbox"
    return 0
  fi
  # The fix workspace is a clone with the same history, so a session can run `git show` on the commit.
  if ! docker exec --user node -e BRANCH "$SANDBOX_NAME" bash -c '
      set -e
      rm -rf /workspace/fix
      git clone -q --no-hardlinks --no-checkout /workspace/repo /workspace/fix
      git -C /workspace/fix fetch -q /workspace/repo "+refs/remotes/origin/$BRANCH:refs/heads/base"
      git -C /workspace/fix checkout -q base'; then
    echo "::warning::Could not prepare the fix workspace for $BRANCH"
    _weekly_notice "weekly review skipped $BRANCH: the sandbox could not be prepared"
    return 0
  fi
  # Global, read by review_one_commit: the commit every fix of this branch is written against.
  FIX_HEAD=$(docker exec --user node -w /workspace/fix "$SANDBOX_NAME" git rev-parse HEAD | tr -d '\r')
  if ! [[ "$FIX_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::warning::Could not read the head of the fix workspace for $BRANCH"
    _weekly_notice "weekly review skipped $BRANCH: the fix workspace head could not be read"
    return 0
  fi

  local NUMBER=0 SHA AUTHOR SUBJECT
  local COMMIT_LINES_FIELD
  while IFS=$'\t' read -r SHA AUTHOR SUBJECT COMMIT_LINES_FIELD <&3; do
    NUMBER=$((NUMBER + 1))
    COMMIT_SHA="$SHA"
    COMMIT_AUTHOR="$AUTHOR"
    COMMIT_SUBJECT="$SUBJECT"
    COMMIT_LINES="${COMMIT_LINES_FIELD:-0}"
    review_one_commit "$INDEX" "$NUMBER" "$BRANCH_DIR/c-$NUMBER"
  done 3< "$BRANCH_DIR/commits.tsv"

  # The commits go oldest first, so a run limit leaves the reviewed ones as a prefix: the window then ends
  # just before the first commit that was not reviewed, and the next run starts there.
  local RESULT_FILES UNREVIEWED_EPOCH
  RESULT_FILES=$(find "$BRANCH_DIR" -path '*/c-*/result.json' | sort -V)
  if [ -n "$RESULT_FILES" ] && jq -es 'any(.[]; .status == "not-reviewed")' $RESULT_FILES > /dev/null 2>&1; then
    UNREVIEWED_EPOCH=$(jq -r 'select(.status == "not-reviewed") | .sha' $RESULT_FILES \
      | while read -r SHA; do git -C "$WORK_DIR/src" log -1 --format=%ct "$SHA"; done | sort -n | head -n 1)
    if [[ "$UNREVIEWED_EPOCH" =~ ^[0-9]+$ ]]; then
      date -u -d "@$((UNREVIEWED_EPOCH - 1))" +%Y-%m-%dT%H:%M:%SZ > "$BRANCH_DIR/window-end.txt"
    else
      rm -f "$BRANCH_DIR/window-end.txt"
    fi
  fi
  return 0
}

weekly_sandbox_step() {
  # DooD: the CLI runs in a throwaway nested container with only ANTHROPIC_API_KEY, egress
  # restricted to npm + Anthropic - no GITEA_TOKEN, no docker.sock.
  name_weekly_resources
  # EXIT does the cleanup; TERM and INT must end the script (a bare handler would run and carry on).
  trap cleanup_weekly_sandbox EXIT
  trap 'exit 143' TERM; trap 'exit 130' INT
  cleanup_weekly_sandbox

  resolve_weekly_output_dir
  setup_weekly_sandbox

  local INDEX
  while IFS=$'\t' read -r INDEX _ <&4; do
    review_branch "$INDEX"
  done 4< "$WORK_DIR/branches.txt"
  echo "Sessions of the run cost \$$(_spent_usd) in all"
}

# ============================================================================
# Fixes -> draft pull request
# ============================================================================

_set_patch_state() {
  local RESULT_FILE="$1" PATCH_STATUS="$2" PATCH_NOTE="$3" TEMP_FILE
  TEMP_FILE=$(mktemp)
  jq --arg status "$PATCH_STATUS" --arg note "$PATCH_NOTE" '. + {patch_status: $status, patch_note: $note}' "$RESULT_FILE" > "$TEMP_FILE" \
    && mv "$TEMP_FILE" "$RESULT_FILE"
}

# Leaves the end of this review where the next run looks for it, when this run opened no pull request of its own:
# one comment on the newest pull request of this pipeline, edited in place on later runs so it never notifies anybody
# twice. Nothing to attach it to (no pull request yet) means the next run falls back to WEEKLY_FALLBACK_DAYS.
_record_window() {
  local INDEX="$1" BRANCH="$2" END_FILE="$WORK_DIR/branches/$1/window-end.txt" END LATEST NUMBER COMMENTS COMMENT_ID BODY PAYLOAD
  [ -s "$END_FILE" ] || return 0
  END=$(tr -d '\r\n' < "$END_FILE")
  LATEST=$(_latest_weekly_pr "$BRANCH") || { echo "::warning::Could not read the pull requests of $WEEKLY_REPO - the end of the review of $BRANCH is not recorded"; return 0; }
  if [ -z "$LATEST" ]; then
    echo "No pull request of this pipeline into $BRANCH yet - the end of its review is not recorded"
    return 0
  fi
  NUMBER=$(jq -r '.number' <<< "$LATEST")
  COMMENTS=$(_pr_comments "$NUMBER") || { echo "::warning::Could not read the comments of #$NUMBER - the end of the review is not recorded"; return 0; }
  COMMENT_ID=$(jq -r '[.[] | select((.body // "") | contains("weekly-review-window-end:"))] | first | .id // empty' <<< "$COMMENTS")
  BODY="Claude Weekly Review: the commits of $BRANCH up to $END were reviewed, nothing to propose."$'\n'"<!-- weekly-review-window-end:$END -->"
  PAYLOAD=$(jq -n --arg body "$BODY" '{body: $body}')
  if [[ "$COMMENT_ID" =~ ^[0-9]+$ ]]; then
    _weekly_api PATCH "/repos/$WEEKLY_ORG/$WEEKLY_REPO/issues/comments/$COMMENT_ID" -d "$PAYLOAD" > /dev/null || true
  else
    _weekly_api POST "/repos/$WEEKLY_ORG/$WEEKLY_REPO/issues/$NUMBER/comments" -d "$PAYLOAD" > /dev/null || true
  fi
  echo "Recorded the end of the review of $BRANCH ($END) on #$NUMBER"
}

# Validates and commits every fix of one branch in order, then pushes and opens the pull request.
# Sets BRANCH_OUTCOME: "pr" when a pull request was opened, "reviewed" when the commits were reviewed and there is
# nothing to open, and nothing when something failed or it was a dry run - the window end is then not recorded.
# Prints nothing on stdout that a caller needs; the pull request link goes to weekly-pr-urls.txt.
open_branch_pr() {
  local INDEX="$1" BRANCH="$2"
  local BRANCH_DIR="$WORK_DIR/branches/$INDEX" CLONE_DIR="$WORK_DIR/pr/$INDEX"
  local WEEK
  BRANCH_OUTCOME=""
  WEEK=$(date -u +%G-W%V)

  if ! compgen -G "$BRANCH_DIR/c-*/result.json" > /dev/null; then
    echo "$BRANCH: no results to turn into a pull request"
    return 0
  fi
  if ! jq -es 'any(.[]; .status == "fixed")' "$BRANCH_DIR"/c-*/result.json > /dev/null 2>&1; then
    echo "$BRANCH: no fix to propose"
    BRANCH_OUTCOME="reviewed"
    return 0
  fi

  rm -rf "$CLONE_DIR"
  if ! git clone --quiet --depth=1 --branch "$BRANCH" "$(_clone_url)" "$CLONE_DIR" 2> /dev/null; then
    echo "::warning::Could not clone $WEEKLY_REPO@$BRANCH for the pull request"
    _weekly_notice "weekly review: could not clone $BRANCH to open its pull request"
    return 0
  fi

  local GIT_ID=(-c "user.name=$WEEKLY_GIT_NAME" -c "user.email=$WEEKLY_GIT_EMAIL")
  local RESULT_FILE CDIR PATCH CHECK_OUT CHECK_RC TITLE APPLIED=0 SUBJECT_ERR APPLY_ARGS
  while IFS= read -r RESULT_FILE; do
    CDIR=$(dirname "$RESULT_FILE")
    [ "$(jq -r '.status' "$RESULT_FILE")" = "fixed" ] || continue
    PATCH="$CDIR/fix.patch"
    CHECK_RC=0
    APPLY_ARGS=(--index --whitespace=nowarn)
    CHECK_OUT=$(python3 .gitea/scripts/triage-tools.py check-patch "$PATCH" "$CLONE_DIR" 2> "$CDIR/check.err") || CHECK_RC=$?
    # The patches are independent, each written against the branch head, so an earlier one can have moved
    # this one's context. A three-way merge takes that case; a real conflict (the same or neighbouring
    # lines) fails it too and stays reported rather than forced.
    if [ "$CHECK_RC" = "2" ] && grep -q 'does not apply' "$CDIR/check.err"; then
      CHECK_RC=0
      CHECK_OUT=$(python3 .gitea/scripts/triage-tools.py check-patch "$PATCH" "$CLONE_DIR" --3way 2> "$CDIR/check.err") || CHECK_RC=$?
      if [ "$CHECK_RC" = "0" ]; then
        APPLY_ARGS+=(--3way)
        echo "Fix patch of $(jq -r '.sha' "$RESULT_FILE" | cut -c1-10) needs a three-way merge: an earlier fix moved its context"
      fi
    fi
    if [ "$CHECK_RC" != "0" ]; then
      SUBJECT_ERR=$(head -c 300 "$CDIR/check.err" | tr '\n\r' '  ' | sed 's/^refused: //; s/[[:space:]]*$//')
      echo "::warning::Fix patch of $(jq -r '.sha' "$RESULT_FILE" | cut -c1-10) not accepted: $SUBJECT_ERR"
      _set_patch_state "$RESULT_FILE" "refused" "$SUBJECT_ERR"
      continue
    fi
    if ! git -C "$CLONE_DIR" apply "${APPLY_ARGS[@]}" "$PWD/$PATCH" 2> "$CDIR/apply.err"; then
      echo "::warning::git apply failed after the check passed: $(head -c 200 "$CDIR/apply.err" | tr '\n\r' '  ')"
      # A failed three-way apply can leave conflict markers behind; the clone goes back to the last commit.
      git -C "$CLONE_DIR" reset -q --hard
      _set_patch_state "$RESULT_FILE" "not-applied" "git apply failed"
      continue
    fi
    # A fix must not break a file that parsed before it: check-patch judges paths and size, not content.
    if ! python3 .gitea/scripts/weekly-review-tools.py syntax-gate --repo "$CLONE_DIR" 2> "$CDIR/syntax.err"; then
      SUBJECT_ERR=$(head -c 300 "$CDIR/syntax.err" | tr '\n\r' '  ' | sed 's/[[:space:]]*$//')
      echo "::warning::Fix patch of $(jq -r '.sha' "$RESULT_FILE" | cut -c1-10) breaks a file that parsed before: $SUBJECT_ERR"
      git -C "$CLONE_DIR" reset -q --hard
      _set_patch_state "$RESULT_FILE" "refused" "syntax check: $SUBJECT_ERR"
      continue
    fi
    # The subject is one line from the model, capped by characters; a byte cut would sever a Cyrillic letter.
    TITLE=$(jq -r '.fix.title // ""' "$RESULT_FILE" | tr -d '\r' | tr '\n' ' ' | _trim_chars 72 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\.$//')
    [ -n "$TITLE" ] || TITLE="Fix a defect found in the weekly review"
    git -C "$CLONE_DIR" "${GIT_ID[@]}" commit -q -m "$TITLE"
    _set_patch_state "$RESULT_FILE" "$([ "${WEEKLY_DRY_RUN:-false}" = "true" ] && echo dry-run || echo applied)" ""
    APPLIED=$((APPLIED + 1))
    echo "Fix accepted ($CHECK_OUT): $TITLE"
  done < <(find "$BRANCH_DIR" -path '*/c-*/result.json' | sort -V)

  local COMMIT_BASE_URL="https://$GITEA_HOST/$WEEKLY_ORG/$WEEKLY_REPO/commit" RUN_URL=""
  [ -n "${GITHUB_RUN_ID:-}" ] && RUN_URL="https://$GITEA_HOST/${GITHUB_REPOSITORY:-$WEEKLY_ORG/ga-common}/actions/runs/$GITHUB_RUN_ID"
  local BODY_FILE="pr-body-$INDEX.md"
  python3 .gitea/scripts/weekly-review-tools.py render --dir "$BRANCH_DIR" --branch "$BRANCH" --week "$WEEK" \
    --window "$(cat "$BRANCH_DIR/window.txt" 2> /dev/null || true)" --large-lines "$WEEKLY_LARGE_COMMIT_LINES" --commit-base-url "$COMMIT_BASE_URL" --cost "$(_spent_usd)" --run-url "$RUN_URL" > "$BODY_FILE"

  if [ "$APPLIED" -eq 0 ]; then
    echo "$BRANCH: no fix passed the checks - no pull request"
    _weekly_notice "weekly review of $BRANCH: fixes were written but none passed the checks"
    BRANCH_OUTCOME="reviewed"
    return 0
  fi
  if [ "${WEEKLY_DRY_RUN:-false}" = "true" ]; then
    echo "Dry run: $APPLIED commit(s) validated for $BRANCH, nothing pushed. Description saved to $BODY_FILE"
    return 0
  fi

  local PR_BRANCH="${WEEKLY_BRANCH_PREFIX}${BRANCH//\//-}/$WEEK" PR_BRANCH_ENC EXISTS
  PR_BRANCH_ENC=${PR_BRANCH//\//%2F}
  # Only a clear 404 lets the branch be created: any other answer, including none, means the state is
  # unknown, and pushing on an unknown state is how a second proposal for one week appears.
  EXISTS=$(_weekly_api GET "/repos/$WEEKLY_ORG/$WEEKLY_REPO/branches/$PR_BRANCH_ENC" -o /dev/null -w '%{http_code}' || true)
  if [ "$EXISTS" = "200" ]; then
    # The earlier pull request of this week is not open (prepare would have skipped the branch), so this is a
    # deliberate rerun after it was closed or merged: it gets its own branch instead of being silently dropped.
    PR_BRANCH="$PR_BRANCH-${GITHUB_RUN_ID:-$(date -u +%H%M)}"
    PR_BRANCH_ENC=${PR_BRANCH//\//%2F}
    echo "The weekly branch already exists - using $PR_BRANCH"
    EXISTS=$(_weekly_api GET "/repos/$WEEKLY_ORG/$WEEKLY_REPO/branches/$PR_BRANCH_ENC" -o /dev/null -w '%{http_code}' || true)
    if [ "$EXISTS" = "200" ]; then
      echo "Branch $PR_BRANCH already exists too - not opening a second pull request"
      return 0
    fi
  fi
  if [ "$EXISTS" != "404" ]; then
    echo "::warning::Could not tell whether $PR_BRANCH exists (HTTP ${EXISTS:-none}) - not opening a pull request"
    _weekly_notice "weekly review of $BRANCH: no pull request opened, the branch check failed (HTTP ${EXISTS:-none})"
    return 0
  fi
  git -C "$CLONE_DIR" checkout -q -b "$PR_BRANCH"
  if ! git -C "$CLONE_DIR" push -q origin "$PR_BRANCH" 2> "$WORK_DIR/push-$INDEX.err"; then
    echo "::warning::Could not push $PR_BRANCH: $(head -c 200 "$WORK_DIR/push-$INDEX.err" | tr '\n\r' '  ')"
    _weekly_notice "weekly review of $BRANCH: the fix branch could not be pushed"
    return 0
  fi

  local PAYLOAD RESPONSE PR_URL
  # Where the next run starts reading commits; hidden in the rendered body, like the markers of the review pipeline.
  if [ -s "$BRANCH_DIR/window-end.txt" ]; then
    printf '\n<!-- weekly-review-window-end:%s -->\n' "$(tr -d '\r\n' < "$BRANCH_DIR/window-end.txt")" >> "$BODY_FILE"
  fi
  # The WIP: prefix makes Gitea treat this as a draft it will not let anyone merge until a person removes it.
  PAYLOAD=$(jq -n --arg title "WIP: Weekly review fixes for $BRANCH ($WEEK)" --arg head "$PR_BRANCH" --arg base "$BRANCH" \
    --rawfile body "$BODY_FILE" '{title: $title, head: $head, base: $base, body: $body}')
  RESPONSE=$(_weekly_api POST "/repos/$WEEKLY_ORG/$WEEKLY_REPO/pulls" -d "$PAYLOAD" || true)
  PR_URL=$(jq -r '.html_url // empty' <<< "$RESPONSE" 2> /dev/null | tr -d '\r' || true)
  if [ -z "$PR_URL" ]; then
    echo "::warning::The branch was pushed but the pull request was not created: $(head -c 200 <<< "$RESPONSE" | tr '\n\r' '  ')"
    _weekly_notice "weekly review of $BRANCH: branch $PR_BRANCH pushed but the pull request was not created"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$BRANCH" "$PR_URL" "$APPLIED" "$INDEX" >> weekly-pr-urls.txt
  echo "Opened draft pull request: $PR_URL"
  BRANCH_OUTCOME="pr"
  return 0
}

open_weekly_prs() {
  : > weekly-pr-urls.txt
  local INDEX BRANCH
  while IFS=$'\t' read -r INDEX BRANCH <&4; do
    open_branch_pr "$INDEX" "$BRANCH"
    if [ "$BRANCH_OUTCOME" = "reviewed" ] && [ "${WEEKLY_DRY_RUN:-false}" != "true" ]; then
      _record_window "$INDEX" "$BRANCH"
    fi
  done 4< "$WORK_DIR/branches.txt"
  return 0
}

# Sends one message with every opened pull request. Nothing opened, nothing sent: a quiet week is not news.
notify_weekly_result() {
  [ -s weekly-pr-urls.txt ] || { echo "No pull request was opened - nothing to send"; return 0; }
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "::warning::TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is unset - message not sent"
    return 0
  fi
  local TEXT BRANCH PR_URL FIXES INDEX STATS
  TEXT="Claude Weekly Review: $WEEKLY_REPO"
  while IFS=$'\t' read -r BRANCH PR_URL FIXES INDEX; do
    # What the pull request does not say at a glance: how many commits were really reviewed and how many need a person.
    STATS=$(jq -rs '
      (map(select(.status == "review-failed" or .status == "not-reviewed")) | length) as $unreviewed
      | (map(select(.status != "clean" and .status != "review-failed" and .status != "not-reviewed"
                    and ((.status == "fixed" and (.patch_status == "applied" or .patch_status == "dry-run")) | not))) | length) as $needs
      | "\(length - $unreviewed) reviewed, \($needs) need a person, \($unreviewed) not reviewed"' \
      "$WORK_DIR"/branches/"$INDEX"/c-*/result.json 2> /dev/null | tr -d '\r' || true)
    TEXT+=$'\n'"$BRANCH - $FIXES proposed fix(es)${STATS:+, $STATS}: $PR_URL"
  done < weekly-pr-urls.txt
  TEXT+=$'\n'"Run cost: \$$(_spent_usd)"
  curl -s --max-time 20 --retry 2 -o /dev/null -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$TELEGRAM_CHAT_ID" --arg text "$TEXT" '{chat_id: $id, text: $text, disable_web_page_preview: true}')" || true
  echo "Message sent"
}

# =====================================================================
# Entry points
# =====================================================================

weekly_main() {
  case "${1:-}" in
    prepare) prepare_weekly_context ;;
    sandbox) weekly_sandbox_step ;;
    open-pr) open_weekly_prs ;;
    notify)  notify_weekly_result ;;
    *)
      echo "usage: weekly-review-run.sh {prepare|sandbox|open-pr|notify}" >&2
      return 2
      ;;
  esac
}

# Sourcing (tests) only defines the functions; running the file dispatches.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  weekly_main "$@"
fi
