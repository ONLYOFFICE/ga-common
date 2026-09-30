#!/usr/bin/env bash
# Runner-side helpers for the "bug -> pull request" stage of bugzilla-triage.yml. Sourced by two steps:
#   attempt_fix   (inside "Run triage", where the sandbox is still alive) - decides whether a fix is
#                 worth attempting, and if so runs the fix session and collects its patch;
#   open_fix_pr   (its own step, the only one holding a token that can push) - validates that patch
#                 and turns it into a draft pull request.
#
# The split is the point. The model that writes the change works in the sandbox with no token, no
# Bugzilla key and no route to Gitea; everything it produces crosses to this side as a patch, and the
# patch is judged by check-fix-patch.py before anything is pushed. Nothing here trusts the sandbox.
#
# Expects from the job env: BUG_ID, GITEA_HOST. Optional: TRIAGE_ORG (default ONLYOFFICE),
# TRIAGE_FIX_PR (must be "true" for anything to happen), TRIAGE_FIX_MAX_OPEN (default 5).

TRIAGE_ORG="${TRIAGE_ORG:-ONLYOFFICE}"
FIX_BRANCH_PREFIX="bugfix/claude-bug-"

# Sets FIX_REPO / FIX_REF and returns 0 when a fix is worth attempting; otherwise sets FIX_WHY to a
# one-line reason and returns 1. Every condition is a reason to spend nothing: a fix session costs
# several times an analysis, and a pull request nobody asked for costs a reviewer's attention.
fix_eligibility() {
  FIX_WHY=""
  FIX_REPO=""
  FIX_REF=""
  if [ "${TRIAGE_FIX_PR:-false}" != "true" ]; then
    FIX_WHY="fix_pr is off"
    return 1
  fi
  if [ -s fix-disabled.txt ]; then
    FIX_WHY="$(head -1 fix-disabled.txt)"
    return 1
  fi
  if [ ! -s claude-structured.json ]; then
    FIX_WHY="the analysis produced no structured result"
    return 1
  fi

  local CONFIDENCE NOTE_KIND MISSING SIMILAR REPO
  CONFIDENCE=$(jq -r '.summary.confidence // ""' claude-structured.json 2>/dev/null | tr -d '\r' || true)
  NOTE_KIND=$(jq -r '.summary.note_kind // ""' claude-structured.json 2>/dev/null | tr -d '\r' || true)
  MISSING=$(jq -r '.missing_repository // ""' claude-structured.json 2>/dev/null | tr -d '\r' || true)
  SIMILAR=$(jq -r '(.similar_bugs // []) | length' claude-structured.json 2>/dev/null | tr -d '\r' || true)
  REPO=$(jq -r '(.locations // [])[0].repository // ""' claude-structured.json 2>/dev/null | tr -d '\r' || true)

  if [ "$CONFIDENCE" != "high" ]; then
    FIX_WHY="confidence is '${CONFIDENCE:-unstated}', not high"
    return 1
  fi
  # Any note_kind at all is the analysis saying "this is not a plain defect in code I could read":
  # the cause is elsewhere, or it may be intended, or the report is too thin.
  if [ -n "$NOTE_KIND" ]; then
    FIX_WHY="the analysis flagged '$NOTE_KIND'"
    return 1
  fi
  if [ -n "$MISSING" ]; then
    FIX_WHY="the analysis places the cause in code it was not given ($MISSING)"
    return 1
  fi
  # Resembling an existing bug is the analysis saying somebody may already have dealt with this.
  if [ "${SIMILAR:-0}" != "0" ]; then
    FIX_WHY="the analysis found a resembling bug"
    return 1
  fi
  if [ -z "$REPO" ]; then
    FIX_WHY="the analysis named no repository"
    return 1
  fi

  # Only an open bug: a fix proposed for one already resolved is noise on a closed thread.
  local STATUS_WORD="${BUG_STATUS%%/*}"
  case "${STATUS_WORD^^}" in
    NEW|UNCONFIRMED|CONFIRMED|ASSIGNED|IN_PROGRESS|REOPENED) ;;
    *)
      FIX_WHY="the bug is ${BUG_STATUS:-of unknown status}, not open"
      return 1
      ;;
  esac

  # The allowlist lives in the private routing map, beside the routing itself, so widening it is one
  # edit there and never a change to this public repository.
  if ! jq -e --arg repo "$REPO" '(.pr_repos // []) | map(ascii_downcase) | index($repo | ascii_downcase)' \
       product-repos.json > /dev/null 2>&1; then
    FIX_WHY="$REPO is not on the pr_repos list"
    return 1
  fi

  local CLONED_NAME CLONED_REF
  CLONED_NAME=$(awk -F@ -v r="$REPO" 'tolower($1) == tolower(r) { print $1; exit }' repos-cloned.txt 2>/dev/null || true)
  CLONED_REF=$(awk -F@ -v r="$REPO" 'tolower($1) == tolower(r) { print substr($0, index($0, "@") + 1); exit }' repos-cloned.txt 2>/dev/null || true)
  if [ -z "$CLONED_NAME" ] || [ -z "$CLONED_REF" ] || [ "$CLONED_REF" = "unknown" ]; then
    FIX_WHY="$REPO was not cloned on a known branch"
    return 1
  fi

  FIX_REPO="$CLONED_NAME"
  FIX_REF="$CLONED_REF"
  return 0
}

