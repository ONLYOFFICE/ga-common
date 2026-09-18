#!/usr/bin/env bash
# Helpers for the "Workflows notify" pipeline (health digest + Claude Review
# stats). Requires $GITEA_TOKEN, $GITEA_HOST, $GITHUB_TOKEN, $GITHUB_ORG,
# $WORKFLOWS and $WORKFLOWS_GITEA to be set. Optional buildserver support reads
# $BUILDSERVER_JOBS plus $BUILDSERVER_AUTH when authentication is required.
# Meant to be sourced from workflows-notify.yaml, not run standalone.

T24="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
T30="$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)"
T7="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
BRANCH_PATTERN="^(master|main|release/.+|hotfix/.+|develop)$"

JQ_QUERY='(if type=="object" then .workflow_runs//[] else [] end|if type!="array" then [] else . end) as $r
  |[$r[]?|select((.head_branch//"")|test($b))|select($wf==""
  or(.path//""|split("@")[0]|(. == $wf or endswith("/"+$wf))))] as $all
  |($all|map(select((.created_at//.started_at//.updated_at//"")>=$t))|if length>0 then . else $all[:1] end) as $runs
  |[($runs|map(select(.status=="completed" and (.conclusion//""
  |test("failure|failed|error|startup_failure|timed_out"))))|length),
  ($runs[0]|.created_at//.started_at//.updated_at//"")] | @tsv'

# Paginated Gitea/GitHub Actions runs fetch. CUTOFF (default $T24) controls how
# far back pagination continues; URLs without a page=N query run unpaginated.
fetch() {
  local AUTH="Authorization: $1" URL=$2 CUTOFF="${3:-$T24}"
  [[ ! "$URL" =~ \?page=[0-9]+ ]] && { curl -s --retry 3 --retry-delay 1 -H "$AUTH" "$URL"; return; }
  local ORIG="${BASH_REMATCH[0]}" TMP="$(mktemp)" PAGE=1 OLDEST
  while true; do
    curl -s --retry 3 --retry-delay 1 -H "$AUTH" "${URL/$ORIG/?page=$PAGE}" | jq -c '.workflow_runs[]?' 2>/dev/null >> "$TMP"
    OLDEST="$(tail -1 "$TMP" | jq -r '.created_at//.started_at//.updated_at//""' 2>/dev/null)"
    [[ -z "$OLDEST" || "$OLDEST" < "$CUTOFF" ]] && break; (( PAGE++ ))
  done
  jq -sc '{workflow_runs:.}' "$TMP"; rm -f "$TMP"
}

# Checks GitHub- or Gitea-hosted workflows listed (pipe-table on stdin) for
# recent failures; fills the _STATUS/_ORDER nameref arrays with 🟢/⚪️/🔴 lines.
check_workflows() {
  local -n _STATUS=$1 _ORDER=$2
  local AUTH=$3 API_FMT=$4 LINK_FMT=$5 BRANCH="${6:-$BRANCH_PATTERN}" LAST_REPO=""
  local -a PIDS=() REPOS=() WFS=() NAMES=() TMPS=() LINKS=()

  while IFS='|' read -r REPO WF NAME; do
    REPO="${REPO// }"; WF="${WF// }"; NAME="${NAME# }"; NAME="${NAME% }"
    [[ -z "$WF" ]] && continue
    [[ -n "$REPO" ]] && LAST_REPO="$REPO" || REPO="$LAST_REPO"; [[ -z "$REPO" ]] && continue
    [[ ! " ${_ORDER[*]} " =~ " $REPO " ]] && _ORDER+=("$REPO")
    [[ "$WF" != *.* ]] && WF="$WF.yml"
    local API="${API_FMT//__REPO__/$REPO}"; API="${API//__WF__/$WF}"
    local LINK="${LINK_FMT//__REPO__/$REPO}"; LINK="${LINK//__WF__/$WF}"
    local TMP; TMP="$(mktemp)"
    fetch "$AUTH" "$API" > "$TMP" &
    PIDS+=($!); REPOS+=("$REPO"); WFS+=("$WF"); NAMES+=("$NAME"); TMPS+=("$TMP"); LINKS+=("$LINK")
  done

  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}"
    local RAW; RAW="$(cat "${TMPS[$i]}")"; rm -f "${TMPS[$i]}"
    local FAIL_COUNT LATEST_DATE
    read -r FAIL_COUNT LATEST_DATE <<< "$(jq -re --arg t "$T24" --arg b "$BRANCH" --arg wf "${WFS[$i]}" "$JQ_QUERY" <<< "$RAW" 2>/dev/null||echo '')"
    [[ -z "$FAIL_COUNT" ]] && continue
    local ICON
    if   [[ -z "$LATEST_DATE" || "$LATEST_DATE" < "$T30" ]]; then ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
    elif (( FAIL_COUNT > 0 ));                                then ICON="🔴"; RED_COUNT=$((RED_COUNT + 1))
    else                                                           ICON="🟢"; GREEN_COUNT=$((GREEN_COUNT + 1)); fi
    _STATUS[${REPOS[$i]}]+="$ICON <a href=\"${LINKS[$i]}\">${NAMES[$i]}</a>\n"
  done
}

# Helpers for parsing buildserver rows and rendering Telegram HTML safely.
trim() {
  local VALUE="$1"
  VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
  VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
  printf '%s' "$VALUE"
}

html_escape() {
  local VALUE="${1:-}"
  VALUE="${VALUE//&/&amp;}"
  VALUE="${VALUE//</&lt;}"
  VALUE="${VALUE//>/&gt;}"
  VALUE="${VALUE//\"/&quot;}"
  printf '%s' "$VALUE"
}

buildserver_url() {
  local SERVER_VAR="$1" PATH_PART="${2:-}" BASE
  [[ "$SERVER_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ -n "${!SERVER_VAR+x}" ]] || return 1
  BASE="${!SERVER_VAR}"
  [[ -z "$BASE" ]] && return 1
  BASE="${BASE%/}"
  [[ -z "$PATH_PART" ]] && { printf '%s' "$BASE"; return; }
  PATH_PART="/${PATH_PART#/}"
  printf '%s' "${BASE}${PATH_PART%/}"
}

jenkins_fetch() {
  local URL="$1"
  local -a CURL_ARGS=(-fsS --globoff --retry 3 --retry-delay 1)
  local HOST USER TOKEN
  HOST="$(sed -E 's#^https?://([^/:]+).*#\1#' <<< "$URL")"
  if [[ -n "${BUILDSERVER_AUTH:-}" && -n "$HOST" ]]; then
    USER="$(jq -r --arg host "$HOST" '.[$host].user // empty' <<< "$BUILDSERVER_AUTH" 2>/dev/null || true)"
    TOKEN="$(jq -r --arg host "$HOST" '.[$host].token // empty' <<< "$BUILDSERVER_AUTH" 2>/dev/null || true)"
    [[ -n "$USER" && -n "$TOKEN" ]] && CURL_ARGS+=(-u "${USER}:${TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$URL"
}

# Checks Jenkins jobs listed as "group | name | server-url-env | path | optional-child-regex"
# and fills the _STATUS/_ORDER nameref arrays with status lines. Direct jobs are
# checked for recent failures. When optional-child-regex is set, host/path is
# treated as a multibranch parent and the latest completed build of the newest
# semantic-versioned matching child job is checked.
# Jenkins API errors are rendered as no data, so one unreachable server does
# not break the digest.
check_jenkins_jobs() {
  local -n _STATUS=$1 _ORDER=$2
  [[ -z "${BUILDSERVER_JOBS:-}" ]] && return

  local LAST_GROUP=""
  local -a PIDS=() JOB_GROUPS=() NAMES=() URLS=() TMPS=() BRANCH_SCOPED=()
  local GROUP NAME HOST PATH_PART CHILD_REGEX URL
  while IFS='|' read -r GROUP NAME HOST PATH_PART CHILD_REGEX; do
    GROUP="$(trim "$GROUP")"; NAME="$(trim "$NAME")"; HOST="$(trim "$HOST")"
    PATH_PART="$(trim "${PATH_PART:-}")"; CHILD_REGEX="$(trim "${CHILD_REGEX:-}")"
    [[ -z "$NAME" || -z "$HOST" ]] && continue
    [[ -n "$GROUP" ]] && LAST_GROUP="$GROUP" || GROUP="$LAST_GROUP"
    [[ -z "$GROUP" ]] && continue
    if ! URL="$(buildserver_url "$HOST" "$PATH_PART")"; then
      WHITE_COUNT=$((WHITE_COUNT + 1))
      _STATUS["$GROUP"]+="⚪️ $(html_escape "$NAME") (missing server URL: $(html_escape "$HOST"))\n"
      continue
    fi

    local SEEN=0 ITEM
    for ITEM in "${_ORDER[@]}"; do
      [[ "$ITEM" == "$GROUP" ]] && SEEN=1 && break
    done
    [[ "$SEEN" -eq 0 ]] && _ORDER+=("$GROUP")

    if [[ -n "$CHILD_REGEX" ]]; then
      local CHILDREN CHILD_COUNT=0 CHILD CHILD_NAME CHILD_URL CHILD_LABEL
      CHILDREN="$(jenkins_fetch "${URL%/}/api/json?tree=jobs[name,displayName,url]" 2>/dev/null || true)"
      if ! jq -e 'type == "object" and (.jobs | type == "array")' <<< "$CHILDREN" > /dev/null 2>&1; then
        WHITE_COUNT=$((WHITE_COUNT + 1))
        _STATUS["$GROUP"]+="⚪️ <a href=\"$(html_escape "$URL")\">$(html_escape "$NAME")</a> (no data)\n"
        continue
      fi
      while IFS= read -r CHILD; do
        CHILD_NAME="$(jq -r '.name // empty' <<< "$CHILD" 2>/dev/null || true)"
        CHILD_URL="$(jq -r '.url // empty' <<< "$CHILD" 2>/dev/null || true)"
        [[ -z "$CHILD_NAME" || -z "$CHILD_URL" ]] && continue
        CHILD_NAME="$(sed -E 's/%25/%/g; s/%2[Ff]/\//g' <<< "$CHILD_NAME")"
        CHILD_LABEL="$NAME: $CHILD_NAME"
        local TMP; TMP="$(mktemp)"
        ( jenkins_fetch "${CHILD_URL%/}/api/json?tree=builds[number,result,building,timestamp,url,duration]{0,10}" || true ) > "$TMP" &
        PIDS+=($!); JOB_GROUPS+=("$GROUP"); NAMES+=("$CHILD_LABEL"); URLS+=("$CHILD_URL"); TMPS+=("$TMP")
        BRANCH_SCOPED+=("true")
        CHILD_COUNT=$((CHILD_COUNT + 1))
      done < <(jq -c --arg pattern "$CHILD_REGEX" '
        def norm: gsub("%25"; "%") | gsub("%2[Ff]"; "/");
        def version_key:
          ((.name // "") | norm | capture("v(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)")? // {major:"0", minor:"0", patch:"0"})
          | [.major, .minor, .patch] | map(tonumber);
        [.jobs[]?
          | {name:(.displayName // .name // ""), url:(.url // "")}
          | select(.url != "")
          | select((.name | norm) | test($pattern))]
        | sort_by(version_key)
        | reverse
        | .[:1][]
      ' <<< "$CHILDREN" 2>/dev/null || true)

      if [[ "$CHILD_COUNT" -eq 0 ]]; then
        WHITE_COUNT=$((WHITE_COUNT + 1))
        _STATUS["$GROUP"]+="⚪️ <a href=\"$(html_escape "$URL")\">$(html_escape "$NAME")</a> (no matching jobs)\n"
      fi
      continue
    fi

    local TMP; TMP="$(mktemp)"
    ( jenkins_fetch "${URL%/}/api/json?tree=builds[number,result,building,timestamp,url,duration]{0,10}" || true ) > "$TMP" &
    PIDS+=($!); JOB_GROUPS+=("$GROUP"); NAMES+=("$NAME"); URLS+=("$URL"); TMPS+=("$TMP")
    BRANCH_SCOPED+=("false")
  done <<< "$BUILDSERVER_JOBS"

  local i RAW BUILD_REPORT LATEST_DATE REPORT_STATUS ICON SAFE_NAME SAFE_URL
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || true
    RAW="$(cat "${TMPS[$i]}")"; rm -f "${TMPS[$i]}"
    GROUP="${JOB_GROUPS[$i]}"; NAME="${NAMES[$i]}"; URL="${URLS[$i]}"
    SAFE_NAME="$(html_escape "$NAME")"; SAFE_URL="$(html_escape "$URL")"

    BUILD_REPORT="$(jq -c --arg cutoff "$T24" --arg branch_scoped "${BRANCH_SCOPED[$i]}" '
      def completed: select(.building != true and (.result // "") != "");
      def iso_date: (((.timestamp // 0) / 1000) | strftime("%Y-%m-%dT%H:%M:%SZ"));
      if $branch_scoped == "true" then
        ((.builds // []) | map(completed) | max_by([(.timestamp // 0), (.number // 0)])) as $build
        | {timestamp:$build.timestamp, status:$build.result, build:$build}
      else
        ((.builds // []) | map(select(.timestamp != null)) | .[0]) as $latest
        | ((.builds // []) | map(completed) | length > 0) as $has_completed
        | ((.builds // [])
          | map(completed
            | select(iso_date >= $cutoff)
            | select((.result // "") | test("FAILURE|UNSTABLE|ABORTED|NOT_BUILT")))
          | .[0]) as $failed
        | {
            timestamp:$latest.timestamp,
            status:(if $has_completed == false then null elif $failed == null then "SUCCESS" else "FAILURE" end),
            build:$failed
          }
      end
    ' <<< "$RAW" 2>/dev/null || echo '{}')"
    LATEST_DATE="$(jq -r '
      .timestamp // empty
      | if . == "" then "" else ((. / 1000) | strftime("%Y-%m-%dT%H:%M:%SZ")) end
    ' <<< "$BUILD_REPORT" 2>/dev/null || echo '')"
    REPORT_STATUS="$(jq -r '.status // empty' <<< "$BUILD_REPORT" 2>/dev/null || true)"

    if [[ -z "$LATEST_DATE" || -z "$REPORT_STATUS" ]]; then
      ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
      _STATUS["$GROUP"]+="$ICON <a href=\"$SAFE_URL\">$SAFE_NAME</a> (no data)\n"
      continue
    fi

    local BUILD_NUM BUILD_URL SAFE_BUILD_URL
    BUILD_NUM="$(jq -r '.build.number // empty' <<< "$BUILD_REPORT" 2>/dev/null || true)"
    BUILD_URL="$(jq -r '.build.url // empty' <<< "$BUILD_REPORT" 2>/dev/null || true)"
    [[ -z "$BUILD_URL" ]] && BUILD_URL="$URL"
    SAFE_BUILD_URL="$(html_escape "$BUILD_URL")"

    if [[ "$LATEST_DATE" < "$T30" ]]; then
      ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
    elif [[ "$REPORT_STATUS" == "SUCCESS" ]]; then
      ICON="🟢"; GREEN_COUNT=$((GREEN_COUNT + 1))
    elif [[ "$REPORT_STATUS" =~ ^(FAILURE|UNSTABLE)$ ]]; then
      ICON="🔴"; RED_COUNT=$((RED_COUNT + 1))
    else
      ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
    fi
    _STATUS["$GROUP"]+="$ICON <a href=\"$SAFE_BUILD_URL\">$SAFE_NAME${BUILD_NUM:+ #$BUILD_NUM}</a>\n"
  done
}

render_health_block() {
  local TITLE="$1" MESSAGE="$2"
  [[ -z "$MESSAGE" ]] && return

  local -a SUMMARY_PARTS=()
  (( GREEN_COUNT > 0 )) && SUMMARY_PARTS+=("${GREEN_COUNT} 🟢")
  (( WHITE_COUNT > 0 )) && SUMMARY_PARTS+=("${WHITE_COUNT} ⚪️")
  (( RED_COUNT > 0 )) && SUMMARY_PARTS+=("${RED_COUNT} 🔴")
  local SUMMARY="" PART
  for PART in "${SUMMARY_PARTS[@]}"; do
    [[ -n "$SUMMARY" ]] && SUMMARY+=" · "
    SUMMARY+="$PART"
  done

  printf '%b' "<pre>${TITLE}\n\n${SUMMARY}</pre><blockquote expandable>\n\n\n${MESSAGE}</blockquote>"
}

# Builds the health digest as separate "Workflows" and "Buildservers" blocks so
# GitHub/Gitea workflow status is not mixed with Jenkins job status.
build_workflows_report() {
  local WORKFLOWS_BLOCK="" BUILDERS_BLOCK=""

  if [[ "${PUBLISH_WORKFLOWS:-true}" == "true" ]]; then
    declare -A github_status gitea_status
    local github_order=() gitea_order=()
    RED_COUNT=0 WHITE_COUNT=0 GREEN_COUNT=0
    check_workflows github_status github_order "Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/${GITHUB_ORG}/__REPO__/actions/workflows/__WF__/runs?per_page=100" \
      "https://github.com/${GITHUB_ORG}/__REPO__/actions/workflows/__WF__" <<< "$WORKFLOWS"
    check_workflows gitea_status gitea_order "token $GITEA_TOKEN" \
      "https://$GITEA_HOST/api/v1/repos/${GITHUB_ORG}/__REPO__/actions/runs?page=1&limit=100" \
      "https://$GITEA_HOST/${GITHUB_ORG}/__REPO__/actions?workflow=__WF__" ".*" <<< "$WORKFLOWS_GITEA"

    local MESSAGE="" REPO
    declare -A seen
    local ALL_ORDER=()
    for REPO in "${github_order[@]}" "${gitea_order[@]}"; do
      [[ -n "${seen[$REPO]:-}" ]] && continue
      seen[$REPO]=1; ALL_ORDER+=("$REPO")
    done
    for REPO in "${ALL_ORDER[@]}"; do MESSAGE+="<b>$REPO</b>\n${github_status[$REPO]:-}${gitea_status[$REPO]:-}\n"; done

    WORKFLOWS_BLOCK="$(render_health_block "Workflows" "$MESSAGE")"
  fi

  if [[ "${PUBLISH_BUILDSERVERS:-true}" == "true" ]]; then
    declare -A jenkins_status
    local jenkins_order=() REPO
    RED_COUNT=0 WHITE_COUNT=0 GREEN_COUNT=0
    check_jenkins_jobs jenkins_status jenkins_order

    local MESSAGE=""
    for REPO in "${jenkins_order[@]}"; do MESSAGE+="<b>$REPO</b>\n${jenkins_status[$REPO]:-}\n"; done
    BUILDERS_BLOCK="$(render_health_block "Buildservers" "$MESSAGE")"
  fi

  [[ -z "$WORKFLOWS_BLOCK" && -z "$BUILDERS_BLOCK" ]] && return
  [[ -n "$WORKFLOWS_BLOCK" ]] && printf '%s' "$WORKFLOWS_BLOCK"
  [[ -n "$WORKFLOWS_BLOCK" && -n "$BUILDERS_BLOCK" ]] && printf '\n\n'
  [[ -n "$BUILDERS_BLOCK" ]] && printf '%s' "$BUILDERS_BLOCK"
}

# Fetches claude-review.yml run history for the configured period (day/week/
# month via $CLAUDE_REVIEW_PERIOD, default week), reduces it to one "latest
# state" row per PR (verdict, severity/fixed counts, open errors), and renders
# the stats digest — a <pre> block (run count, PRs reviewed, pass/fail bar,
# one bar per severity) plus an error list and a collapsible PR list, both
# linking out. Echoes the finished HTML message, or nothing if there's no data.
render_claude_review() {
  local AUTH="token $GITEA_TOKEN"
  local API_BASE="https://$GITEA_HOST/api/v1/repos/${GITHUB_ORG}/ga-common"

  local CUTOFF
  case "${CLAUDE_REVIEW_PERIOD:-week}" in
    day)   CUTOFF="$T24" ;;
    month) CUTOFF="$T30" ;;
    *)     CUTOFF="$T7" ;;
  esac

  local RUNS_RAW RUNS_JSON
  RUNS_RAW="$(fetch "$AUTH" "$API_BASE/actions/runs?page=1&limit=100" "$CUTOFF")"
  RUNS_JSON="$(jq -c --arg t "$CUTOFF" --arg wf "claude-review.yml" '
    (.workflow_runs // []) as $r
    | [$r[] | select(.status=="completed")
      | select((.path//"" | split("@")[0] | (. == $wf or endswith("/"+$wf))))
      | select((.created_at//.started_at//.updated_at//"") >= $t)
      | {id, display_title, html_url}]
  ' <<< "$RUNS_RAW" 2>/dev/null || echo '[]')"
  local RUN_COUNT; RUN_COUNT="$(jq 'length' <<< "$RUNS_JSON" 2>/dev/null || echo 0)"

  local -a PIDS=() TITLES=() URLS=() TMPS=()
  local RUN RUN_ID TITLE RUN_URL TMP
  while IFS= read -r RUN; do
    RUN_ID="$(jq -r '.id' <<< "$RUN")"
    TITLE="$(jq -r '.display_title' <<< "$RUN")"
    RUN_URL="$(jq -r '.html_url' <<< "$RUN")"
    TMP="$(mktemp)"
    (
      local JOB_ID
      JOB_ID="$(fetch "$AUTH" "$API_BASE/actions/runs/$RUN_ID/jobs" 2>/dev/null | jq -r '.jobs[0].id // empty' 2>/dev/null || echo '')"
      [[ -z "$JOB_ID" ]] && exit 0
      fetch "$AUTH" "$API_BASE/actions/jobs/$JOB_ID/logs" 2>/dev/null
    ) > "$TMP" &
    PIDS+=($!); TITLES+=("$TITLE"); URLS+=("$RUN_URL"); TMPS+=("$TMP")
  done < <(jq -c '.[]' <<< "$RUNS_JSON")

  # Runs are newest-first (fetch()/pagination assumes descending order), so the
  # first run seen for a given PR key is its latest run — used as current state
  # (verdict, severity counts, Fixed counts). Older runs for the same PR only
  # contribute to that PR's error count/link, since a run's Fixed count is
  # already a running total for the PR's whole lifetime, not one run.
  local -A PR_SEEN PR_VERDICT PR_CRIT PR_MED PR_LOW PR_LEG PR_FIXED PR_ERRORS PR_ERR_LINK
  local -A PR_FIXED_CRIT PR_FIXED_MED PR_FIXED_LOW PR_FIXED_LEG PR_DISPLAY_REPO
  local -a PR_ORDER=()

  # Duration is tracked per-run (not deduped by PR like the state above) —
  # every executed run consumed real CI time, including reruns on the same PR.
  local TOTAL_RUN_SECONDS=0 TOTAL_RUN_TIMED=0

  local i LOG REPO PR KEY VERDICT COUNTS_LINE C M L G F JOB_LINE
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || true
    LOG="$(cat "${TMPS[$i]}")"; rm -f "${TMPS[$i]}"
    TITLE="${TITLES[$i]}"; RUN_URL="${URLS[$i]}"
    # Title is the run-name, i.e. the raw pr_url ("https://HOST/ORG/REPO/pulls/N") since
    # display_name was dropped - match that first. Runs dispatched before that change (or
    # still in this window) may carry the legacy "ORG/REPO!N" / "ORG/REPO#N" label instead -
    # keep matching both shapes case-insensitively so historical and current runs both count.
    if [[ "$TITLE" =~ /([^/]+)/pulls/([0-9]+) ]]; then
      REPO="${BASH_REMATCH[1]}"; PR="${BASH_REMATCH[2]}"
    else
      REPO="$(grep -oiP "${GITHUB_ORG}/\K[^!#/]+" <<< "$TITLE" || true)"
      PR="$(grep -oP '[!#]\K[0-9]+' <<< "$TITLE" || true)"
    fi
    [[ -z "$REPO" || -z "$PR" ]] && continue
    # Same PR can show different repo casing across runs (Lambda-built URL vs. a
    # manually typed dispatch) - key on lowercase so they aggregate into one row,
    # but remember the first-seen casing (runs are processed newest-first, so
    # that's the latest run's casing) for display.
    KEY="$(tr '[:upper:]' '[:lower:]' <<< "$REPO")#${PR}"
    [[ -z "${PR_DISPLAY_REPO[$KEY]:-}" ]] && PR_DISPLAY_REPO[$KEY]="$REPO"

    if [[ -z "${PR_SEEN[$KEY]:-}" ]]; then
      PR_SEEN[$KEY]=1; PR_ORDER+=("$KEY")
      PR_FIXED[$KEY]=0; PR_ERRORS[$KEY]=0
      PR_FIXED_CRIT[$KEY]=0; PR_FIXED_MED[$KEY]=0; PR_FIXED_LOW[$KEY]=0; PR_FIXED_LEG[$KEY]=0
    fi

    VERDICT="$(grep -oP 'Verdict: \K\S+' <<< "$LOG" | head -1 || true)"
    # No "Verdict:" line at all means the review was legitimately skipped
    # (SHA already reviewed, base-branch sync merge, WIP title) — not an error.
    [[ -z "$VERDICT" ]] && continue

    # Wall-clock duration of this run (from post_review_and_set_status's
    # "Job: ... [Xm Ys]" line), regardless of verdict — every executed run
    # counts toward the average, including errored ones.
    JOB_LINE="$(grep -P 'Job: ' <<< "$LOG" | tail -1 || true)"
    if [[ "$JOB_LINE" =~ \[([0-9]+)m[[:space:]]([0-9]+)s\] ]]; then
      TOTAL_RUN_SECONDS=$((TOTAL_RUN_SECONDS + 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
      TOTAL_RUN_TIMED=$((TOTAL_RUN_TIMED + 1))
    fi

    if [[ "$VERDICT" == "none" ]]; then
      PR_ERRORS[$KEY]=$((${PR_ERRORS[$KEY]} + 1))
      [[ -z "${PR_ERR_LINK[$KEY]:-}" ]] && PR_ERR_LINK[$KEY]="$RUN_URL"
      continue
    fi

    # Only the latest run's state is used (see comment above) — Claude re-prints
    # every previously-Fixed entry in each new review, so summing Fixed across a
    # PR's runs would count the same fix multiple times.
    [[ -n "${PR_VERDICT[$KEY]:-}" ]] && continue
    C=0 M=0 L=0 G=0 F=0
    COUNTS_LINE="$(grep -P 'Critical.*Fixed' <<< "$LOG" | head -1 || true)"
    [[ -n "$COUNTS_LINE" ]] && read -r C M L G F <<< "$(grep -oP '(?<=\*\*)\d+(?=\*\*)' <<< "$COUNTS_LINE" | tr '\n' ' ')"
    PR_VERDICT[$KEY]="$VERDICT"
    PR_CRIT[$KEY]="$C"; PR_MED[$KEY]="$M"; PR_LOW[$KEY]="$L"; PR_LEG[$KEY]="$G"
    PR_FIXED[$KEY]="$F"
    # Each ⚪️ Fixed entry's summary carries its original severity, e.g.
    # "⚪️ Fixed [🔴 Critical]: Issue title" — count those to break Fixed down by severity.
    PR_FIXED_CRIT[$KEY]="$(grep -c -F 'Fixed [🔴' <<< "$LOG" || true)"
    PR_FIXED_MED[$KEY]="$(grep -c -F 'Fixed [🟡' <<< "$LOG" || true)"
    PR_FIXED_LOW[$KEY]="$(grep -c -F 'Fixed [🔵' <<< "$LOG" || true)"
    PR_FIXED_LEG[$KEY]="$(grep -c -F 'Fixed [🟣' <<< "$LOG" || true)"
  done

  local R_COUNT=0 R_APPROVE=0 R_BLOCKED=0
  local R_CRIT=0 R_MED=0 R_LOW=0 R_LEG=0
  local R_FCRIT=0 R_FMED=0 R_FLOW=0 R_FLEG=0
  local -a R_ERRLIST=()
  local V ERR_N LINK LABEL DKEY
  for KEY in "${PR_ORDER[@]}"; do
    V="${PR_VERDICT[$KEY]:-}"
    if [[ -n "$V" ]]; then
      R_COUNT=$((R_COUNT + 1))
      [[ "$V" == "APPROVE" ]] && R_APPROVE=$((R_APPROVE + 1))
      [[ "$V" == "BLOCKED" ]] && R_BLOCKED=$((R_BLOCKED + 1))
      R_CRIT=$((R_CRIT + ${PR_CRIT[$KEY]:-0})); R_MED=$((R_MED + ${PR_MED[$KEY]:-0}))
      R_LOW=$((R_LOW + ${PR_LOW[$KEY]:-0})); R_LEG=$((R_LEG + ${PR_LEG[$KEY]:-0}))
      R_FCRIT=$((R_FCRIT + ${PR_FIXED_CRIT[$KEY]:-0})); R_FMED=$((R_FMED + ${PR_FIXED_MED[$KEY]:-0}))
      R_FLOW=$((R_FLOW + ${PR_FIXED_LOW[$KEY]:-0})); R_FLEG=$((R_FLEG + ${PR_FIXED_LEG[$KEY]:-0}))
    fi
    ERR_N="${PR_ERRORS[$KEY]:-0}"; LINK="${PR_ERR_LINK[$KEY]:-}"
    if (( ERR_N > 0 )); then
      DKEY="${PR_DISPLAY_REPO[$KEY]}#${KEY##*#}"
      LABEL="$DKEY"; [[ -n "$LINK" ]] && LABEL="<a href=\"${LINK}\">${DKEY}</a>"
      R_ERRLIST+=("$LABEL")
    fi
  done
  local R_ERRCOUNT="${#R_ERRLIST[@]}"
  (( R_COUNT == 0 && R_ERRCOUNT == 0 )) && return

  local BLOCK="" STATS="Claude Review\n\n"
  if (( R_COUNT > 0 )); then
    local BAR_LEN=10
    local FILLED=$(( (BAR_LEN * R_APPROVE) / R_COUNT ))
    local EMPT=$((BAR_LEN - FILLED))
    local BAR="" BI
    for ((BI = 0; BI < FILLED; BI++)); do BAR+="█"; done
    for ((BI = 0; BI < EMPT; BI++)); do BAR+="░"; done
    local AVG_PART=""
    (( TOTAL_RUN_TIMED > 0 )) && AVG_PART=" · $((TOTAL_RUN_SECONDS / TOTAL_RUN_TIMED))s"
    STATS+="${R_COUNT} PRs · ${RUN_COUNT} runs${AVG_PART}\n"
    local APAD; APAD="$(printf '%-2s' "$R_APPROVE")"
    STATS+="${BAR} ${APAD} ✔️ · ${R_BLOCKED}  ✖️\n"
    STATS+="Bugs\n"

    # One bar per severity: filled = fixed / (open + fixed). The severity emoji
    # sits after the count (replacing the word "found") so every bar starts in
    # the same column; rows with nothing open and nothing fixed are omitted.
    r_sev_bar() {
      local EMOJI="$1" FIXEDN="$3" TOTAL=$(($2 + $3))
      (( TOTAL == 0 )) && return
      local SL=10
      local SF=$(( (SL * FIXEDN) / TOTAL ))
      local SE=$((SL - SF))
      local SB="" k
      for ((k = 0; k < SF; k++)); do SB+="█"; done
      for ((k = 0; k < SE; k++)); do SB+="░"; done
      local TP; TP="$(printf '%-2s' "$TOTAL")"
      STATS+="${SB} ${TP} ${EMOJI} ￫ ${FIXEDN} fixed\n"
    }
    r_sev_bar "🔴" "$R_CRIT" "$R_FCRIT"
    r_sev_bar "🟡" "$R_MED" "$R_FMED"
    r_sev_bar "🔵" "$R_LOW" "$R_FLOW"
    r_sev_bar "🟣" "$R_LEG" "$R_FLEG"
  fi

  # The stats block is plain text with no nested HTML entities, so it can be
  # wrapped in one <pre> block for a bordered, copyable, monospace-aligned box.
  # The error list and PR list below contain <a href> links and must stay
  # outside any code/pre tag, since Telegram doesn't allow nested entities there.
  BLOCK+="<pre>${STATS}</pre>"

  if (( R_ERRCOUNT > 0 )); then
    [[ "$R_COUNT" -gt 0 ]] && BLOCK+="\n"
    BLOCK+="⚠️ ${R_ERRCOUNT} PR(s) with errors:\n"
    local ENTRY
    for ENTRY in "${R_ERRLIST[@]}"; do
      BLOCK+="${ENTRY}\n"
    done
  fi

  if (( R_COUNT > 0 )); then
    # Per-repo rollup instead of a flat PR list: strip "#PR" off each key
    # (REPO#PR) to get the repo, tally the PR count and bug severity/fixed counts
    # per repo (same fields as the global STATS bars above, just scoped).
    # Approve/blocked is deliberately not repeated here — the global bar already
    # carries it, and per repo it only crowded the line.
    local -A REPO_TOTAL
    local -A REPO_CRIT REPO_MED REPO_LOW REPO_LEG
    local -A REPO_FCRIT REPO_FMED REPO_FLOW REPO_FLEG
    local -a REPO_ORDER=()
    local REPO
    for KEY in "${PR_ORDER[@]}"; do
      V="${PR_VERDICT[$KEY]:-}"
      [[ -z "$V" ]] && continue
      REPO="${PR_DISPLAY_REPO[$KEY]}"
      [[ -z "${REPO_TOTAL[$REPO]:-}" ]] && REPO_ORDER+=("$REPO")
      REPO_TOTAL[$REPO]=$(( ${REPO_TOTAL[$REPO]:-0} + 1 ))
      REPO_CRIT[$REPO]=$(( ${REPO_CRIT[$REPO]:-0} + ${PR_CRIT[$KEY]:-0} ))
      REPO_MED[$REPO]=$(( ${REPO_MED[$REPO]:-0} + ${PR_MED[$KEY]:-0} ))
      REPO_LOW[$REPO]=$(( ${REPO_LOW[$REPO]:-0} + ${PR_LOW[$KEY]:-0} ))
      REPO_LEG[$REPO]=$(( ${REPO_LEG[$REPO]:-0} + ${PR_LEG[$KEY]:-0} ))
      REPO_FCRIT[$REPO]=$(( ${REPO_FCRIT[$REPO]:-0} + ${PR_FIXED_CRIT[$KEY]:-0} ))
      REPO_FMED[$REPO]=$(( ${REPO_FMED[$REPO]:-0} + ${PR_FIXED_MED[$KEY]:-0} ))
      REPO_FLOW[$REPO]=$(( ${REPO_FLOW[$REPO]:-0} + ${PR_FIXED_LOW[$KEY]:-0} ))
      REPO_FLEG[$REPO]=$(( ${REPO_FLEG[$REPO]:-0} + ${PR_FIXED_LEG[$KEY]:-0} ))
    done

    # Busiest repos (by PR count) first, alphabetical among ties — surfaces the
    # repos with the most review activity without needing to expand and scan.
    local -a SREPOS=()
    while IFS= read -r REPO; do
      [[ -n "$REPO" ]] && SREPOS+=("$REPO")
    done < <(
      for REPO in "${REPO_ORDER[@]}"; do
        printf '%d\t%s\n' "${REPO_TOTAL[$REPO]}" "$REPO"
      done | sort -t $'\t' -k1,1nr -k2,2f | cut -f2-
    )

    # One fixed-width slot per severity, appended to BUG_ROW in the caller's
    # scope. Every repo prints all four slots — "-" where nothing was found — so
    # the counts stay in the same column from row to row; dropping empty
    # severities is what made the list ragged. Padding is applied with ASCII
    # only: bash printf field widths count bytes, so a multibyte placeholder
    # would be padded short.
    repo_bug_slot() {
      local EMOJI="$1" OPEN="$2" FIXEDN="$3" TOTAL
      TOTAL=$((OPEN + FIXEDN))
      if (( TOTAL == 0 )); then
        BUG_ROW+="$(printf '%s %-6s' "$EMOJI" "-")"
      else
        BUG_ROW+="$(printf '%s %-6s' "$EMOJI" "${TOTAL}/${FIXEDN}")"
      fi
    }

    BLOCK+="<blockquote expandable>\n"
    BLOCK+="<i>reviewed PRs · bugs found/fixed</i>\n\n"
    for REPO in "${SREPOS[@]}"; do
      BLOCK+="<b><a href=\"https://${GITEA_HOST}/${GITHUB_ORG}/${REPO}\">${REPO}</a></b> · <code>${REPO_TOTAL[$REPO]}</code>\n"
      # The whole severity row is a single <code> span: the padding only lines
      # up if it sits inside one monospace entity, not per-severity pills.
      local BUG_ROW=""
      repo_bug_slot "🔴" "${REPO_CRIT[$REPO]:-0}" "${REPO_FCRIT[$REPO]:-0}"
      repo_bug_slot "🟡" "${REPO_MED[$REPO]:-0}" "${REPO_FMED[$REPO]:-0}"
      repo_bug_slot "🔵" "${REPO_LOW[$REPO]:-0}" "${REPO_FLOW[$REPO]:-0}"
      repo_bug_slot "🟣" "${REPO_LEG[$REPO]:-0}" "${REPO_FLEG[$REPO]:-0}"
      # Drop the padding of the last slot so the <code> background ends on a digit.
      if [[ "$BUG_ROW" =~ ^(.*[^[:space:]]) ]]; then BUG_ROW="${BASH_REMATCH[1]}"; fi
      BLOCK+="<code>${BUG_ROW}</code>\n\n"
    done
    BLOCK+="</blockquote>"
  fi

  printf '%b' "$BLOCK"
}
