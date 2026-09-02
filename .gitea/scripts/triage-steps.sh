#!/usr/bin/env bash
# Sourced helper library for bugzilla-triage.yml. Two entry points:
#   prepare_triage_context  - fetch the bug, run the guards, pick and clone repositories, render the prompt
#   report_triage_result    - render the result into the job log and step summary
#
# Expects from the job env: BUG_ID, BUGZILLA_HOST, BUGZILLA_API_KEY, GITEA_HOST, GITEA_TOKEN,
# ANTHROPIC_API_KEY (for the repository-selection call). Optional: TRIAGE_ORG (default ONLYOFFICE),
# TRIAGE_ALLOWED_PRODUCTS (default DocSpace), SELECT_MAX_REPOS (see select-repos.py).

set -euo pipefail

TRIAGE_ORG="${TRIAGE_ORG:-ONLYOFFICE}"
# Empty by default: triage/product-repos.json is what admits a product. This is only for products
# routed by the model rather than by a list entry - comma-separated, or "*" for any product.
TRIAGE_ALLOWED_PRODUCTS="${TRIAGE_ALLOWED_PRODUCTS:-}"

# Caps by characters, not bytes: bash's own ${var:0:n} slices bytes under a non-UTF-8 locale, which
# both halves the cap and can sever a codepoint mid-sequence on this org's routinely-Cyrillic bug
# text. Kept identical to review-steps.sh's helper of the same name.
_trim_chars() {
  python3 -c 'import sys
limit = int(sys.argv[1])
text = sys.stdin.buffer.read().decode("utf-8", "replace")[:limit]
sys.stdout.buffer.write(text.encode("utf-8"))' "$1"
}