# The fix prompt, rendered like the analysis one. The analysis is model output that was itself
# shaped by the bug text, so it goes in escaped and inside a data-only block, same as everything
# else that reaches a prompt from outside.
render_fix_prompt() {
  local ANALYSIS BUGZILLA_CONTEXT
  ANALYSIS=$(jq -r '
    "Cause (" + (.summary.confidence // "?") + " confidence): " + (.summary.probable_cause // "")
    + "\n\nLocations, best first:\n"
    + ((.locations // []) | map("- " + (.repository // "?") + " " + (.path // "?")
        + (if .line then ":" + (.line | tostring) else "" end)
        + (if .why then "  " + .why else "" end)) | join("\n"))
    + (if .next_steps then "\n\nChecks suggested: " + .next_steps else "" end)
    | gsub("<"; "&lt;") | gsub(">"; "&gt;")' claude-structured.json 2>/dev/null | tr -d '\r' || true)
  if [ -z "$ANALYSIS" ]; then
    echo "::warning::Could not read the analysis back for the fix prompt"
    return 1
  fi
  BUGZILLA_CONTEXT=$(cat bug-context.txt 2>/dev/null || true)
  export BUG_ID BUG_URL PRODUCT COMPONENT BUGZILLA_CONTEXT ANALYSIS FIX_REPO FIX_REF
  envsubst '$BUG_ID $BUG_URL $PRODUCT $COMPONENT $BUGZILLA_CONTEXT $ANALYSIS $FIX_REPO $FIX_REF' \
    < triage/FIX.md > fix-prompt.txt
  echo "Fix prompt rendered: $(wc -c < fix-prompt.txt | tr -d ' ') bytes"
}

# Never fatal: the analysis is already written, and a fix that cannot be attempted changes nothing
# about it. Runs in the "Run triage" step, so the sandbox and its trap are still in place.
attempt_fix() {
  if ! fix_eligibility; then
    echo "No fix attempted: $FIX_WHY"
    return 0
  fi
  echo "Attempting a fix in $FIX_REPO @ $FIX_REF"
  if ! render_fix_prompt; then
    return 0
  fi
  printf '%s\t%s\n' "$FIX_REPO" "$FIX_REF" > fix-target.txt
  run_claude_fix || echo "::warning::The fix attempt failed - the analysis stands on its own"
  return 0
}

# One line per problem, appended: several stages can each have something a person should hear.
_fix_notice() {
  echo "$1" >> pipeline-notice.txt
}

_fix_api() {
  local METHOD="$1" API_PATH="$2"
  shift 2
  curl -s --max-time 30 -X "$METHOD" -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" "https://$GITEA_HOST/api/v1$API_PATH" "$@"
}

# Turns the collected patch into a draft pull request. Its own step, and the only one that holds a
# token able to push. Every early return is a quiet one: no patch is the normal outcome.
open_fix_pr() {
  if [ ! -s claude-output/fix.patch ] || [ ! -s claude-fix-structured.json ] || [ ! -s fix-target.txt ]; then
    echo "No fix patch to turn into a pull request"
    return 0
  fi
  local REPO REF
  REPO=$(cut -f1 fix-target.txt)
  REF=$(cut -f2 fix-target.txt)

  rm -rf fix-work
  if ! git clone --depth=1 --quiet --branch "$REF" "https://$GITEA_HOST/$TRIAGE_ORG/$REPO" "fix-work/$REPO" 2>/dev/null; then
    echo "::warning::Could not clone $REPO@$REF for the fix pull request"
    return 0
  fi

  local CHECK_RC=0 CHECK_OUT
  CHECK_OUT=$(python3 .gitea/scripts/check-fix-patch.py claude-output/fix.patch "fix-work/$REPO" 2> fix-check.err) || CHECK_RC=$?
  if [ "$CHECK_RC" = "3" ]; then
    echo "The fix session changed nothing - no pull request"
    return 0
  fi
  if [ "$CHECK_RC" != "0" ]; then
    echo "::warning::Fix patch not accepted: $(cat fix-check.err)"
    _fix_notice "fix patch for $REPO not accepted - $(head -1 fix-check.err | sed 's/^refused: //')"
    return 0
  fi
  echo "Fix patch accepted: $CHECK_OUT"

  local BRANCH="${FIX_BRANCH_PREFIX}${BUG_ID}" BRANCH_ENC
  BRANCH_ENC=${BRANCH//\//%2F}
  local EXISTS
  EXISTS=$(_fix_api GET "/repos/$TRIAGE_ORG/$REPO/branches/$BRANCH_ENC" -o /dev/null -w '%{http_code}' || true)
  if [ "$EXISTS" = "200" ]; then
    echo "Branch $BRANCH already exists in $REPO - not opening a second pull request"
    return 0
  fi
  # A cap on open proposals per repository: if nobody is reading them, more of them is not help.
  local OPEN_COUNT
  OPEN_COUNT=$(_fix_api GET "/repos/$TRIAGE_ORG/$REPO/pulls?state=open&limit=50" \
    | jq -r --arg p "$FIX_BRANCH_PREFIX" '[.[]? | select((.head.ref // "") | startswith($p))] | length' 2>/dev/null || echo 0)
  if [ "${OPEN_COUNT:-0}" -ge "${TRIAGE_FIX_MAX_OPEN:-5}" ]; then
    echo "$REPO already has $OPEN_COUNT open proposals from this pipeline - not adding another"
    _fix_notice "no fix pull request opened for $REPO: $OPEN_COUNT proposals from this pipeline are still open"
    return 0
  fi

  local TITLE SUMMARY UNVERIFIED SUBJECT
  TITLE=$(jq -r '.title // ""' claude-fix-structured.json | tr -d '\r' | tr '\n' ' ' | head -c 90 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  SUMMARY=$(jq -r '.summary // ""' claude-fix-structured.json | tr -d '\r')
  UNVERIFIED=$(jq -r '.not_verified // ""' claude-fix-structured.json | tr -d '\r')
  if [ -z "$TITLE" ] || [ -z "$SUMMARY" ]; then
    echo "::warning::The fix result has no title or summary - not opening a pull request"
    return 0
  fi
  # The commit subject follows the repositories' own convention for a bug fix. It is all the commit
  # carries on purpose: these repositories can be mirrored to a public host, and history travels
  # with the mirror while a pull request body does not.
  SUBJECT="fix Bug $BUG_ID - $TITLE"

  local GIT_ID=(-c "user.name=${TRIAGE_GIT_NAME:-Claude Bug Triage}" -c "user.email=${TRIAGE_GIT_EMAIL:-claude-triage@noreply.$GITEA_HOST}")
  if ! git -C "fix-work/$REPO" apply --index --whitespace=nowarn "$PWD/claude-output/fix.patch" 2>fix-apply.err; then
    echo "::warning::git apply failed after the check passed: $(head -c 200 fix-apply.err)"
    return 0
  fi
  git -C "fix-work/$REPO" checkout -q -b "$BRANCH"
  git -C "fix-work/$REPO" "${GIT_ID[@]}" commit -q -m "$SUBJECT"
  if ! git -C "fix-work/$REPO" push -q origin "$BRANCH" 2>fix-push.err; then
    echo "::warning::Could not push $BRANCH: $(head -c 200 fix-push.err)"
    _fix_notice "fix branch for $REPO could not be pushed"
    return 0
  fi

  local RUN_URL="" BODY PAYLOAD RESPONSE PR_URL
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    RUN_URL="https://$GITEA_HOST/${GITHUB_REPOSITORY:-$TRIAGE_ORG/ga-common}/actions/runs/$GITHUB_RUN_ID"
  fi
  BODY=$(printf '%s\n\n%s\n%s\n%s\n%s\n' \
    "**Automated proposal for Bug $BUG_ID.** Written by the Claude Bug Triage pipeline and **not reviewed by a person**; treat it as a suggestion to check, not a change to trust." \
    "**What it does:** $SUMMARY" \
    "${UNVERIFIED:+**Not verified:** $UNVERIFIED}" \
    "**Analysed at:** \`$REPO@$REF\` - this branch is based on it; port it to another line if the fix belongs there." \
    "${RUN_URL:+**Run:** $RUN_URL}")
  # The WIP: prefix is what makes Gitea treat this as a draft, which it will not let anyone merge
  # until the prefix is removed - a deliberate second step by a person.
  PAYLOAD=$(jq -n --arg title "WIP: $SUBJECT" --arg head "$BRANCH" --arg base "$REF" --arg body "$BODY" \
    '{title: $title, head: $head, base: $base, body: $body}')
  RESPONSE=$(_fix_api POST "/repos/$TRIAGE_ORG/$REPO/pulls" -d "$PAYLOAD" || true)
  PR_URL=$(jq -r '.html_url // empty' <<< "$RESPONSE" 2>/dev/null | tr -d '\r' || true)
  if [ -z "$PR_URL" ]; then
    echo "::warning::The branch was pushed but the pull request was not created: $(head -c 200 <<< "$RESPONSE")"
    _fix_notice "fix branch $BRANCH pushed to $REPO but the pull request was not created"
    return 0
  fi
  echo "$PR_URL" > fix-pr-url.txt
  echo "Opened draft pull request: $PR_URL"
  _fix_notice "opened a draft pull request with a proposed fix: $PR_URL"
  return 0
}
