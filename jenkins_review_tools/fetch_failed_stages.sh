#!/usr/bin/env bash
# Download the decoded log of every FAILED stage of a Jenkins pipeline build.
#
# For each failed stage it writes:  stage_<id>_<slug>.log   (plain text, no ANSI)
# and prints "<stage_id> <slug> <name>" per stage to stdout for a caller loop.
# Progress goes to stderr so stdout stays machine-readable.
#
# Usage:
#   JENKINS_AUTH="user:token" ./fetch_failed_stages.sh \
#       "https://example.jenkins.url/job/oo/job/release%252Fv10.0.0/123"
#
# Tunables (env): OUT_DIR, CURL_MAX_TIME (s), MAX_PAGES, MAX_NODE_BYTES, QUIET=1
# Requires: bash, curl, jq.

set -euo pipefail

BASE="${1:?usage: fetch_failed_stages.sh <build-base-url>}"
: "${JENKINS_AUTH:?export JENKINS_AUTH=user:token}"
OUT_DIR="${OUT_DIR:-.}"
CURL_MAX_TIME="${CURL_MAX_TIME:-120}"          # hard cap per HTTP request
MAX_PAGES="${MAX_PAGES:-3000}"                 # per-node pagination safety cap
MAX_NODE_BYTES="${MAX_NODE_BYTES:-20000000}"   # stop a node's log at ~20 MB

log() { [ "${QUIET:-0}" = "1" ] || printf '%s\n' "$*" >&2; }

jc() { curl -sSf --connect-timeout 15 --max-time "$CURL_MAX_TIME" -u "$JENKINS_AUTH" "$@"; }

# wfapi/log returns HTML-annotated console: strip ANSI, then HTML tags, then decode entities.
clean_log() {
  sed -E 's/\x1b\[[0-9;?]*[ -/]*[@-~]//g' \
  | sed -E 's/<[^>]*>//g' \
  | sed -E 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#0?39;/'\''/g; s/&#0?34;/"/g; s/&amp;/\&/g'
}

slug() { echo "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_'; }

# Full text of one flow node. `length` in the response is the ABSOLUTE next
# offset (total bytes so far), not the chunk size - so the next request uses
# start=<length>. Guard: if the offset does not grow, the server ignored ?start=
# (would otherwise re-append the same chunk forever) - stop.
fetch_node_log() {
  local node="$1" start=0 page=0 resp more new
  while :; do
    page=$((page + 1))
    if ! resp="$(jc "$BASE/execution/node/$node/wfapi/log?start=$start")"; then
      log "      ! node $node page $page: curl failed (timeout/HTTP) - stopping this node"
      break
    fi
    new="$(printf '%s' "$resp" | jq -r '.length // 0')"
    more="$(printf '%s' "$resp" | jq -r '.hasMore // false')"

    # offset did not advance since last page -> server ignored ?start= -> stop before re-appending
    if [ "$page" -gt 1 ] && [ "$new" -le "$start" ]; then
      log "      ! node $node: offset did not advance ($start -> $new) - stopping (server may ignore ?start=)"
      break
    fi

    printf '%s' "$resp" | jq -r '.text // ""'
    log "      node $node page $page: offset $start -> $new, hasMore=$more"

    [ "$more" = "true" ] || break
    [ "$new" -le "$start" ] && break
    start="$new"
    if [ "$page" -ge "$MAX_PAGES" ]; then
      log "      ! node $node: hit MAX_PAGES=$MAX_PAGES - stopping"; break
    fi
    if [ "$start" -ge "$MAX_NODE_BYTES" ]; then
      log "      ! node $node: hit MAX_NODE_BYTES=$MAX_NODE_BYTES - stopping"; break
    fi
  done
}

log "==> querying failed stages: $BASE/wfapi/describe"
mapfile -t FAILED < <(jc "$BASE/wfapi/describe" \
  | jq -r '.stages[] | select(.status=="FAILED") | "\(.id)\t\(.name)"')

log "==> failed stages: ${#FAILED[@]}"
if [ "${#FAILED[@]}" -eq 0 ]; then
  log "No FAILED stages found."
  exit 0
fi

for row in "${FAILED[@]}"; do
  stage_id="${row%%$'\t'*}"
  stage_name="${row#*$'\t'}"
  s="$(slug "$stage_name")"
  out="$OUT_DIR/stage_${stage_id}_${s}.log"

  log "--> stage $stage_id ($stage_name): listing failed steps"
  mapfile -t NODES < <(jc "$BASE/execution/node/$stage_id/wfapi/describe" \
    | jq -r '.stageFlowNodes[] | select(.status=="FAILED") | .id')

  if [ "${#NODES[@]}" -eq 0 ]; then
    log "    no FAILED child node; falling back to stage node $stage_id"
    NODES=("$stage_id")
  else
    log "    failed step node(s): ${NODES[*]}"
  fi

  {
    echo "# stage $stage_id: $stage_name"
    for n in "${NODES[@]}"; do
      echo "# --- flow node $n ---"
      fetch_node_log "$n" | clean_log
    done
  } > "$out"

  log "    wrote $out ($(wc -l < "$out") lines)"
  echo "$stage_id $s $stage_name"      # machine-readable index line (stdout)
done

log "==> done"
