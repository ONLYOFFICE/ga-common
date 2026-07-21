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
  body="**Claude Code Review** • [View run →]($(_run_url))

<img src=\"https://raw.githubusercontent.com/markwylde/claude-code-gitea-action/refs/heads/gitea/assets/spinner.gif\" width=\"20\" align=\"absmiddle\" /> Analyzing Pull Request..."
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
  local payload; payload=$(printf '%s\n\n<!-- Claude-Review: -->' "$body" | jq -Rs .)
  if [ -n "$comment_id" ]; then
    gitea_api_json "$repo/issues/comments/$comment_id" -X PATCH -d "{\"body\": $payload}" > /dev/null
    echo "$comment_id"
  else
    gitea_api_json "$repo/issues/$pr/comments" -X POST -d "{\"body\": $payload}" | jq -r '.id'
  fi
}

upsert_review_comment() {
  local repo="$1" pr="$2" file="$3" comment_id="${4:-}" sha="${5:-}" marker="${6:-}"
  local end_marker="${marker:-<!-- Claude-Review:${sha} -->}"
  local body; body="$(printf '%s\n\n%s' "$(cat "$file")" "$end_marker")"
  local payload; payload="{\"body\": $(echo "$body" | jq -Rs .)}"
  if [ -n "$comment_id" ]; then
    # Fall back to POST when the tracked comment was deleted mid-run (stale id)
    # so the finished review is never silently dropped.
    gitea_api_json "$repo/issues/comments/$comment_id" -X PATCH -d "$payload" > /dev/null \
      || { echo "PATCH of comment #$comment_id failed — posting a new comment" >&2
           gitea_api_json "$repo/issues/$pr/comments" -X POST -d "$payload" > /dev/null; }
  else
    gitea_api_json "$repo/issues/$pr/comments" -X POST -d "$payload" > /dev/null
  fi
}

set_commit_status() {
  local repo="$1" sha="$2" state="$3" context="${5:-Claude Code Review}"
  local desc="/ $4"; desc="${desc:0:140}"
  gitea_api_json "$repo/statuses/$sha" -X POST \
    -d "$(jq -n --arg state "$state" --arg desc "$desc" --arg url "$(_run_url)" --arg ctx "$context" \
           '{state:$state,context:$ctx,description:$desc,target_url:$url}')" > /dev/null || true
}

# Open a PR for $head into $base, or refresh the one already open from $head.
# Body is read from $body_file (markdown). On success prints "<created|updated> <html_url>";
# returns non-zero (and prints nothing) on failure.
# Usage: open_pull_request <owner/repo> <head> <base> <title> <body_file>
open_pull_request() {
  local repo="$1" head="$2" base="$3" title="$4" body_file="$5"
  local number out url
  number=$(gitea_api "$repo/pulls?state=open&limit=50" 2>/dev/null \
    | jq -r --arg h "$head" 'map(select(.head.ref == $h)) | first | .number // empty' 2>/dev/null || true)
  if [ -n "$number" ]; then
    # Branch was force-pushed with new fixes — refresh the open PR's title/body.
    out=$(gitea_api_json "$repo/pulls/$number" -X PATCH \
      -d "$(jq -n --arg title "$title" --rawfile body "$body_file" '{title:$title, body:$body}')") || return 1
    url=$(printf '%s' "$out" | jq -r '.html_url // empty')
    [ -n "$url" ] && { echo "updated $url"; return 0; }
    return 1
  fi
  out=$(gitea_api_json "$repo/pulls" -X POST \
    -d "$(jq -n --arg head "$head" --arg base "$base" --arg title "$title" --rawfile body "$body_file" \
          '{head:$head, base:$base, title:$title, body:$body}')") || return 1
  url=$(printf '%s' "$out" | jq -r '.html_url // empty')
  [ -n "$url" ] && { echo "created $url"; return 0; }
  return 1
}