# Bugzilla-supplied text reaching an LLM prompt or a shell variable.
_sanitize() {
  # Same pipeline the review side uses on PR text, and for the same reasons: drop newlines,
  # backticks and dollars so the value cannot steer envsubst or the shell, cap by characters, and
  # escape & < > last so a cap can never leave a dangling entity. Escaping & first is required -
  # doing it after < > would double-escape the entities this very step introduces.
  printf '%s' "$1" | tr '\n\r\t`$' '     ' | tr -s ' ' | _trim_chars "${2:-200}" \
    | sed 's/^ *//; s/ *$//; s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

_bugzilla_get() {
  # The API key goes in the query string: per the Bugzilla REST docs there is no header auth.
  curl -sf --get "https://$BUGZILLA_HOST/rest/$1" --data-urlencode "api_key=$BUGZILLA_API_KEY"
}

# Fetches the bug, enforces the guards a manual workflow_dispatch would otherwise skip (the Lambda
# applies its own, but a human can dispatch any id), and exports the fields the prompt needs.
_fetch_bug_metadata() {
  local BUG_JSON
  BUG_JSON=$(_bugzilla_get "bug/$BUG_ID") || {
    echo "::error::Could not fetch bug $BUG_ID from Bugzilla - check the id and BUGZILLA_API_KEY"
    return 1
  }
  if [ "$(jq -r '.bugs | length' <<< "$BUG_JSON")" != "1" ]; then
    echo "::error::Bugzilla returned no bug for id $BUG_ID"
    return 1
  fi

  # Confidential bugs never reach the model: their content would leave Bugzilla's access control
  # behind. The Lambda checks this too, but it is not in the path on a manual dispatch, so this is
  # the guard that actually holds - keep the two in sync (lambda_function.py:is_confidential).
  local RESTRICTION
  RESTRICTION=$(jq -r '
    .bugs[0] as $bug
    | [ (($bug.groups // []) | if length > 0 then "groups=" + join(",") else empty end),
        (if ($bug.is_private // false) or ($bug.is_confidential // false) then "private flag" else empty end),
        # This instance carries the security flag as the custom field cf_security ("---" when
        # unset). Both spellings are checked separately, never joined with //: the jq alternative
        # operator only falls through on null/false, so a present-but-unset cf_security ("---")
        # would mask a set "security" field and let a restricted bug through. The Lambda checks
        # both fields too, and these two guards are required to agree.
        ((($bug.cf_security // "") | tostring | ascii_downcase)
          | if . != "" and . != "---" then "cf_security=" + . else empty end),
        ((($bug.security // "") | tostring | ascii_downcase)
          | if . != "" and . != "---" then "security=" + . else empty end) ]
    | join("; ")' <<< "$BUG_JSON" | tr -d '\r')
  if [ -n "$RESTRICTION" ]; then
    echo "::error::Bug $BUG_ID is access-restricted ($RESTRICTION) - refusing to send it to the model"
    return 1
  fi

  PRODUCT=$(_sanitize "$(jq -r '.bugs[0].product // ""' <<< "$BUG_JSON")" 80)
  COMPONENT=$(_sanitize "$(jq -r '.bugs[0].component // ""' <<< "$BUG_JSON")" 80)
  BUG_VERSION=$(_sanitize "$(jq -r '.bugs[0].version // ""' <<< "$BUG_JSON")" 40)
  BUG_STATUS=$(_sanitize "$(jq -r '[.bugs[0].status, .bugs[0].resolution] | map(select(. != null and . != "")) | join("/")' <<< "$BUG_JSON")" 40)
  BUG_SUMMARY=$(_sanitize "$(jq -r '.bugs[0].summary // ""' <<< "$BUG_JSON")" 300)
  BUG_URL="https://$BUGZILLA_HOST/show_bug.cgi?id=$BUG_ID"

  # Product gate. A product listed in product-repos.json is allowed by that fact alone - the entry
  # is what makes the bug routable - so adding a product is one edit in one place. TRIAGE_ALLOWED_
  # PRODUCTS is for products deliberately routed by the model instead of by a list entry (the
  # connectors are the real case: the product name alone cannot say whether "Zoom" means
  # onlyoffice-zoom or onlyoffice-docspace-zoom, while the bug text usually can). It is
  # comma-separated, not space-separated: product names here include "Docs Cloud" and "API Website".
  local ALLOWED=false PRODUCT_ITEM
  if jq -e --arg product "$PRODUCT" 'any(.[]; .products | map(ascii_downcase) | index($product | ascii_downcase))' \
       triage/product-repos.json > /dev/null 2>&1; then
    ALLOWED=true
  else
    local IFS=,
    # set -f while splitting: the documented "*" (any product) is a literal, and an unquoted
    # expansion would otherwise let pathname expansion turn it into whatever files sit in $PWD,
    # so the wildcard silently never matched.
    set -f
    for PRODUCT_ITEM in ${TRIAGE_ALLOWED_PRODUCTS:-}; do
      PRODUCT_ITEM=$(printf '%s' "$PRODUCT_ITEM" | sed 's/^ *//; s/ *$//')
      if [ "$PRODUCT_ITEM" = "*" ] || [ "${PRODUCT_ITEM,,}" = "${PRODUCT,,}" ]; then
        ALLOWED=true
        break
      fi
    done
    set +f
  fi
  if [ "$ALLOWED" != "true" ]; then
    echo "::error::Product '$PRODUCT' has no entry in triage/product-repos.json and is not in TRIAGE_ALLOWED_PRODUCTS (${TRIAGE_ALLOWED_PRODUCTS:-unset}) - skipping bug $BUG_ID"
    return 1
  fi

  echo "Bug $BUG_ID: $PRODUCT / $COMPONENT / $BUG_VERSION [$BUG_STATUS]"
  echo "  $BUG_SUMMARY"
}

# Renders the <bug> data block (bugzilla-api.py does its own sanitizing and mojibake repair).
_render_bug_context() {
  python3 .gitea/scripts/bugzilla-api.py "$BUG_ID" > bug-context.txt || true
  # bugzilla-api.py never exits non-zero: a failed fetch still prints a "data not retrieved" stub
  # and returns 0, and that stub is non-empty, so testing the exit status (or just -s) would feed
  # an empty bug report into a full-budget analysis. The rendered Summary line is the real signal.
  if ! grep -q '^- Summary: .' bug-context.txt; then
    echo "::warning::bugzilla-api.py returned no usable bug data - falling back to the metadata already fetched"
    printf '<bug id="%s">\n- URL: %s\n- Summary: %s\n- Product / Component / Version: %s / %s / %s\n</bug>\n' \
      "$BUG_ID" "$BUG_URL" "$BUG_SUMMARY" "$PRODUCT" "$COMPONENT" "$BUG_VERSION" > bug-context.txt
  fi
  if ! grep -q '^- Summary: .' bug-context.txt; then
    echo "::error::No bug context could be rendered for bug $BUG_ID"
    return 1
  fi
}

# Lists the org's non-archived repositories as selection candidates.
#
# Pages until a page comes back empty, and deliberately does NOT stop early on a short page: this
# Gitea ignores `limit` (asking for 50 or 100 both yield 30, asking for 30 yields 20) and its page
# sizes vary a lot because permission filtering is applied per page - measured live as 30, 18, 23,
# 38, 15, 35, 36, 6 across 8 pages for 201 repos. A "short page means last page" shortcut therefore
# stopped after page 1 and offered 30 of 201 repos, with docspace-ui-kit-react (page 7) unreachable -
# exactly the repository the pilot showed matters most for frontend bugs filed against Server.
_list_candidate_repos() {
  local PAGE=1 COUNT
  : > repos-available.txt
  while :; do
    local BATCH
    # A failed request is fatal, never a quiet "assume that was the last page": past the last page
    # Gitea answers 200 with [], so -f failing means a real error, and silently truncating the list
    # makes a listed product abort later with a confusing "not in the ONLYOFFICE listing" instead.
    # One retry first, since a single transient 5xx should not sink the run.
    BATCH=$(curl -sf -H "Authorization: token $GITEA_TOKEN" \
      "https://$GITEA_HOST/api/v1/orgs/$TRIAGE_ORG/repos?limit=50&page=$PAGE") \
      || BATCH=$(curl -sf --retry 2 --retry-delay 2 -H "Authorization: token $GITEA_TOKEN" \
      "https://$GITEA_HOST/api/v1/orgs/$TRIAGE_ORG/repos?limit=50&page=$PAGE") \
      || { echo "::error::Gitea repository listing failed on page $PAGE - refusing to work from a partial list"; return 1; }
    COUNT=$(jq -r 'length' <<< "$BATCH")
    [ "$COUNT" = "0" ] && break
    # "name<TAB>language": this Gitea has descriptions on 2 of ~200 repositories, so the primary
    # language is the only extra signal available to the selection call. Only the name is ever
    # used as a clone target (select-repos.py takes field one).
    jq -r '.[] | select(.archived == false) | [.name, (.language // "")] | @tsv' <<< "$BATCH" | tr -d '\r' >> repos-available.txt
    PAGE=$((PAGE + 1))
    [ "$PAGE" -gt 30 ] && break
  done
  sort -u -o repos-available.txt repos-available.txt
  local TOTAL
  TOTAL=$(wc -l < repos-available.txt | tr -d ' ')
  if [ "$TOTAL" = "0" ]; then
    echo "::error::Could not list repositories of org $TRIAGE_ORG from the Gitea API"
    return 1
  fi
  echo "Selection candidates: $TOTAL repositories in $TRIAGE_ORG"
}

# Clones one repository shallow, preferring the bug's own release branch when it exists.
# .git is dropped afterwards: the model is told it has no history, and this makes that literally
# true while roughly halving what gets copied into the sandbox.
_clone_repo() {
  local REPO="$1" BRANCH=""
  if [ -n "$BUG_VERSION" ] && [[ "$BUG_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    local CANDIDATE="release/v$BUG_VERSION"
    if git ls-remote --heads "https://$GITEA_HOST/$TRIAGE_ORG/$REPO" "$CANDIDATE" 2>/dev/null | grep -q .; then
      BRANCH="$CANDIDATE"
    fi
  fi
  local CLONE_ARGS=(--depth=1 --quiet)
  [ -n "$BRANCH" ] && CLONE_ARGS+=(--branch "$BRANCH")
  if ! git clone "${CLONE_ARGS[@]}" "https://$GITEA_HOST/$TRIAGE_ORG/$REPO" "repos/$REPO" 2>/dev/null; then
    echo "::warning::Could not clone $REPO${BRANCH:+ ($BRANCH)} - continuing without it"
    rm -rf "repos/$REPO"
    return 1
  fi
  local ACTUAL_BRANCH
  ACTUAL_BRANCH=$(git -C "repos/$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  rm -rf "repos/$REPO/.git"
  echo "$REPO@$ACTUAL_BRANCH" >> repos-cloned.txt
  echo "  cloned $REPO ($ACTUAL_BRANCH)"
}

# Model-driven selection (see select-repos.py) followed by the clones; at least one repo must land.
# TRIAGE_REPOS overrides the model entirely - the escape hatch for a manual dispatch when selection
# picked wrong, still validated against the Gitea listing so a typo fails instead of silently skipping.
_select_and_clone_repos() {
  mkdir -p repos
  : > repos-cloned.txt
  local SELECTED
  if [ -z "${TRIAGE_REPOS:-}" ]; then
    # A product listed in product-repos.json skips the model call entirely. Measured on 50 labeled
    # bugs: for DocSpace the selection call returned the same family every time (DocSpace-client and
    # DocSpace-server in 50 of 50 answers), so for a listed product the list is the same answer for
    # free and without run-to-run variance. Unlisted products still go through the model, which is
    # what keeps Docs and Workspace working without anyone maintaining an entry for them first.
    local LISTED
    LISTED=$(jq -r --arg product "$PRODUCT" '
      [.[] | select(.products | map(ascii_downcase) | index($product | ascii_downcase))]
      | (.[0].repos // []) | .[]' triage/product-repos.json 2>/dev/null | tr -d '\r' || true)
    if [ -n "$LISTED" ]; then
      TRIAGE_REPOS=$(paste -sd, - <<< "$LISTED")
      echo "Product '$PRODUCT' is listed in product-repos.json: $TRIAGE_REPOS"
    fi
  fi
  if [ -n "${TRIAGE_REPOS:-}" ]; then
    SELECTED=""
    local WANTED
    for WANTED in ${TRIAGE_REPOS//,/ }; do
      local MATCH
      MATCH=$(cut -f1 repos-available.txt | grep -ix -- "$WANTED" || true)
      if [ -z "$MATCH" ]; then
        echo "::error::Requested repository '$WANTED' is not in the $TRIAGE_ORG listing"
        return 1
      fi
      SELECTED+="$MATCH"$'\n'
    done
    echo "Repositories taken from the TRIAGE_REPOS override"
  else
    SELECTED=$(python3 .gitea/scripts/select-repos.py \
      --repos-file repos-available.txt --bug-file bug-context.txt --product "$PRODUCT") || {
      echo "::error::Repository selection failed for bug $BUG_ID"
      return 1
    }
  fi
  echo "Selected repositories:"
  printf '%s\n' "$SELECTED" | sed '/^$/d; s/^/  - /'

  local REPO
  while read -r REPO; do
    [ -n "$REPO" ] || continue
    _clone_repo "$REPO" || true
  done <<< "$SELECTED"

  if [ ! -s repos-cloned.txt ]; then
    echo "::error::None of the selected repositories could be cloned - nothing to analyse"
    return 1
  fi
}

# Clones the repositories the already-cloned code declares (vendored tarballs, submodule targets).
# This is the deterministic half of repository discovery: the selection call reliably finds the
# product's own repositories but not the libraries it pulls in, and those are named outright in
# package.json / .gitmodules - see expand-repos.py for the measured case (Bug 83616).
_expand_and_clone_declared_repos() {
  local EXTRA
  sed 's/@[^@]*$//' repos-cloned.txt > repos-cloned-names.txt
  EXTRA=$(python3 .gitea/scripts/expand-repos.py \
    --repos-dir repos --repos-file repos-available.txt \
    --exclude-file repos-cloned-names.txt --max "${TRIAGE_MAX_EXTRA_REPOS:-3}") || {
    echo "::warning::Dependency expansion failed - continuing with the selected repositories only"
    return 0
  }
  [ -n "$EXTRA" ] || return 0
  local REPO
  while read -r REPO; do
    [ -n "$REPO" ] || continue
    _clone_repo "$REPO" || true
  done <<< "$EXTRA"
}

# Builds the <repositories> block: one line per cloned repo, with the path the sandbox will see.
_render_repositories_block() {
  REPOSITORIES=$(while read -r ENTRY; do
    [ -n "$ENTRY" ] || continue
    printf -- '- %s (branch %s) at /workspace/%s\n' "${ENTRY%@*}" "${ENTRY##*@}" "${ENTRY%@*}"
  done < repos-cloned.txt)
}

# One product in two entries would silently resolve to whichever comes first, so a duplicate is
# treated as what it is - an editing mistake in the data - rather than quietly picking a family.
_validate_product_map() {
  # Named explicitly: the file is the product gate, so if the clone lacks it (added to the repo but
  # never committed, say) every bug is rejected as an unlisted product with nothing pointing here.
  if [ ! -f triage/product-repos.json ]; then
    echo "::error::triage/product-repos.json is missing from the checkout - no product can be routed"
    return 1
  fi
  if ! jq -e 'type == "array" and length > 0 and all(.[]; (.products | type == "array") and (.repos | type == "array"))' \
       triage/product-repos.json > /dev/null 2>&1; then
    echo "::error::triage/product-repos.json is not a non-empty array of {products, repos} entries"
    return 1
  fi
  local DUPES
  DUPES=$(jq -r '[.[].products[] | ascii_downcase] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' \
    triage/product-repos.json 2>/dev/null | tr -d '\r' || true)
  if [ -n "$DUPES" ]; then
    echo "::error::triage/product-repos.json lists the same product in more than one entry: $DUPES"
    return 1
  fi
}

prepare_triage_context() {
  _validate_product_map
  _fetch_bug_metadata
  _render_bug_context
  _list_candidate_repos
  _select_and_clone_repos
  _expand_and_clone_declared_repos
  _render_repositories_block

  BUGZILLA_CONTEXT=$(cat bug-context.txt)
  export BUG_ID BUG_URL PRODUCT COMPONENT BUGZILLA_CONTEXT REPOSITORIES
  # Explicit variable list, so a stray $-looking token in the template is left alone. The single
  # quotes are required: envsubst takes the variable *names*, so expanding them here would defeat it.
  envsubst '$BUG_ID $BUG_URL $PRODUCT $COMPONENT $BUGZILLA_CONTEXT $REPOSITORIES' \
    < triage/TRIAGE.md > claude-prompt.txt
  echo "Prompt rendered: $(wc -c < claude-prompt.txt | tr -d ' ') bytes"

  # Read back by report_triage_result, which runs in a later step with a fresh shell.
  { echo "PRODUCT=$PRODUCT"; echo "COMPONENT=$COMPONENT"; echo "BUG_URL=$BUG_URL"; } >> "$GITHUB_ENV"
}

# Maps the model's missing_repository value onto a real repository name, or prints nothing.
# The value is free text from the analysis, so it may name the package rather than the repository
# ("@onlyoffice/ai-chat" for onlyoffice-ai-chat); only an exact or single unambiguous match is
# accepted, since the point is to spend one more run on a near-certainty, not on a guess.
_resolve_missing_repo() {
  local WANTED="$1" NAMES MATCH TOKEN
  NAMES=$(cut -f1 repos-available.txt)
  MATCH=$(grep -ix -- "$WANTED" <<< "$NAMES" || true)
  if [ -z "$MATCH" ]; then
    # "@scope/name" -> "scope-name", the shape ONLYOFFICE's vendored packages use.
    TOKEN=$(printf '%s' "$WANTED" | tr -d '@' | tr '/' '-')
    MATCH=$(grep -ix -- "$TOKEN" <<< "$NAMES" || true)
  fi
  if [ -z "$MATCH" ] && [ -n "${TOKEN:-}" ]; then
    MATCH=$(grep -i -- "$TOKEN" <<< "$NAMES" || true)
    [ "$(wc -l <<< "$MATCH" | tr -d ' ')" = "1" ] || MATCH=""
  fi
  printf '%s' "$MATCH"
}

# Re-dispatches this workflow once with the repository the analysis says it was missing. Guarded by
# IS_RETRY so a second dead end ends the chain instead of looping.
maybe_retry_with_missing_repo() {
  [ -s claude-structured.json ] || return 0
  if [ "${IS_RETRY:-false}" = "true" ]; then
    echo "This run is already a retry - not re-dispatching again"
    return 0
  fi
  local WANTED
  WANTED=$(jq -r '.missing_repository // "" | tostring' claude-structured.json 2>/dev/null | tr -d '\r' | head -c 200)
  [ -n "$WANTED" ] && [ "$WANTED" != "null" ] || return 0

  local MATCH
  MATCH=$(_resolve_missing_repo "$WANTED")
  if [ -z "$MATCH" ]; then
    echo "::warning::Analysis asked for '$WANTED', which matches no repository in $TRIAGE_ORG - not re-dispatching"
    return 0
  fi
  if cut -f1 -d@ repos-cloned.txt | grep -qix -- "$MATCH"; then
    echo "::warning::Analysis asked for '$MATCH', which was already analysed - not re-dispatching"
    return 0
  fi

  local REPO_LIST
  REPO_LIST=$(sed 's/@[^@]*$//' repos-cloned.txt | paste -sd, -)
  REPO_LIST="$REPO_LIST,$MATCH"
  echo "Re-dispatching triage for bug $BUG_ID with $MATCH added ($REPO_LIST)"
  local PAYLOAD
  PAYLOAD=$(jq -n --arg ref "${GITHUB_REF_NAME:-master}" --arg bug "$BUG_ID" --arg repos "$REPO_LIST" \
    --arg model "${CLAUDE_MODEL:-}" --arg effort "${CLAUDE_EFFORT:-}" \
    --arg version "${CLAUDE_CODE_VERSION:-}" --arg budget "${CLAUDE_MAX_BUDGET_USD:-}" \
    '{ref: $ref, inputs: ({bug_id: $bug, repos: $repos, is_retry: "true"}
        + (if $model   != "" then {model: $model} else {} end)
        + (if $effort  != "" then {effort: $effort} else {} end)
        + (if $version != "" then {claude_code_version: $version} else {} end)
        + (if $budget  != "" then {max_budget_usd: $budget} else {} end))}')
  local CODE
  CODE=$(curl -s -o /tmp/retry-dispatch.out -w '%{http_code}' -X POST \
    -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
    "https://$GITEA_HOST/api/v1/repos/$TRIAGE_ORG/ga-common/actions/workflows/bugzilla-triage.yml/dispatches" \
    -d "$PAYLOAD")
  if [ "$CODE" = "204" ] || [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then
    echo "Retry dispatched (HTTP $CODE)"
  else
    echo "::warning::Retry dispatch failed (HTTP $CODE): $(head -c 200 /tmp/retry-dispatch.out)"
  fi
}

# Renders the analysis (or a fallback) into the job log and the step summary. This message body is
# what will later be posted as the Bugzilla comment, so it is plain text, not markdown.
report_triage_result() {
  local ARGS=(--bug-id "$BUG_ID" --bug-url "${BUG_URL:-}" --product "${PRODUCT:-}" --component "${COMPONENT:-}")
  if [ -s claude-structured.json ]; then
    ARGS+=(--structured claude-structured.json)
  else
    ARGS+=(--fallback "the triage run produced no valid structured output (job status: ${JOB_STATUS:-unknown})")
  fi

  python3 .gitea/scripts/render-triage.py "${ARGS[@]}" --output triage-message.txt > /dev/null

  echo "--- triage message ---"
  cat triage-message.txt
  echo "--- end ---"

  # Fenced in the summary so the plain-text body is shown verbatim, exactly as Bugzilla would get it.
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "## Claude triage: Bug $BUG_ID"; echo; echo '```text'; cat triage-message.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
  fi
}
