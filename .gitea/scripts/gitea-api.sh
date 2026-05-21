#!/usr/bin/env bash
# Helper for Gitea API calls. Requires $GITEA_TOKEN and $GITEA_HOST to be set.

_gitea_raw() {
  local retry="$1" endpoint="$2"; shift 2
  local body http_code
  body=$(curl -s --retry "$retry" -w "\n%{http_code}" \
    -H "Authorization: token $GITEA_TOKEN" \
    "https://$GITEA_HOST/api/v1/repos/$endpoint" \
    "$@")
  http_code=$(printf '%s' "$body" | tail -1)
  body=$(printf '%s' "$body" | head -n -1)
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "Gitea API error $http_code for $endpoint: $(echo "$body" | jq -r '.message // empty' 2>/dev/null || echo "$body")" >&2; return 1
  fi
  printf '%s' "$body"
}

gitea_api()      { _gitea_raw 3 "$@"; }
gitea_api_json() { _gitea_raw 0 "$1" -H "Content-Type: application/json" "${@:2}"; }

_run_url() { echo "https://$GITEA_HOST/${WORKFLOW_REPO:-$ORG_NAME/ga-common}/actions/runs/$GITHUB_RUN_ID"; }

fetch_all_comments() {
  local endpoint="$1" all="[]" page=1
  while true; do
    local batch; batch=$(gitea_api "$endpoint?limit=50&page=$page") || { echo "Error fetching page $page of $endpoint" >&2; return 1; }
    local count; count=$(echo "$batch" | jq 'length') || return 1
    [ "$count" -eq 0 ] && break
    all=$(jq -n --argjson a "$all" --argjson b "$batch" '$a + $b') || return 1
    [ "$count" -lt 50 ] && break
    (( page++ ))
  done
  echo "$all"
}

post_working_comment() {
  local repo="$1" pr="$2" comment_id="${3:-}" previous_review_file="${4:-}"
  local body
  body="**Claude Code Review** • [View run →]($(_run_url))"
  if [ -n "$previous_review_file" ] && [ -f "$previous_review_file" ]; then
    local prev_verdict=""
    grep -q "✅ APPROVE" "$previous_review_file" && prev_verdict=" - ✅ APPROVE"
    grep -q "❌ BLOCKED" "$previous_review_file" && prev_verdict=" - ❌ BLOCKED"
    body="$body

---

<details><summary>💬 Previous review$prev_verdict</summary>

$(cat "$previous_review_file")

</details>"
  fi
  local payload; payload=$(printf '%s\n\n<!-- Claude-Review -->' "$body" | jq -Rs .)
  if [ -n "$comment_id" ]; then
    gitea_api_json "$repo/issues/comments/$comment_id" -X PATCH -d "{\"body\": $payload}" > /dev/null
    echo "$comment_id"
  else
    gitea_api_json "$repo/issues/$pr/comments" -X POST -d "{\"body\": $payload}" | jq -r '.id'
  fi
}

upsert_review_comment() {
  local repo="$1" pr="$2" file="$3" comment_id="${4:-}" marker="${5:-<!-- Claude-Review -->}" sha="${6:-}"
  local sha_tag=""; [ -n "$sha" ] && sha_tag="<!-- review-sha:$sha -->\n"
  local body; body="$(printf '%s%s\n\n%s' "$sha_tag" "$(cat "$file")" "$marker")"
  if [ -n "$comment_id" ]; then
    gitea_api_json "$repo/issues/comments/$comment_id" -X PATCH -d "{\"body\": $(echo "$body" | jq -Rs .)}" > /dev/null
  else
    gitea_api_json "$repo/issues/$pr/comments" -X POST -d "{\"body\": $(echo "$body" | jq -Rs .)}" > /dev/null
  fi
}

set_commit_status() {
  local repo="$1" sha="$2" state="$3" context="${5:-Claude Code Review}"
  local desc="/ $4"; desc="${desc:0:140}"
  gitea_api_json "$repo/statuses/$sha" -X POST \
    -d "$(jq -n --arg state "$state" --arg desc "$desc" --arg url "$(_run_url)" --arg ctx "$context" \
           '{state:$state,context:$ctx,description:$desc,target_url:$url}')" > /dev/null || true
}
