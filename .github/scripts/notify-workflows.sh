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
# for recent failures; fills the _STATUS/_ORDER nameref arrays with status
# lines. When optional-child-regex is set, host/path is treated as a multibranch
# parent and the newest semantic-versioned matching child job is checked.
# Jenkins API errors are rendered as no data, so one unreachable server does
# not break the digest.
check_jenkins_jobs() {
  local -n _STATUS=$1 _ORDER=$2
  [[ -z "${BUILDSERVER_JOBS:-}" ]] && return

  local LAST_GROUP=""
  local -a PIDS=() JOB_GROUPS=() NAMES=() URLS=() TMPS=()
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
  done <<< "$BUILDSERVER_JOBS"

  local i RAW FAIL_COUNT LATEST_DATE ICON SAFE_NAME SAFE_URL
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || true
    RAW="$(cat "${TMPS[$i]}")"; rm -f "${TMPS[$i]}"
    GROUP="${JOB_GROUPS[$i]}"; NAME="${NAMES[$i]}"; URL="${URLS[$i]}"
    SAFE_NAME="$(html_escape "$NAME")"; SAFE_URL="$(html_escape "$URL")"

    FAIL_COUNT="$(jq -r --arg cutoff "$T24" '
      [.builds[]?
        | select(.building != true)
        | select((((.timestamp // 0) / 1000) | strftime("%Y-%m-%dT%H:%M:%SZ")) >= $cutoff)
        | select((.result // "") | test("FAILURE|UNSTABLE|ABORTED|NOT_BUILT"))]
      | length
    ' <<< "$RAW" 2>/dev/null || echo '')"
    LATEST_DATE="$(jq -r '
      (.builds // [])
      | map(select(.timestamp != null))
      | .[0].timestamp // empty
      | if . == "" then "" else ((. / 1000) | strftime("%Y-%m-%dT%H:%M:%SZ")) end
    ' <<< "$RAW" 2>/dev/null || echo '')"

    if [[ -z "$FAIL_COUNT" || -z "$LATEST_DATE" ]]; then
      ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
      _STATUS["$GROUP"]+="$ICON <a href=\"$SAFE_URL\">$SAFE_NAME</a> (no data)\n"
      continue
    fi

    if [[ "$LATEST_DATE" < "$T30" ]]; then
      ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
      _STATUS["$GROUP"]+="$ICON <a href=\"$SAFE_URL\">$SAFE_NAME</a>\n"
    elif (( FAIL_COUNT > 0 )); then
      ICON="🔴"; RED_COUNT=$((RED_COUNT + 1))
      local FAILED_BUILD BUILD_NUM BUILD_URL SAFE_BUILD_URL
      FAILED_BUILD="$(jq -c --arg cutoff "$T24" '
        (.builds // [])
        | map(select(.building != true)
          | select((((.timestamp // 0) / 1000) | strftime("%Y-%m-%dT%H:%M:%SZ")) >= $cutoff)
          | select((.result // "") | test("FAILURE|UNSTABLE|ABORTED|NOT_BUILT")))
        | .[0] // {}
      ' <<< "$RAW" 2>/dev/null || echo '{}')"
      BUILD_NUM="$(jq -r '.number // empty' <<< "$FAILED_BUILD" 2>/dev/null || true)"
      BUILD_URL="$(jq -r '.url // empty' <<< "$FAILED_BUILD" 2>/dev/null || true)"
      [[ -z "$BUILD_URL" ]] && BUILD_URL="$URL"
      SAFE_BUILD_URL="$(html_escape "$BUILD_URL")"
      _STATUS["$GROUP"]+="$ICON <a href=\"$SAFE_BUILD_URL\">$SAFE_NAME${BUILD_NUM:+ #$BUILD_NUM}</a>\n"
    else
      ICON="🟢"; GREEN_COUNT=$((GREEN_COUNT + 1))
      _STATUS["$GROUP"]+="$ICON <a href=\"$SAFE_URL\">$SAFE_NAME</a>\n"
    fi
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

  local WORKFLOWS_BLOCK BUILDERS_BLOCK
  WORKFLOWS_BLOCK="$(render_health_block "Workflows" "$MESSAGE")"

  declare -A jenkins_status
  local jenkins_order=()
  RED_COUNT=0 WHITE_COUNT=0 GREEN_COUNT=0
  check_jenkins_jobs jenkins_status jenkins_order

  MESSAGE=""
  for REPO in "${jenkins_order[@]}"; do MESSAGE+="<b>$REPO</b>\n${jenkins_status[$REPO]:-}\n"; done
  BUILDERS_BLOCK="$(render_health_block "Buildservers" "$MESSAGE")"

  [[ -z "$WORKFLOWS_BLOCK" && -z "$BUILDERS_BLOCK" ]] && return
  [[ -n "$WORKFLOWS_BLOCK" ]] && printf '%s' "$WORKFLOWS_BLOCK"
  [[ -n "$WORKFLOWS_BLOCK" && -n "$BUILDERS_BLOCK" ]] && printf '\n\n'
  [[ -n "$BUILDERS_BLOCK" ]] && printf '%s' "$BUILDERS_BLOCK"
}

# Fetches claude-review.yml run history for the last 7 days, reduces it to one
# "latest state" row per PR (verdict, severity/fixed counts, open errors), and
# renders the weekly stats digest — a <pre> block (PRs reviewed, pass/fail bar,
# one bar per severity) plus an error list and a collapsible PR list, both
# linking out. Echoes the finished HTML message, or nothing if there's no data.
render_claude_review() {
  local AUTH="token $GITEA_TOKEN"
  local API_BASE="https://$GITEA_HOST/api/v1/repos/${GITHUB_ORG}/ga-common"

  local RUNS_RAW RUNS_JSON
  RUNS_RAW="$(fetch "$AUTH" "$API_BASE/actions/runs?page=1&limit=100" "$T7")"
  RUNS_JSON="$(jq -c --arg t "$T7" --arg wf "claude-review.yml" '
    (.workflow_runs // []) as $r
    | [$r[] | select(.status=="completed")
      | select((.path//"" | split("@")[0] | (. == $wf or endswith("/"+$wf))))
      | select((.created_at//.started_at//.updated_at//"") >= $t)
      | {id, display_title, html_url}]
  ' <<< "$RUNS_RAW" 2>/dev/null || echo '[]')"

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
  local -A PR_SEEN PR_VERDICT PR_CRIT PR_MED PR_LOW PR_LEG PR_FIXED PR_ERRORS PR_ERR_LINK PR_LINK
  local -A PR_FIXED_CRIT PR_FIXED_MED PR_FIXED_LOW PR_FIXED_LEG
  local -a PR_ORDER=()

  local i LOG REPO PR KEY VERDICT COUNTS_LINE C M L G P F
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || true
    LOG="$(cat "${TMPS[$i]}")"; rm -f "${TMPS[$i]}"
    TITLE="${TITLES[$i]}"; RUN_URL="${URLS[$i]}"
    REPO="$(grep -oP "${GITHUB_ORG}/\K[^#]+" <<< "$TITLE" || true)"
    PR="$(grep -oP '#\K[0-9]+' <<< "$TITLE" || true)"
    [[ -z "$REPO" || -z "$PR" ]] && continue
    KEY="${REPO}#${PR}"

    if [[ -z "${PR_SEEN[$KEY]:-}" ]]; then
      PR_SEEN[$KEY]=1; PR_ORDER+=("$KEY")
      PR_FIXED[$KEY]=0; PR_ERRORS[$KEY]=0
      PR_FIXED_CRIT[$KEY]=0; PR_FIXED_MED[$KEY]=0; PR_FIXED_LOW[$KEY]=0; PR_FIXED_LEG[$KEY]=0
      PR_LINK[$KEY]="https://$GITEA_HOST/${GITHUB_ORG}/${REPO}/pulls/${PR}"
    fi

    VERDICT="$(grep -oP 'Verdict: \K\S+' <<< "$LOG" | head -1 || true)"
    # No "Verdict:" line at all means the review was legitimately skipped
    # (SHA already reviewed, base-branch sync merge, WIP title) — not an error.
    [[ -z "$VERDICT" ]] && continue
    if [[ "$VERDICT" == "none" ]]; then
      PR_ERRORS[$KEY]=$((${PR_ERRORS[$KEY]} + 1))
      [[ -z "${PR_ERR_LINK[$KEY]:-}" ]] && PR_ERR_LINK[$KEY]="$RUN_URL"
      continue
    fi

    # Only the latest run's state is used (see comment above) — Claude re-prints
    # every previously-Fixed entry in each new review, so summing Fixed across a
    # PR's runs would count the same fix multiple times.
    [[ -n "${PR_VERDICT[$KEY]:-}" ]] && continue
    C=0 M=0 L=0 G=0 P=0 F=0
    COUNTS_LINE="$(grep -P 'Critical.*Fixed' <<< "$LOG" | head -1 || true)"
    [[ -n "$COUNTS_LINE" ]] && read -r C M L G P F <<< "$(grep -oP '(?<=\*\*)\d+(?=\*\*)' <<< "$COUNTS_LINE" | tr '\n' ' ')"
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
  local V ERR_N LINK LABEL
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
      LABEL="$KEY"; [[ -n "$LINK" ]] && LABEL="<a href=\"${LINK}\">${KEY}</a>"
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
    STATS+="${R_COUNT} PRs reviewed\n"
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
    local -a SKEYS=()
    while IFS= read -r KEY; do
      [[ -n "$KEY" ]] && SKEYS+=("$KEY")
    done < <(printf '%s\n' "${PR_ORDER[@]}" | sort -f)

    local -a APL=()
    local ICN
    for KEY in "${SKEYS[@]}"; do
      V="${PR_VERDICT[$KEY]:-}"
      [[ -z "$V" ]] && continue
      ICN="✅"; [[ "$V" == "BLOCKED" ]] && ICN="❌"
      APL+=("${ICN} <a href=\"${PR_LINK[$KEY]:-}\">${KEY}</a>")
    done
    BLOCK+="<blockquote expandable>\n\n\n"
    for ENTRY in "${APL[@]}"; do
      BLOCK+="${ENTRY}\n"
    done
    BLOCK+="</blockquote>"
  fi

  printf '%b' "$BLOCK"
}
