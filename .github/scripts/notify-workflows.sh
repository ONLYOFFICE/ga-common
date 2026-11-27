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

# Prints "failures in 24h, newest run date, result, newest failed run URL, branches"; "-" marks an empty field.
# The result is a failure when the latest successful or failed run of any branch active in the last 24 hours
# failed (of the newest branch when none was active); the URL is given only when every such branch is green again.
# Branches ("f|s branch run-URL" items joined by \x1e, failing first) are listed for a red row or several branches.
JQ_QUERY='def run_date: .created_at//.started_at//.updated_at//"";
  def failed: .status=="completed" and (.conclusion//""|test("failure|failed|error|startup_failure|timed_out"));
  def decisive: map(select(failed or (.status=="completed" and .conclusion=="success")));
  (if type=="object" then .workflow_runs//[] else [] end|if type!="array" then [] else . end) as $r
  |[$r[]?|select((.head_branch//"")|test($b))|select($wf==""
  or(.path//""|split("@")[0]|(. == $wf or endswith("/"+$wf))))] as $all
  |($all|map(select(run_date>=$t))|decisive) as $recent
  |(if ($recent|length) > 0 then ($recent|group_by(.head_branch//"")|map(max_by(run_date)))
    else [$all|decisive|max_by(run_date)|select(. != null)] end) as $heads
  |(if any($heads[]; failed) then "failure" else "success" end) as $result
  |($all|map(select(run_date>=$t and failed))|sort_by(run_date)|reverse) as $fails
  |[($fails|length),
  ($all|map(run_date)|max|if . == null or . == "" then "-" else . end),
  $result,
  (if $result == "success" and ($fails|length) > 0 then ($fails[0].html_url//"-") else "-" end),
  (if $result == "failure" or ($heads|length) > 1 then
    ($heads|sort_by([(if failed then 0 else 1 end), (.head_branch//"")])
    |map("\(if failed then "f" else "s" end) \(.head_branch//"-") \(.html_url//"-")")|join("\u001e"))
  else "-" end)] | @tsv'

# Paginated Gitea/GitHub Actions runs fetch. CUTOFF (default $T24) controls how
# far back pagination continues; URLs without a page=N query run unpaginated.
fetch() {
  local AUTH="Authorization: $1" URL=$2 CUTOFF="${3:-$T24}"
  [[ ! "$URL" =~ \?page=[0-9]+ ]] && { curl -s --retry 3 --retry-delay 1 -H "$AUTH" "$URL"; return; }
  local ORIG="${BASH_REMATCH[0]}" TMP="$(mktemp)" PAGE=1 PAGE_RUNS NEWEST
  while true; do
    PAGE_RUNS="$(curl -fsS --retry 3 --retry-delay 1 -H "$AUTH" "${URL/$ORIG/?page=$PAGE}")" || { rm -f "$TMP"; return 1; }
    PAGE_RUNS="$(jq -c '.workflow_runs[]' <<< "$PAGE_RUNS")" || { rm -f "$TMP"; return 1; }
    [[ -z "$PAGE_RUNS" ]] && break
    printf '%s\n' "$PAGE_RUNS" >> "$TMP"
    # Gitea uses the Unix epoch for runs canceled before starting. A single
    # such run at the end of a page must not cut off the rest of the history.
    NEWEST="$(jq -sr 'map(.created_at//.started_at//.updated_at//"") | max // ""' <<< "$PAGE_RUNS")"
    [[ "$NEWEST" > "1970-01-02" && "$NEWEST" < "$CUTOFF" ]] && break
    (( PAGE++ ))
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
    local FAIL_COUNT LATEST_DATE LAST_STATUS FAILED_URL BRANCHES
    read -r FAIL_COUNT LATEST_DATE LAST_STATUS FAILED_URL BRANCHES <<< "$(jq -re --arg t "$T24" --arg b "$BRANCH" --arg wf "${WFS[$i]}" "$JQ_QUERY" <<< "$RAW" 2>/dev/null||echo '')"
    [[ -z "$FAIL_COUNT" ]] && continue
    [[ "$LATEST_DATE" == "-" ]] && LATEST_DATE=""
    [[ "$FAILED_URL" == "-" ]] && FAILED_URL=""
    # Failures already fixed by a later run of the same branch become a note instead of a red icon.
    local ICON FAILED_NOTE=""
    if   [[ -z "$LATEST_DATE" || "$LATEST_DATE" < "$T30" ]]; then ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
    elif [[ "$LAST_STATUS" == "failure" ]];                    then ICON="🔴"; RED_COUNT=$((RED_COUNT + 1))
    else                                                            ICON="🟢"; GREEN_COUNT=$((GREEN_COUNT + 1)); fi
    if [[ -n "$FAILED_URL" && "$FAIL_COUNT" =~ ^[1-9][0-9]*$ ]]; then
      FAILED_NOTE=" (<a href=\"$(html_escape "$FAILED_URL")\">${FAIL_COUNT} failed in 24h</a>)"
    fi
    _STATUS[${REPOS[$i]}]+="$ICON <a href=\"${LINKS[$i]}\">${NAMES[$i]}</a>${FAILED_NOTE}\n"
    # One indented line per branch under a red row or a row with several branches, not under a stale one.
    [[ "$ICON" == "⚪️" || -z "$BRANCHES" || "$BRANCHES" == "-" ]] && continue
    local BRANCH_STATE BRANCH_NAME BRANCH_URL BRANCH_ICON
    while read -r BRANCH_STATE BRANCH_NAME BRANCH_URL; do
      [[ -z "$BRANCH_NAME" ]] && continue
      # A run without a branch still decides the colour, so it is listed instead of skipped.
      [[ "$BRANCH_NAME" == "-" ]] && BRANCH_NAME="(no branch)"
      [[ "$BRANCH_URL" == "-" || -z "$BRANCH_URL" ]] && BRANCH_URL="${LINKS[$i]}"
      [[ "$BRANCH_STATE" == "f" ]] && BRANCH_ICON="🔴" || BRANCH_ICON="🟢"
      _STATUS[${REPOS[$i]}]+="    $BRANCH_ICON <a href=\"$(html_escape "$BRANCH_URL")\">$(html_escape "$BRANCH_NAME")</a>\n"
    done <<< "${BRANCHES//$'\x1e'/$'\n'}"
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
  # Quoted replacements: since bash 5.2 an unquoted & in the replacement stands for the matched text.
  VALUE="${VALUE//&/"&amp;"}"
  VALUE="${VALUE//</"&lt;"}"
  VALUE="${VALUE//>/"&gt;"}"
  VALUE="${VALUE//\"/"&quot;"}"
  printf '%s' "$VALUE"
}

# Count rendered text conservatively: entities may be overcounted, emoji use
# two UTF-16 units. printf matches the report renderer's escaped newlines.
telegram_text_length() {
  local BYTES
  BYTES="$(printf '%b' "$1" | sed 's/<[^>]*>//g' | iconv -f UTF-8 -t UTF-16LE | wc -c)"
  printf '%s' "$((BYTES / 2))"
}

# Send each report to every configured chat; a failed delivery must fail the job
# without preventing delivery to the remaining recipients.
send_telegram() {
  local MESSAGE CHAT_ID PAYLOAD FAILED=0
  for MESSAGE in "$@"; do
    [[ -z "$MESSAGE" ]] && continue
    echo "$MESSAGE"
    for CHAT_ID in ${TELEGRAM_CHAT_ID//,/ }; do
      PAYLOAD="$(jq -n --arg chat_id "$CHAT_ID" --arg text "$MESSAGE" \
        '{chat_id: ($chat_id|tonumber), text: $text, parse_mode: "HTML", disable_web_page_preview: true}')" || { FAILED=1; continue; }
      curl --fail-with-body -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" -d "$PAYLOAD" || FAILED=1
    done
    # Telegram recommends at most one message per second to the same chat.
    sleep 1
  done
  return "$FAILED"
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
# and fills the _STATUS/_ORDER nameref arrays with status lines. The icon follows
# the latest completed build; an earlier failure in the last 24 hours is shown as
# a linked note next to it. When optional-child-regex is set, host/path is
# treated as a multibranch parent and the newest semantic-versioned matching
# child job is checked.
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
      def build_key: [(.timestamp // 0), (.number // 0)];
      ((.builds // []) | map(completed)) as $done
      | ($done | max_by(build_key)) as $last
      | ($done | map(select(iso_date >= $cutoff and ((.result // "") | test("FAILURE|UNSTABLE|ABORTED|NOT_BUILT"))))) as $fails
      | ($fails | max_by(build_key)) as $failed
      | {
          # A direct job goes stale by its newest build, a running one included.
          timestamp:(if $branch_scoped == "true" then $last.timestamp
            else ((.builds // []) | map(select(.timestamp != null)) | max_by(.timestamp) | .timestamp) end),
          status:$last.result,
          build:$last,
          failed_count:($fails | length),
          failed_build:(if $failed != null and $failed.number != $last.number then $failed else null end)
        }
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

    local FAILED_COUNT FAILED_URL FAILED_NOTE=""
    FAILED_COUNT="$(jq -r '.failed_count // 0' <<< "$BUILD_REPORT" 2>/dev/null || echo 0)"
    FAILED_URL="$(jq -r '.failed_build.url // empty' <<< "$BUILD_REPORT" 2>/dev/null || true)"
    if [[ -n "$FAILED_URL" && "$FAILED_COUNT" =~ ^[1-9][0-9]*$ ]]; then
      FAILED_NOTE=" (<a href=\"$(html_escape "$FAILED_URL")\">${FAILED_COUNT} failed in 24h</a>)"
    fi

    if [[ "$LATEST_DATE" < "$T30" ]]; then
      ICON="⚪️"; WHITE_COUNT=$((WHITE_COUNT + 1))
    elif [[ "$REPORT_STATUS" == "SUCCESS" ]]; then
      ICON="🟢"; GREEN_COUNT=$((GREEN_COUNT + 1))
    else
      # FAILURE, UNSTABLE, ABORTED and NOT_BUILT alike, as in the failure note above.
      ICON="🔴"; RED_COUNT=$((RED_COUNT + 1))
    fi
    _STATUS["$GROUP"]+="$ICON <a href=\"$SAFE_BUILD_URL\">$SAFE_NAME${BUILD_NUM:+ #$BUILD_NUM}</a>${FAILED_NOTE}\n"
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
    # Per-workflow runs: the repository-wide list is mostly Claude Review, so a rare workflow fell outside the 24h pages.
    check_workflows gitea_status gitea_order "token $GITEA_TOKEN" \
      "https://$GITEA_HOST/api/v1/repos/${GITHUB_ORG}/__REPO__/actions/workflows/__WF__/runs?page=1&limit=50" \
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
  # An empty block makes the test above fail; the caller runs under bash -e, so the report must not end with that status
  return 0
}

# Newest Trivy result per branch in the last 24 hours, read from the annotations of the "Scan" jobs of the GitHub
# workflows in $TRIVY_SCANS ("repo | workflow | label"). Format written by DocSpace-buildtools trivy-scan.yml, keep in sync:
# title "Trivy <tag> (<branch>)", message "<image>: <n>C/<n>H[/<n>S] | <image>: ok | <image>: err | ...".
# Only counts are public there, so only counts are sent. Prints one HTML message, or nothing when no scan ran.
render_trivy_scans() {
  local AUTH="Authorization: Bearer $GITHUB_TOKEN" REPO WF LABEL LAST_REPO="" BODY="" RUNS RUN_ID JOBS JOB
  local RED=0 ORANGE=0 GREEN=0 FAILED=0 UNREADABLE=0 SCANS LINES ICON NAME TITLE URL DETAILS
  while IFS='|' read -r REPO WF LABEL; do
    REPO="$(trim "$REPO")"; WF="$(trim "$WF")"; LABEL="$(trim "$LABEL")"
    [[ -z "$WF" ]] && continue
    [[ -n "$REPO" ]] && LAST_REPO="$REPO" || REPO="$LAST_REPO"; [[ -z "$REPO" ]] && continue
    [[ "$WF" != *.* ]] && WF="$WF.yml"
    local API="https://api.github.com/repos/${GITHUB_ORG}/${REPO}" SCAN_FILE; SCAN_FILE="$(mktemp)"
    if ! RUNS="$(curl -fsS --retry 3 --retry-delay 1 -H "$AUTH" "$API/actions/workflows/$WF/runs?per_page=100&status=completed&created=%3E%3D$T24")"; then
      BODY+="<b>$(html_escape "${LABEL:-$REPO}")</b>\n⚪️ GitHub API unreadable\n\n"; UNREADABLE=$((UNREADABLE + 1)); rm -f "$SCAN_FILE"; continue
    fi
    for RUN_ID in $(jq -r '.workflow_runs[]?.id' <<< "$RUNS"); do
      JOBS="$(curl -fsS --retry 3 --retry-delay 1 -H "$AUTH" "$API/actions/runs/$RUN_ID/jobs?per_page=100")" || continue
      # The scan job is "Scan <tag>" in trivy-scan.yml, "<caller> / Scan <tag>" when another workflow calls it.
      for JOB in $(jq -r '.jobs[]? | select(.conclusion != "skipped" and (.name | test("(^|/ )Scan( |$)"))) | "\(.id)|\(.html_url)|\(.completed_at)"' <<< "$JOBS"); do
        curl -fsS --retry 3 --retry-delay 1 -H "$AUTH" "$API/check-runs/${JOB%%|*}/annotations" \
          | jq -c --arg url "$(cut -d'|' -f2 <<< "$JOB")" --arg done "${JOB##*|}" \
              '.[]? | select(.title // "" | startswith("Trivy ")) | {title, message, url: $url, done: $done}' >> "$SCAN_FILE" || true
      done
    done
    # One line per branch, newest scan wins: icon, branch, tag, findings (images without findings left out).
    LINES="$(jq -sr '
      map(. + ((.title | capture("^Trivy (?<tag>\\S+)( \\((?<branch>.+)\\))?$")) // {tag: .title, branch: null}))
      | map(.branch //= .tag) | group_by(.branch) | map(max_by(.done)) | sort_by(.branch)[]
      | (.message | split(" | ") | map(capture("^(?<image>[^:]+): (?<value>.+)$")) ) as $images
      | ([$images[] | select(.value == "err")] | length) as $errors
      | ([$images[] | .value | capture("^(?<c>[0-9]+)C") | .c | tonumber] | add // 0) as $critical
      | ([$images[] | select(.value != "ok" and .value != "err")] | length) as $dirty
      | [(if $errors > 0 then "⚠️" elif $critical > 0 then "🔴" elif $dirty > 0 then "🟠" else "🟢" end),
         .branch, .tag, .url,
         ([$images[] | select(.value != "ok") | "\(.image) \(.value | sub("^0C/"; ""))"] | join(" · ") | if . == "" then "clean" else . end)]
      | @tsv' "$SCAN_FILE" 2>/dev/null || true)"
    rm -f "$SCAN_FILE"
    [[ -z "$LINES" ]] && continue
    BODY+="<b>$(html_escape "${LABEL:-$REPO}")</b> · <a href=\"https://github.com/${GITHUB_ORG}/${REPO}/security/code-scanning?query=is%3Aopen+tool%3ATrivy\">code scanning</a>\n"
    while IFS=$'\t' read -r ICON NAME TITLE URL DETAILS; do
      case "$ICON" in 🔴) RED=$((RED + 1)) ;; 🟠) ORANGE=$((ORANGE + 1)) ;; 🟢) GREEN=$((GREEN + 1)) ;; *) FAILED=$((FAILED + 1)) ;; esac
      BODY+="$ICON <a href=\"$(html_escape "$URL")\">$(html_escape "$NAME")</a> <code>$(html_escape "$TITLE")</code>: $(html_escape "$DETAILS")\n"
    done <<< "$LINES"
    BODY+="\n"
  done <<< "${TRIVY_SCANS:-}"
  [[ -z "$BODY" ]] && return 0

  local -a PARTS=()
  (( RED > 0 )) && PARTS+=("${RED} 🔴")
  (( ORANGE > 0 )) && PARTS+=("${ORANGE} 🟠")
  (( GREEN > 0 )) && PARTS+=("${GREEN} 🟢")
  (( FAILED > 0 )) && PARTS+=("${FAILED} ⚠️")
  (( UNREADABLE > 0 )) && PARTS+=("${UNREADABLE} ⚪️")
  SCANS="$(IFS='|'; printf '%s' "${PARTS[*]}")"
  printf '%b' "<pre>Trivy (HIGH/CRITICAL with a fix)\n\n${SCANS//|/ · }</pre>\n${BODY%\\n}"
}

# Start of the window shared by the Claude Review and AI pipelines digests ($CLAUDE_REVIEW_PERIOD).
digest_cutoff() {
  case "${CLAUDE_REVIEW_PERIOD:-week}" in
    day)   printf '%s' "$T24" ;;
    month) printf '%s' "$T30" ;;
    *)     printf '%s' "$T7" ;;
  esac
}

# Prints the log of the first job of a ga-common run on Gitea; prints nothing when it cannot be read.
gitea_run_log() {
  local API_BASE="https://$GITEA_HOST/api/v1/repos/${GITHUB_ORG}/ga-common" AUTH="Authorization: token $GITEA_TOKEN" JOB_ID
  JOB_ID="$(curl -fsS --max-time 60 --retry 3 --retry-delay 1 -H "$AUTH" "$API_BASE/actions/runs/$1/jobs" 2>/dev/null \
    | jq -r '.jobs[0].id // empty' 2>/dev/null || true)"
  [[ -z "$JOB_ID" ]] && return 0
  curl -fsS --max-time 120 --retry 3 --retry-delay 1 -H "$AUTH" "$API_BASE/actions/jobs/$JOB_ID/logs" 2>/dev/null || true
}

# Prints the log of the job named $2 (else the first job) of a ga-common run on GitHub; nothing on error.
# Needs the actions: read permission; the logs endpoint redirects to blob storage, hence -L.
github_run_log() {
  local API_BASE="https://api.github.com/repos/${GITHUB_ORG}/ga-common/actions" AUTH="Authorization: Bearer $GITHUB_TOKEN" JOB_ID
  JOB_ID="$(curl -fsS --max-time 60 --retry 3 --retry-delay 1 -H "$AUTH" "$API_BASE/runs/$1/jobs" 2>/dev/null \
    | jq -r --arg name "${2:-}" '(.jobs // []) as $jobs | (($jobs | map(select(.name == $name))) + $jobs)[0].id // empty' 2>/dev/null || true)"
  [[ -z "$JOB_ID" ]] && return 0
  curl -fsSL --max-time 120 --retry 3 --retry-delay 1 -H "$AUTH" "$API_BASE/jobs/$JOB_ID/logs" 2>/dev/null || true
}

# Sums the amounts that follow the PCRE prefix $1 in a job log on stdin. The match is anchored right
# after the runner's timestamp, so a model excerpt quoted in the middle of a line does not count.
log_cost_sum() {
  { grep -oP "^\S+ +$1\K[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?" || true; } \
    | awk '{ sum += $1 } END { printf "%.4f", sum + 0 }'
}

# Adds up decimal amounts given as arguments.
sum_amounts() {
  printf '%s\n' "$@" | awk '{ sum += $1 } END { printf "%.4f", sum + 0 }'
}

# Fetches claude-review.yml run history for the configured period (day/week/
# month via $CLAUDE_REVIEW_PERIOD, default week), reduces it to one "latest
# state" row per PR (verdict, severity/fixed counts, open errors), and renders
# the stats digest — a <pre> block (run count, PRs reviewed, pass/fail bar,
# one bar per severity) plus an error list and a collapsible PR list, both
# linking out. Fills the array named by $1 with complete HTML messages; a long
# error list continues in further messages, while the per-repository PR list is
# cut to fit the message it follows.
render_claude_review() {
  local -n _REVIEW_MESSAGES=$1
  _REVIEW_MESSAGES=()
  local AUTH="token $GITEA_TOKEN"
  local API_BASE="https://$GITEA_HOST/api/v1/repos/${GITHUB_ORG}/ga-common"
  local MAX_LENGTH=3900 # Leave room for part numbers below Telegram's limit.

  local CUTOFF; CUTOFF="$(digest_cutoff)"

  local RUNS_RAW RUNS_JSON RUNS_OK=true
  RUNS_RAW="$(fetch "$AUTH" "$API_BASE/actions/runs?page=1&limit=100" "$CUTOFF")" || RUNS_OK=false
  RUNS_JSON="$(jq -c --arg t "$CUTOFF" --arg wf "claude-review.yml" '
    (.workflow_runs // []) as $r
    | [$r[] | select(.status=="completed")
      | select((.display_title // "") | startswith("Check") | not)
      | select((.path//"" | split("@")[0] | (. == $wf or endswith("/"+$wf))))
      | select((.created_at//.started_at//.updated_at//"") >= $t)
      | {id, display_title, html_url, conclusion}]
  ' <<< "$RUNS_RAW" 2>/dev/null || echo '[]')"
  local RUN_COUNT; RUN_COUNT="$(jq 'length' <<< "$RUNS_JSON" 2>/dev/null || echo 0)"

  local -a PIDS=() TITLES=() URLS=() TMPS=()
  local RUN RUN_ID TITLE RUN_URL TMP
  while IFS= read -r RUN; do
    RUN_ID="$(jq -r '.id' <<< "$RUN")"
    TITLE="$(jq -r '.display_title' <<< "$RUN")"
    RUN_URL="$(jq -r '.html_url' <<< "$RUN")"
    TMP="$(mktemp)"
    gitea_run_log "$RUN_ID" > "$TMP" &
    PIDS+=($!); TITLES+=("$TITLE"); URLS+=("$RUN_URL"); TMPS+=("$TMP")
  done < <(jq -c '.[]' <<< "$RUNS_JSON")

  # Spend for the AI pipelines digest, per run (not per PR): reruns and failed runs were paid for too.
  # The amounts come from review-run.sh's "Review OK: ..." and "Session cost: ..." lines - keep the wording in sync.
  local -a RUN_COSTS=()
  local RUN_UNREAD=0

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

  # Runs that fell back to the default Anthropic key, per repository: every such run is
  # a request to add a dedicated key. Counted per run and per distinct PR, before the
  # verdict check below, because skipped and failed runs asked for a key as well.
  local -A KEY_RUNS KEY_PRS KEY_PR_SEEN KEY_DISPLAY
  local -a KEY_ORDER=()

  local i LOG REPO PR KEY VERDICT COUNTS_LINE C M L G F JOB_LINE
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || true
    LOG="$(cat "${TMPS[$i]}")"; rm -f "${TMPS[$i]}"
    TITLE="${TITLES[$i]}"; RUN_URL="${URLS[$i]}"
    if [[ -z "$LOG" ]]; then
      RUN_UNREAD=$((RUN_UNREAD + 1))
    else
      RUN_COSTS+=("$(log_cost_sum '(?:Review OK|Session cost):[^$]*\$' <<< "$LOG")")
    fi
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

    # The line is printed by claude-review.yml's "Select API key" step - keep the wording in sync.
    # The job log also echoes that step's source, where the same text carries literal $ORG_NAME/$REPO_NAME, so only a filled-in ORG/REPO counts.
    if grep -qP 'No dedicated API key for [^\s$/]+/[^\s$]+ - using default key' <<< "$LOG"; then
      local KEY_REPO="${KEY%%#*}"
      if [[ -z "${KEY_RUNS[$KEY_REPO]:-}" ]]; then
        KEY_ORDER+=("$KEY_REPO"); KEY_DISPLAY[$KEY_REPO]="$REPO"
        KEY_RUNS[$KEY_REPO]=0; KEY_PRS[$KEY_REPO]=0
      fi
      KEY_RUNS[$KEY_REPO]=$((${KEY_RUNS[$KEY_REPO]} + 1))
      if [[ -z "${KEY_PR_SEEN[$KEY]:-}" ]]; then
        KEY_PR_SEEN[$KEY]=1
        KEY_PRS[$KEY_REPO]=$((${KEY_PRS[$KEY_REPO]} + 1))
      fi
    fi

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

  # Read by render_ai_pipelines, so the review logs are fetched once for both digests.
  if [[ "$RUNS_OK" == "true" ]]; then
    AI_REVIEW_RUNS="$RUN_COUNT"
    AI_REVIEW_FAILED="$(jq '[.[] | select(.conclusion == "failure")] | length' <<< "$RUNS_JSON" 2>/dev/null || echo 0)"
    AI_REVIEW_COST="$(sum_amounts "${RUN_COSTS[@]}")"
    AI_REVIEW_UNREAD="$RUN_UNREAD"
  else
    AI_REVIEW_RUNS="?"
  fi

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

  # Repositories that ran on the default key, as a collapsible quote placed right under
  # the stats box so it always lands in the first message, however long the lists below get.
  local KEYS_BLOCK=""
  if (( ${#KEY_ORDER[@]} > 0 )); then
    local KEY_REPO
    KEYS_BLOCK="<blockquote expandable>\n<i>⚠️ no dedicated Anthropic key · default key used</i>\n\n"
    local -a KEY_PARTS=()
    # Most requests first, alphabetical among ties.
    while IFS= read -r KEY_REPO; do
      [[ -n "$KEY_REPO" ]] && KEY_PARTS+=("$KEY_REPO")
    done < <(
      for KEY_REPO in "${KEY_ORDER[@]}"; do
        printf '%d\t%s\n' "${KEY_RUNS[$KEY_REPO]}" "$KEY_REPO"
      done | sort -t $'\t' -k1,1nr -k2,2f | cut -f2-
    )
    for KEY_REPO in "${KEY_PARTS[@]}"; do
      KEYS_BLOCK+="<a href=\"https://${GITEA_HOST}/${GITHUB_ORG}/${KEY_DISPLAY[$KEY_REPO]}\">${KEY_DISPLAY[$KEY_REPO]}</a> · runs: ${KEY_RUNS[$KEY_REPO]}, PRs: ${KEY_PRS[$KEY_REPO]}\n"
    done
    KEYS_BLOCK+="</blockquote>"
  fi

  if (( R_COUNT == 0 && R_ERRCOUNT == 0 )); then
    [[ -n "$KEYS_BLOCK" ]] && _REVIEW_MESSAGES+=("$(printf '%b' "<pre>Claude Review</pre>\n${KEYS_BLOCK}")")
    return
  fi

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
  # The trailing newline keeps this quote from fusing with the next one into a single quote.
  [[ -n "$KEYS_BLOCK" ]] && BLOCK+="\n${KEYS_BLOCK}\n"

  if (( R_ERRCOUNT > 0 )); then
    [[ "$R_COUNT" -gt 0 && -z "$KEYS_BLOCK" ]] && BLOCK+="\n"
    BLOCK+="⚠️ ${R_ERRCOUNT} PR(s) with errors:\n"
    local ENTRY
    for ENTRY in "${R_ERRLIST[@]}"; do
      if (( $(telegram_text_length "${BLOCK}${ENTRY}\n") > MAX_LENGTH )); then
        _REVIEW_MESSAGES+=("$(printf '%b' "$BLOCK")")
        BLOCK="<pre>Claude Review</pre>\n⚠️ Errors (continued):\n"
      fi
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

    # The rollup never spills into a message of its own: repos that do not fit are cut off (busiest ones are listed first).
    local REPO_HEADER="<blockquote expandable>\n<i>reviewed PRs · bugs found/fixed</i>\n\n"
    local BLOCK_BEFORE_ROLLUP="$BLOCK" REPOS_SHOWN=0
    BLOCK+="$REPO_HEADER"
    local REPO_ENTRY
    for REPO in "${SREPOS[@]}"; do
      REPO_ENTRY="<b><a href=\"https://${GITEA_HOST}/${GITHUB_ORG}/${REPO}\">${REPO}</a></b> · <code>${REPO_TOTAL[$REPO]}</code>\n"
      # The whole severity row is a single <code> span: the padding only lines
      # up if it sits inside one monospace entity, not per-severity pills.
      local BUG_ROW=""
      repo_bug_slot "🔴" "${REPO_CRIT[$REPO]:-0}" "${REPO_FCRIT[$REPO]:-0}"
      repo_bug_slot "🟡" "${REPO_MED[$REPO]:-0}" "${REPO_FMED[$REPO]:-0}"
      repo_bug_slot "🔵" "${REPO_LOW[$REPO]:-0}" "${REPO_FLOW[$REPO]:-0}"
      repo_bug_slot "🟣" "${REPO_LEG[$REPO]:-0}" "${REPO_FLEG[$REPO]:-0}"
      # Drop the padding of the last slot so the <code> background ends on a digit.
      if [[ "$BUG_ROW" =~ ^(.*[^[:space:]]) ]]; then BUG_ROW="${BASH_REMATCH[1]}"; fi
      REPO_ENTRY+="<code>${BUG_ROW}</code>\n\n"
      (( $(telegram_text_length "${BLOCK}${REPO_ENTRY}") > MAX_LENGTH )) && break
      BLOCK+="$REPO_ENTRY"
      REPOS_SHOWN=$((REPOS_SHOWN + 1))
    done
    if (( REPOS_SHOWN == 0 )); then
      BLOCK="$BLOCK_BEFORE_ROLLUP"
    else
      (( REPOS_SHOWN < ${#SREPOS[@]} )) && BLOCK+="<i>… +$((${#SREPOS[@]} - REPOS_SHOWN)) more</i>\n"
      BLOCK+="</blockquote>"
    fi
  fi

  _REVIEW_MESSAGES+=("$(printf '%b' "$BLOCK")")
  if (( ${#_REVIEW_MESSAGES[@]} > 1 )); then
    for i in "${!_REVIEW_MESSAGES[@]}"; do
      _REVIEW_MESSAGES[$i]="${_REVIEW_MESSAGES[$i]/Claude Review/Claude Review ($((i + 1))\/${#_REVIEW_MESSAGES[@]})}"
    done
  fi
}

# One digest for every AI pipeline of this repository: Claude Review, Bugzilla triage and the weekly
# release review on Gitea, the Jenkins build analysis on GitHub. Per pipeline: completed runs in the
# $CLAUDE_REVIEW_PERIOD window, failed runs, Claude spend summed from the cost lines each pipeline
# prints to its job log, and the pull requests it opened, with their state now. Fills the array
# named by $1 with one HTML message.
render_ai_pipelines() {
  local -n _AI_MESSAGES=$1
  _AI_MESSAGES=()
  local MAX_LENGTH=3900
  local CUTOFF; CUTOFF="$(digest_cutoff)"

  # Review numbers come from render_claude_review, which reads every review log anyway.
  if [[ -z "${AI_REVIEW_RUNS:-}" ]]; then
    local -a REVIEW_UNUSED=()
    render_claude_review REVIEW_UNUSED
  fi

  local -a PIPELINES=(Review Triage Weekly Jenkins)
  local -A RUNS=() FAILED=() COST=() UNREAD=() OPENED=()
  RUNS[Review]="${AI_REVIEW_RUNS:-?}"; FAILED[Review]="${AI_REVIEW_FAILED:-0}"
  COST[Review]="${AI_REVIEW_COST:-0}"; UNREAD[Review]="${AI_REVIEW_UNREAD:-0}"
  OPENED[Review]="-"; OPENED[Jenkins]="-"

  # Runs whose logs are read below, one "pipeline<TAB>platform<TAB>run id" entry each.
  local -a ENTRIES=()
  local RAW PIPE PLATFORM RUN_ID CONCLUSION

  if RAW="$(fetch "token $GITEA_TOKEN" "https://$GITEA_HOST/api/v1/repos/${GITHUB_ORG}/ga-common/actions/runs?page=1&limit=100" "$CUTOFF")"; then
    RUNS[Triage]=0; RUNS[Weekly]=0; OPENED[Triage]=0; OPENED[Weekly]=0
    while IFS=$'\t' read -r PIPE RUN_ID CONCLUSION; do
      [[ -z "$PIPE" ]] && continue
      ENTRIES+=("$PIPE"$'\t'"gitea"$'\t'"$RUN_ID")
      RUNS[$PIPE]=$((${RUNS[$PIPE]} + 1))
      [[ "$CONCLUSION" == "failure" ]] && FAILED[$PIPE]=$((${FAILED[$PIPE]:-0} + 1))
    done < <(jq -r --arg t "$CUTOFF" '
      .workflow_runs[]? | select(.status == "completed")
      | select((.created_at // .started_at // .updated_at // "") >= $t)
      | ((.path // "") | split("@")[0] | split("/") | last) as $wf
      | ({"bugzilla-triage.yml": "Triage", "weekly-review.yml": "Weekly"}[$wf]) as $pipeline
      | select($pipeline != null)
      | [$pipeline, .id, (.conclusion // "")] | @tsv
    ' <<< "$RAW" 2>/dev/null || true)
  else
    RUNS[Triage]="?"; RUNS[Weekly]="?"
  fi

  local GITHUB_RUNS_URL="https://api.github.com/repos/${GITHUB_ORG}/ga-common/actions/workflows/jenkins-analyze-build.yaml/runs?per_page=100&status=completed&created=%3E%3D${CUTOFF}"
  if RAW="$(curl -fsS --max-time 60 --retry 3 --retry-delay 1 -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_RUNS_URL")" \
    && jq -e '.workflow_runs | type == "array"' <<< "$RAW" > /dev/null 2>&1; then
    RUNS[Jenkins]=0
    while IFS=$'\t' read -r RUN_ID CONCLUSION; do
      [[ -z "$RUN_ID" ]] && continue
      ENTRIES+=("Jenkins"$'\t'"github"$'\t'"$RUN_ID")
      RUNS[Jenkins]=$((${RUNS[Jenkins]} + 1))
      [[ "$CONCLUSION" == "failure" ]] && FAILED[Jenkins]=$((${FAILED[Jenkins]:-0} + 1))
    done < <(jq -r '.workflow_runs[] | [.id, (.conclusion // "")] | @tsv' <<< "$RAW" 2>/dev/null || true)
  else
    RUNS[Jenkins]="?"
  fi

  local -a PIDS=() TMPS=()
  local ENTRY TMP
  for ENTRY in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r PIPE PLATFORM RUN_ID <<< "$ENTRY"
    TMP="$(mktemp)"
    if [[ "$PLATFORM" == "gitea" ]]; then
      gitea_run_log "$RUN_ID" > "$TMP" &
    else
      github_run_log "$RUN_ID" analyze > "$TMP" &
    fi
    PIDS+=($!); TMPS+=("$TMP")
  done

  # Cost lines per pipeline - keep the wording in sync with triage-run.sh ("Triage OK", "Fix session OK",
  # "Session cost"), weekly-review-run.sh ("[label] finished after ..., run total $X", cumulative, so the
  # last one counts) and jenkins-analyze-build.yaml ("select cost: X USD", "stage cost: X USD").
  local -a PR_REFS=() PR_PIPES=()
  local -A PR_SEEN=()
  local i LOG RUN_COST REF
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || true
    LOG="$(cat "${TMPS[$i]}")"; rm -f "${TMPS[$i]}"
    IFS=$'\t' read -r PIPE PLATFORM RUN_ID <<< "${ENTRIES[$i]}"
    if [[ -z "$LOG" ]]; then
      UNREAD[$PIPE]=$((${UNREAD[$PIPE]:-0} + 1))
      continue
    fi
    case "$PIPE" in
      Triage)  RUN_COST="$(log_cost_sum '(?:Triage OK|Fix session OK|Session cost):[^$]*\$' <<< "$LOG")" ;;
      Weekly)  RUN_COST="$({ grep -oP '^\S+ +\[[^]]+\] finished after .*run total \$\K[0-9]+(?:\.[0-9]+)?' <<< "$LOG" || true; } | tail -1)" ;;
      Jenkins) RUN_COST="$(log_cost_sum '(?:select|stage) cost: ' <<< "$LOG")" ;;
      *)       RUN_COST=0 ;;
    esac
    COST[$PIPE]="$(sum_amounts "${COST[$PIPE]:-0}" "${RUN_COST:-0}")"

    # "Opened (draft) pull request: URL" from triage-run.sh and weekly-review-run.sh. The host is
    # masked in the log as a secret, so only ORG/REPO/pulls/N is taken and the host is added back.
    while IFS= read -r REF; do
      [[ -z "$REF" || -n "${PR_SEEN[$REF]:-}" ]] && continue
      PR_SEEN[$REF]=1; PR_REFS+=("$REF"); PR_PIPES+=("$PIPE")
      OPENED[$PIPE]=$((${OPENED[$PIPE]:-0} + 1))
    done < <({ grep -oP '^\S+ +Opened (?:draft )?pull request: \K\S+' <<< "$LOG" || true; } \
      | { grep -oP '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pulls/[0-9]+$' || true; })
  done

  local -a STATE_PIDS=() STATE_TMPS=()
  for REF in "${PR_REFS[@]}"; do
    TMP="$(mktemp)"
    { curl -fsS --max-time 30 --retry 3 --retry-delay 1 -H "Authorization: token $GITEA_TOKEN" \
        "https://$GITEA_HOST/api/v1/repos/$REF" 2>/dev/null \
      | jq -r 'if .merged == true then "merged" else (.state // "unknown") end' 2>/dev/null || true; } > "$TMP" &
    STATE_PIDS+=($!); STATE_TMPS+=("$TMP")
  done
  local -a PR_STATES=()
  local -A STATE_COUNT=()
  local STATE
  for i in "${!STATE_PIDS[@]}"; do
    wait "${STATE_PIDS[$i]}" || true
    STATE="$(head -1 "${STATE_TMPS[$i]}")"; rm -f "${STATE_TMPS[$i]}"
    [[ "$STATE" =~ ^(open|merged|closed)$ ]] || STATE="unknown"
    PR_STATES+=("$STATE")
    STATE_COUNT[$STATE]=$((${STATE_COUNT[$STATE]:-0} + 1))
  done

  # The table is ASCII-only inside <pre>: printf pads by bytes, so it lines up only without emoji.
  local TABLE ROW MARK TOTAL_RUNS=0 TOTAL_FAILED=0 TOTAL_OPENED=0 UNREAD_TOTAL=0
  local -a TOTAL_COSTS=() LIST_FAILED=()
  TABLE="$(printf '%-8s %5s %5s %9s %4s' "" "runs" "fail" "cost" "PRs")\n"
  for PIPE in "${PIPELINES[@]}"; do
    if [[ "${RUNS[$PIPE]:-?}" == "?" ]]; then
      LIST_FAILED+=("$PIPE")
      ROW="$(printf '%-8s %5s %5s %9s %4s' "$PIPE" "?" "?" "?" "?")"
    else
      MARK=""; (( ${UNREAD[$PIPE]:-0} > 0 )) && MARK="*"
      ROW="$(printf '%-8s %5s %5s %9s %4s' "$PIPE" "${RUNS[$PIPE]}" "${FAILED[$PIPE]:-0}" \
        "\$$(printf '%.2f' "${COST[$PIPE]:-0}")$MARK" "${OPENED[$PIPE]:-0}")"
      TOTAL_RUNS=$((TOTAL_RUNS + ${RUNS[$PIPE]})); TOTAL_FAILED=$((TOTAL_FAILED + ${FAILED[$PIPE]:-0}))
      [[ "${OPENED[$PIPE]:-0}" =~ ^[0-9]+$ ]] && TOTAL_OPENED=$((TOTAL_OPENED + ${OPENED[$PIPE]}))
      UNREAD_TOTAL=$((UNREAD_TOTAL + ${UNREAD[$PIPE]:-0}))
      TOTAL_COSTS+=("${COST[$PIPE]:-0}")
    fi
    TABLE+="$ROW\n"
  done
  MARK=""; (( UNREAD_TOTAL > 0 || ${#LIST_FAILED[@]} > 0 )) && MARK="*"
  TABLE+="$(printf '%-8s %5s %5s %9s %4s' "Total" "$TOTAL_RUNS" "$TOTAL_FAILED" \
    "\$$(printf '%.2f' "$(sum_amounts "${TOTAL_COSTS[@]}")")$MARK" "$TOTAL_OPENED")\n"

  local NOTES=""
  (( UNREAD_TOTAL > 0 )) && NOTES+="\n* ${UNREAD_TOTAL} run log(s) unreadable, cost is a lower bound"
  (( ${#LIST_FAILED[@]} > 0 )) && NOTES+="\n? run list unreadable: ${LIST_FAILED[*]}"
  if (( ${#PR_REFS[@]} > 0 )); then
    NOTES+="\nPRs now: ${STATE_COUNT[open]:-0} open · ${STATE_COUNT[merged]:-0} merged · ${STATE_COUNT[closed]:-0} closed"
    (( ${STATE_COUNT[unknown]:-0} > 0 )) && NOTES+=" · ${STATE_COUNT[unknown]} unknown"
  fi

  local BLOCK="<pre>AI pipelines · ${CLAUDE_REVIEW_PERIOD:-week}\n\n${TABLE}${NOTES}</pre>"

  # Opened pull requests as a collapsible list; entries that do not fit the message are cut off.
  if (( ${#PR_REFS[@]} > 0 )); then
    BLOCK+="\n<blockquote expandable>\n<i>opened PRs · 🟢 open · 🟣 merged · ⚪️ closed</i>\n\n"
    local SHOWN=0 ICON PR_ORG PR_REPO PR_NUMBER PR_ENTRY
    for i in "${!PR_REFS[@]}"; do
      IFS=/ read -r PR_ORG PR_REPO _ PR_NUMBER <<< "${PR_REFS[$i]}"
      case "${PR_STATES[$i]}" in
        open)   ICON="🟢" ;;
        merged) ICON="🟣" ;;
        closed) ICON="⚪️" ;;
        *)      ICON="❔" ;;
      esac
      PR_ENTRY="$ICON <a href=\"https://${GITEA_HOST}/${PR_ORG}/${PR_REPO}/pulls/${PR_NUMBER}\">$(html_escape "$PR_REPO")#${PR_NUMBER}</a> · ${PR_PIPES[$i]}\n"
      (( $(telegram_text_length "${BLOCK}${PR_ENTRY}") > MAX_LENGTH )) && break
      BLOCK+="$PR_ENTRY"
      SHOWN=$((SHOWN + 1))
    done
    (( SHOWN < ${#PR_REFS[@]} )) && BLOCK+="<i>… +$((${#PR_REFS[@]} - SHOWN)) more</i>\n"
    BLOCK+="</blockquote>"
  fi

  _AI_MESSAGES+=("$(printf '%b' "$BLOCK")")
}
