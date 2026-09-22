#!/usr/bin/env bash
# Sourced helper library for bugzilla-triage.yml. Two entry points:
#   prepare_triage_context  - fetch the bug, run the guards, pick and clone repositories, render the prompt
#   report_triage_result    - render the result into the job log and step summary
#
# Expects from the job env: BUG_ID, BUGZILLA_HOST, BUGZILLA_API_KEY, GITEA_HOST, GITEA_TOKEN,
# ANTHROPIC_API_KEY (for the repository-selection call). Optional: TRIAGE_ORG (default ONLYOFFICE),
# TRIAGE_ALLOWED_PRODUCTS (default empty - product-repos.json is what admits a product),
# SELECT_MAX_REPOS (see select-repos.py).

set -euo pipefail

TRIAGE_ORG="${TRIAGE_ORG:-ONLYOFFICE}"
# Empty by default: product-repos.json is what admits a product. This is only for products
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
  # Retried and time-boxed: this is the first call of the run, and a single flaky response used to
  # abort the whole triage (seen live - the same request answered 200 in 1.8s moments later).
  # Extra --data-urlencode arguments are forwarded, so a caller can add query parameters without
  # encoding product and component names that contain spaces by hand.
  local ENDPOINT="$1"
  shift
  curl -sf --max-time 45 --retry 2 --retry-delay 3 --retry-all-errors \
    --get "https://$BUGZILLA_HOST/rest/$ENDPOINT" --data-urlencode "api_key=$BUGZILLA_API_KEY" "$@"
}

# A deliberate skip is not a failure. Marking one red trains everybody to ignore red, and the
# unroutable products are a steady trickle (UI.iOS alone files about two bugs a day), so the run
# ends green with the reason stated instead. Mirrors claude-review.yml's steps.prepare.outputs.skip.
_skip_run() {
  local REASON="$1"
  echo "::notice::Skipping bug $BUG_ID: $REASON"
  echo "$REASON" > triage-skip-reason.txt
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "skip=true" >> "$GITHUB_OUTPUT"
  return 0
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
    _skip_run "access-restricted ($RESTRICTION) - its contents are not sent to the model"
    return 78
  fi

  PRODUCT=$(_sanitize "$(jq -r '.bugs[0].product // ""' <<< "$BUG_JSON")" 80)
  COMPONENT=$(_sanitize "$(jq -r '.bugs[0].component // ""' <<< "$BUG_JSON")" 80)
  BUG_VERSION=$(_sanitize "$(jq -r '.bugs[0].version // ""' <<< "$BUG_JSON")" 40)
  BUG_STATUS=$(_sanitize "$(jq -r '[.bugs[0].status, .bugs[0].resolution] | map(select(. != null and . != "")) | join("/")' <<< "$BUG_JSON")" 40)
  BUG_SUMMARY=$(_sanitize "$(jq -r '.bugs[0].summary // ""' <<< "$BUG_JSON")" 300)
  BUG_URL="https://$BUGZILLA_HOST/show_bug.cgi?id=$BUG_ID"

  # Product gate. A product listed in product-repos.json is allowed by that fact alone - the entry
  # is what makes the bug routable - so adding a product is one edit in one place. TRIAGE_ALLOWED_
  # PRODUCTS admits a product that has no entry yet and routes it through the model instead. It is
  # comma-separated, not space-separated: product names here include "Docs Cloud" and "API Website".
  #
  # The connectors used to be the argument for model routing, since the product name alone cannot
  # say whether "Zoom" means onlyoffice-zoom or onlyoffice-docspace-zoom. They are listed outright
  # now: an entry takes several repositories, so both variants are simply cloned, and the pairs are
  # 1-13 MB each against sdkjs at 1.2 GB. Disambiguating was never worth a model call at that size.
  local ALLOWED=false PRODUCT_ITEM
  if jq -e --arg product "$PRODUCT" 'any(.products[]; .products | map(ascii_downcase) | index($product | ascii_downcase))' \
       product-repos.json > /dev/null 2>&1; then
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
    _skip_run "product '$PRODUCT' is not routed: no entry in the routing map (buildserver:${TRIAGE_MAP_PATH:-claude_bugzilla_triage/product-repos.json}) and not in TRIAGE_ALLOWED_PRODUCTS (${TRIAGE_ALLOWED_PRODUCTS:-unset})"
    return 78
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

# Recent bugs in the same component, as candidates for "this looks like an existing bug".
#
# Bugzilla cannot find these itself - measured: searching its own summary field for all the words
# of a report returns only that report, and for two of them it returns whatever else happens to
# contain "Files" and "does not work". quicksearch across products was worse. What it can do is
# hand over the recent bugs of one component, which is the pile a human triager skims, and the
# model is already reading the report closely enough to recognise one of them.
#
# Deliberately not fatal and deliberately capped: this is an extra, and a run that cannot fetch it
# is a run that simply does not mention duplicates.
_fetch_similar_bugs() {
  : > related-bugs.txt
  [ -n "${PRODUCT:-}" ] && [ -n "${COMPONENT:-}" ] || return 0
  local LIST
  LIST=$(_bugzilla_get "bug" '--data-urlencode' "product=$PRODUCT" '--data-urlencode' "component=$COMPONENT" '--data-urlencode' "include_fields=id,summary,status,resolution" '--data-urlencode' "limit=${TRIAGE_SIMILAR_LIMIT:-40}" '--data-urlencode' "order=bug_id DESC") || return 0
  # The bug being triaged is in its own component listing; dropping it here keeps the model from
  # solemnly reporting that the bug resembles itself. Angle brackets are escaped for the same
  # reason bugzilla-api.py escapes them: these summaries are text a reporter wrote, they go into a
  # data-only <related_bugs> block, and one containing that closing tag would walk straight out of
  # it.
  jq -r --arg self "$BUG_ID" '.bugs // [] | map(select((.id | tostring) != $self))
    | .[] | [(.id | tostring), ([.status, .resolution] | map(select(. != null and . != "")) | join("/")),
             (.summary | gsub("<"; "&lt;") | gsub(">"; "&gt;"))]
    | @tsv' <<< "$LIST" 2>/dev/null | tr -d '\r' | head -40 > related-bugs.txt || true
  local COUNT
  COUNT=$(wc -l < related-bugs.txt | tr -d " ")
  echo "Related-bug candidates: $COUNT recent bugs in $PRODUCT / $COMPONENT"
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
  : > repos-archived.txt
  while :; do
    local BATCH
    # A failed request is fatal, never a quiet "assume that was the last page": past the last page
    # Gitea answers 200 with [], so -f failing means a real error, and silently truncating the list
    # makes a listed product abort later with a confusing "not in the ONLYOFFICE listing" instead.
    # One retry first, since a single transient 5xx should not sink the run.
    local CODE
    CODE=$(curl -s --max-time 30 --retry 2 --retry-delay 2 -o /tmp/repos-page.json -w '%{http_code}' \
      -H "Authorization: token $GITEA_TOKEN" \
      "https://$GITEA_HOST/api/v1/orgs/$TRIAGE_ORG/repos?limit=50&page=$PAGE")
    if [ "$CODE" != "200" ]; then
      # The code matters: 403 means the token lacks read:organization (it can still clone), which
      # is a scope problem to fix once, not a transient failure to retry forever.
      echo "::warning::Gitea repository listing failed on page $PAGE (HTTP $CODE): $(head -c 160 /tmp/repos-page.json | tr -d '\n')"
      return 1
    fi
    BATCH=$(cat /tmp/repos-page.json)
    COUNT=$(jq -r 'length' <<< "$BATCH")
    [ "$COUNT" = "0" ] && break
    # "name<TAB>language": this Gitea has descriptions on 2 of ~200 repositories, so the primary
    # language is the only extra signal available to the selection call. Only the name is ever
    # used as a clone target (select-repos.py takes field one).
    jq -r '.[] | select(.archived == false) | [.name, (.language // "")] | @tsv' <<< "$BATCH" | tr -d '\r' >> repos-available.txt
    # Kept separately, not discarded: _enrich_candidates unions the routing map back in, and
    # without this an entry that was archived after somebody described it would quietly become
    # selectable and clonable again.
    jq -r '.[] | select(.archived == true) | .name' <<< "$BATCH" | tr -d '\r' >> repos-archived.txt
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

# Merges the two candidate sources into the list the selection call actually reads.
#
# The org listing is the set of repositories that exist; the routing map is the only place
# descriptions exist at all, since this Gitea carries its own description on 2 repositories out of
# ~200. While PAT_GITEA_TOKEN lacked read:organization the listing always failed and the map was
# used alone, so the model chose among 127 described names. With the listing working, using it
# alone would hand the model ~198 names and a language each - more candidates but a worse prompt,
# and repository choice is the one step the pilot measured at 90% first-pick. Taking the union,
# with the map's description preferred, keeps the new coverage without losing the descriptions.
_enrich_candidates() {
  # Never fatal: a failure here leaves the plain listing in place, which is what the run would
  # have used anyway.
  python3 - repos-available.txt product-repos.json map-gaps.txt repos-archived.txt <<'PY' || return 0
import io, json, sys
TAB, NL = chr(9), chr(10)

listed, order = {}, []
try:
    for raw in io.open(sys.argv[1], encoding='utf-8'):
        entry = raw.strip()
        if not entry:
            continue
        parts = entry.split(TAB, 1)
        name = parts[0].strip()
        if not name:
            continue
        if name.lower() not in listed:
            order.append(name)
        listed[name.lower()] = parts[1].strip() if len(parts) > 1 else ''
except OSError:
    raise SystemExit(0)

try:
    described = json.load(io.open(sys.argv[2], encoding='utf-8')).get('repositories', {})
except (OSError, ValueError):
    raise SystemExit(0)
by_lower = {k.lower(): (k, v) for k, v in described.items() if isinstance(v, str)}

rows, with_desc = [], 0
for name in order:
    hit = by_lower.get(name.lower())
    if hit and hit[1].strip():
        rows.append(name + TAB + hit[1].strip())
        with_desc += 1
    else:
        rows.append(name + TAB + listed[name.lower()])

# Names the map knows that the listing did not return. A listing is permission-filtered per page,
# so a curated entry is better evidence that a repository exists than its absence from one call.
archived = set()
try:
    archived = {l.strip().lower() for l in io.open(sys.argv[4], encoding='utf-8') if l.strip()}
except OSError:
    pass
extra = sorted(orig for low, (orig, _) in by_lower.items()
               if low not in listed and low not in archived)
for name in extra:
    rows.append(name + TAB + by_lower[name.lower()][1].strip())
io.open(sys.argv[1], 'w', encoding='utf-8', newline=NL).write(NL.join(rows) + NL)

# The gap list is written to a file, never into this repository: these are private repository
# names and ga-common is mirrored to public GitHub. The job log and step summary are not.
unknown = sorted(n for n in order if n.lower() not in by_lower)
io.open(sys.argv[3], 'w', encoding='utf-8', newline=NL).write(NL.join(unknown) + (NL if unknown else ''))
print('Candidates: ' + str(len(rows)) + ' repositories, ' + str(with_desc + len(extra)) + ' with a description')
if unknown:
    head = ', '.join(unknown[:12]) + (' ...' if len(unknown) > 12 else '')
    noun = ' repository is' if len(unknown) == 1 else ' repositories are'
    print('::notice::' + str(len(unknown)) + noun + ' not in the routing map: ' + head)
PY
  # Reported, never auto-added: which product a new repository serves is a routing decision, and
  # most of what shows up here (blogs, SDK wrappers, test harnesses) can never hold a bug's cause.
  if [ -s map-gaps.txt ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "### Routing map gaps"; echo
      echo "$(wc -l < map-gaps.txt | tr -d ' ') repositories in $TRIAGE_ORG have no entry in the routing map:"
      echo; sed 's/^/- /' map-gaps.txt; } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Clones one repository shallow, preferring the bug's own release branch when it exists.
# .git is dropped afterwards: the model is told it has no history, and this makes that literally
# true while roughly halving what gets copied into the sandbox.
# Picks the branch to analyse, in order: the bug's own release line, then the newest release or
# hotfix line, then develop, then (empty) the repository default.
#
# Matching the bug's version needs a prefix pass, not just an exact one: Bugzilla records "10.0"
# while the branch is release/v10.0.0, so exact-only silently fell back to master - which is the
# wrong code to read for a bug filed against a release. The bug's own line wins over a newer one,
# since a bug against 9.4 has to be judged on 9.4.
_resolve_branch() {
  local REPO="$1" REFS RELEASES MATCH="" ESCAPED
  REFS=$(git ls-remote --heads "https://$GITEA_HOST/$TRIAGE_ORG/$REPO" 2>/dev/null | sed 's#.*refs/heads/##') || REFS=""
  if [ -z "$REFS" ]; then
    # Silence here would look identical to "this repo has no release branch" and quietly hand the
    # analysis the default branch, which is usually master - the wrong code for a release bug.
    echo "::warning::Could not list branches of $REPO - falling back to its default branch" >&2
    return 0
  fi
  RELEASES=$(grep -E '^(release|hotfix)/v?[0-9]' <<< "$REFS" || true)

  if [ -n "${BUG_VERSION:-}" ] && [[ "$BUG_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] && [ -n "$RELEASES" ]; then
    ESCAPED=${BUG_VERSION//./\\.}
    MATCH=$(grep -iE "^(release|hotfix)/v?${ESCAPED}$" <<< "$RELEASES" | head -1 || true)
    # "10.0" also has to find release/v10.0.0; take the highest of the matching line.
    [ -n "$MATCH" ] || MATCH=$(grep -iE "^(release|hotfix)/v?${ESCAPED}(\.|$)" <<< "$RELEASES" | sort -t/ -k2 -V | tail -1 || true)
  fi
  if [ -z "$MATCH" ] && [ -n "$RELEASES" ]; then
    MATCH=$(sort -t/ -k2 -V <<< "$RELEASES" | tail -1)
  fi
  if [ -z "$MATCH" ] && grep -qx "develop" <<< "$REFS"; then
    MATCH="develop"
  fi
  printf '%s' "$MATCH"
}

_clone_repo() {
  local REPO="$1" BRANCH=""
  BRANCH=$(_resolve_branch "$REPO")
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
# A product listed in the routing map skips the model call and uses the listed repositories instead.
_select_and_clone_repos() {
  mkdir -p repos
  : > repos-cloned.txt
  local SELECTED MAPPED_REPOS=""
  # A product listed in product-repos.json skips the model call entirely. Measured on 50 labeled
  # bugs: for DocSpace the selection call returned the same family every time (DocSpace-client and
  # DocSpace-server in 50 of 50 answers), so for a listed product the list is the same answer for
  # free and without run-to-run variance. Unlisted products still go through the model, which is
  # what keeps Docs and Workspace working without anyone maintaining an entry for them first.
  local LISTED
  LISTED=$(jq -r --arg product "$PRODUCT" '
    [.products[] | select(.products | map(ascii_downcase) | index($product | ascii_downcase))]
    | (.[0].repos // []) | .[]' product-repos.json 2>/dev/null | tr -d '\r' || true)
  if [ -n "$LISTED" ]; then
    MAPPED_REPOS=$(paste -sd, - <<< "$LISTED")
    echo "Product '$PRODUCT' is listed in the routing map: $MAPPED_REPOS"
  fi
  if [ -n "$MAPPED_REPOS" ]; then
    SELECTED=""
    local WANTED HAVE_LISTING=false
    [ -s repos-available.txt ] && HAVE_LISTING=true
    # set -f as in the product loop above: these names are input, not globs.
    set -f
    for WANTED in ${MAPPED_REPOS//,/ }; do
      if [ "$HAVE_LISTING" != "true" ]; then
        # A name that came from the routing map does not depend on the org listing - the listing
        # only validates spelling. Losing it degrades the check rather than the run; a wrong name
        # then fails at clone time, which is loud enough.
        SELECTED+="$WANTED"$'\n'
        continue
      fi
      local MATCH
      MATCH=$(cut -f1 repos-available.txt | grep -ixF -- "$WANTED" || true)
      if [ -z "$MATCH" ]; then
        set +f
        echo "::error::Routing map names '$WANTED', which is not in the $TRIAGE_ORG listing"
        return 1
      fi
      SELECTED+="$MATCH"$'\n'
    done
    set +f
    [ "$HAVE_LISTING" = "true" ] || echo "::warning::No repository listing available - taking the mapped names as given"
    echo "Repositories taken from the routing map"
  else
    if [ ! -s repos-available.txt ]; then
      echo "::error::Product '$PRODUCT' has no entry in the routing map, so the model must choose"
      echo "::error::the repositories - but the $TRIAGE_ORG listing could not be read, so there is nothing to choose from"
      return 1
    fi
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
  # Named explicitly: this file is the product gate, so if the fetch left nothing behind, every bug
  # would be rejected as an unlisted product with nothing pointing at the real cause.
  if [ ! -f product-repos.json ]; then
    echo "::error::product-repos.json was not fetched - no product can be routed"
    return 1
  fi
  if ! jq -e '(.products | type == "array") and (.products | length > 0)
       and all(.products[]; (.products | type == "array") and (.repos | type == "array"))
       and (.repositories | type == "object")' product-repos.json > /dev/null 2>&1; then
    echo "::error::product-repos.json must hold a non-empty products[] of {products, repos} entries plus a repositories{} map"
    return 1
  fi
  local DUPES
  DUPES=$(jq -r '[.products[].products[] | ascii_downcase] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' \
    product-repos.json 2>/dev/null | tr -d '\r' || true)
  if [ -n "$DUPES" ]; then
    echo "::error::product-repos.json lists the same product in more than one entry: $DUPES"
    return 1
  fi
}

# Fetches the routing map. It lives in an internal repository rather than here because ga-common is
# mirrored to public GitHub and the map names private repositories; one raw API call is cheaper than
# cloning for a single file. TRIAGE_MAP_REPO/PATH/REF override the location.
_fetch_product_map() {
  local REPO="${TRIAGE_MAP_REPO:-buildserver}"
  local MAP_PATH="${TRIAGE_MAP_PATH:-claude_bugzilla_triage/product-repos.json}"
  # Refs are tried in order: an explicit override, this workflow's own branch, then master. Following
  # the workflow's branch means a pipeline change and the matching map change are developed under the
  # same branch name and picked up together, and it collapses to master once both are merged.
  local CODE="" REF ENCODED
  for REF in ${TRIAGE_MAP_REF:-} "${GITHUB_REF_NAME:-}" master; do
    [ -n "$REF" ] || continue
    ENCODED=${REF//\//%2F}
    CODE=$(curl -s --max-time 30 --retry 2 --retry-delay 2 -o product-repos.json -w '%{http_code}' \
      -H "Authorization: token $GITEA_TOKEN" \
      "https://$GITEA_HOST/api/v1/repos/$TRIAGE_ORG/$REPO/raw/$MAP_PATH?ref=$ENCODED")
    if [ "$CODE" = "200" ]; then
      echo "Routing map from $REPO@$REF: $(jq -r '"\(.products | length) product entries, \(.repositories | length) repositories described"' product-repos.json)"
      return 0
    fi
  done
  echo "::error::Could not fetch $MAP_PATH from $REPO on any ref tried (last HTTP $CODE): $(head -c 160 product-repos.json | tr -d '\n')"
  return 1
}

# The CLI validates triage-schema.json in strict mode, and a keyword outside the JSON Schema
# vocabulary kills the run - but only after the repositories have been cloned and the container
# built. Seen live: a "//" key added as a comment cost a full run. Checking here costs milliseconds.
_validate_triage_schema() {
  python3 - triage/triage-schema.json <<'PY' || return 1
import json, sys
ALLOWED = {"type", "properties", "required", "additionalProperties", "items",
           "description", "enum", "minItems", "maxItems", "maxLength"}

def walk(node, path):
    bad = []
    if isinstance(node, dict):
        for key, value in node.items():
            # Inside a "properties" map the keys are field names, not keywords.
            if path.endswith(".properties"):
                bad += walk(value, f"{path}.{key}")
            elif key not in ALLOWED:
                bad.append(f"{path}.{key}")
            else:
                bad += walk(value, f"{path}.{key}")
    return bad

try:
    schema = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError) as error:
    print(f"::error::triage-schema.json is unreadable ({error})")
    raise SystemExit(1)
offenders = walk(schema, "root")
if offenders:
    print("::error::triage-schema.json has keywords the CLI rejects in strict mode: "
          + ", ".join(offenders))
    raise SystemExit(1)
PY
}

prepare_triage_context() {
  _validate_triage_schema
  _fetch_product_map
  _validate_product_map
  # 78 is _skip_run's signal: the bug is deliberately not analysed. Nothing failed, so the step
  # ends green here and the later steps gate on steps.prepare.outputs.skip instead.
  local METADATA_RC=0
  _fetch_bug_metadata || METADATA_RC=$?
  [ "$METADATA_RC" = "78" ] && return 0
  [ "$METADATA_RC" = "0" ] || return "$METADATA_RC"
  _render_bug_context
  _fetch_similar_bugs
  # Screenshots the reporter attached. 18 of the first 28 bugs had attachments, and a screenshot
  # is regularly the only place the symptom is actually visible - see fetch-attachments.py.
  rm -rf attachments; : > attachments.txt
  python3 .gitea/scripts/fetch-attachments.py --bug-id "$BUG_ID" --out-dir attachments > attachments.txt || true
  # Tolerated, not required: a listed product already knows its repositories, and the listing only
  # validates their spelling and feeds expand-repos.py. It is mandatory solely for model selection,
  # which _select_and_clone_repos checks for itself. Seen live: PAT_GITEA_TOKEN can clone but may
  # lack read:organization, and that must not stop a bug whose repositories are already known.
  : > repos-available.txt
  if _list_candidate_repos; then
    _enrich_candidates
  else
    # The map itself is the fallback candidate list, and a better one for the model than the org
    # listing ever was: this Gitea carries descriptions on 2 repositories out of ~200, while every
    # entry here has one. It covers only repositories somebody has described, so a product with no
    # entry still needs the listing (and therefore the read:organization scope).
    jq -r '.repositories | to_entries[] | [.key, .value] | @tsv' product-repos.json 2>/dev/null \
      | tr -d '\r' > repos-available.txt || true
    if [ -s repos-available.txt ]; then
      echo "::warning::No org listing - using the $(wc -l < repos-available.txt | tr -d ' ') repositories described in the routing map as candidates"
    else
      echo "::warning::Continuing without any repository listing"
    fi
  fi
  _select_and_clone_repos
  _expand_and_clone_declared_repos
  _render_repositories_block

  BUGZILLA_CONTEXT=$(cat bug-context.txt)
  # Rendered from the TSV rather than passed through raw, so the prompt shows aligned columns and
  # the block is empty - not the word "none" - when there was nothing to fetch.
  RELATED_BUGS=$(awk -F'\t' '{ printf "%s  %-16s %s\n", $1, $2, $3 }' related-bugs.txt 2>/dev/null || true)
  # "attachments/<file> - <what the reporter called it>: <their description>", one per line. The
  # path is what the model opens; the rest is context and is already escaped by the fetcher.
  ATTACHMENTS=$(awk -F'\t' '{ printf "attachments/%s - %s%s\n", $1, $2, ($3 == "" ? "" : ": " $3) }' attachments.txt 2>/dev/null || true)
  [ -n "$ATTACHMENTS" ] || ATTACHMENTS="(none)"
  [ -n "$RELATED_BUGS" ] || RELATED_BUGS="(none available)"
  export BUG_ID BUG_URL PRODUCT COMPONENT BUGZILLA_CONTEXT REPOSITORIES RELATED_BUGS ATTACHMENTS
  # Explicit variable list, so a stray $-looking token in the template is left alone. The single
  # quotes are required: envsubst takes the variable *names*, so expanding them here would defeat it.
  envsubst '$BUG_ID $BUG_URL $PRODUCT $COMPONENT $BUGZILLA_CONTEXT $REPOSITORIES $RELATED_BUGS $ATTACHMENTS' \
    < triage/TRIAGE.md > claude-prompt.txt
  echo "Prompt rendered: $(wc -c < claude-prompt.txt | tr -d ' ') bytes"

  # Read back by report_triage_result, which runs in a later step with a fresh shell.
  { echo "PRODUCT=$PRODUCT"; echo "COMPONENT=$COMPONENT"; echo "BUG_URL=$BUG_URL"; } >> "$GITHUB_ENV"
}

# Posts the rendered analysis as a comment on the bug. Called by its own step, after the message
# has already been written to the job log and the step summary.
#
# A comment, never the description: the description is the reporter's text and belongs to them.
#
# The tracker is closed - show_bug.cgi serves a login page to an anonymous request and the REST
# API answers 401 - so the private repository names and paths in the message stay inside. That is
# the reason this is allowed to post at all, and the reason to check again before ever opening the
# tracker up.
#
# Nothing is posted for a run that has nothing to say: a deliberate skip, a fallback where the
# analysis should be, or an empty message. A bug thread is read by people, and "the pipeline could
# not produce a result" is a line for the run log, not for the bug.
publish_triage_comment() {
  if [ "${TRIAGE_PUBLISH:-false}" != "true" ]; then
    echo "Publishing is off (TRIAGE_PUBLISH=${TRIAGE_PUBLISH:-false}) - the comment was not posted"
    return 0
  fi
  if [ -s triage-skip-reason.txt ]; then
    echo "Bug $BUG_ID was skipped - nothing to publish"
    return 0
  fi
  if [ ! -s triage-message.txt ]; then
    echo "::warning::No rendered message to publish for bug $BUG_ID"
    return 0
  fi
  if grep -q "NO RESULT" triage-message.txt; then
    echo "The run produced no analysis - not publishing a failure notice into the bug"
    return 0
  fi
  if [ -z "${BUGZILLA_API_KEY:-}" ] || [ -z "${BUGZILLA_HOST:-}" ]; then
    echo "::warning::BUGZILLA_API_KEY or BUGZILLA_HOST is unset - the comment was not posted"
    return 0
  fi

  # Once per bug, with no way to override it. A second opinion on the same report is not worth a
  # second comment in a thread people read, and a re-run that silently doubled the noise would be
  # discovered by the reader rather than by us. The first line of every message carries this
  # marker, so the existing one is found without a hidden tag - Bugzilla comments are plain text
  # and cannot hide anything.
  local EXISTING
  EXISTING=$(_bugzilla_get "bug/$BUG_ID/comment" 2>/dev/null | jq -r '[.bugs[]?.comments[]? | select(.text | contains("Claude Bug Triage"))] | length' 2>/dev/null || echo 0)
  if [ "${EXISTING:-0}" != "0" ]; then
    echo "Bug $BUG_ID already carries a Claude triage comment - not posting another"
    return 0
  fi

  local CODE
  CODE=$(curl -s --max-time 45 --retry 2 --retry-delay 3 -o publish-response.json -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    "https://$BUGZILLA_HOST/rest/bug/$BUG_ID/comment?api_key=$BUGZILLA_API_KEY" \
    -d "$(jq -Rs '{comment: .}' < triage-message.txt)")
  # Never fatal. The analysis is already in the log, the summary and the artifacts; a tracker that
  # refuses the write must not turn a finished run red.
  if [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then
    echo "Posted the analysis as a comment on bug $BUG_ID (HTTP $CODE)"
  else
    echo "::warning::Could not post the comment on bug $BUG_ID (HTTP $CODE): $(head -c 200 publish-response.json | tr -d '\n')"
  fi
}

# Renders the analysis (or a fallback) into the job log and the step summary. This message body is
# what will later be posted as the Bugzilla comment, so it is plain text, not markdown.
report_triage_result() {
  if [ -s triage-skip-reason.txt ]; then
    local REASON
    REASON=$(cat triage-skip-reason.txt)
    echo "Bug $BUG_ID was not analysed: $REASON"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { echo "## Claude triage: Bug $BUG_ID skipped"; echo
        if [ -n "${BUG_URL:-}" ]; then echo "[Bug $BUG_ID in Bugzilla]($BUG_URL)"; echo; fi
        echo "$REASON"; } >> "$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi

  local ARGS=(--bug-id "$BUG_ID" --product "${PRODUCT:-}" --component "${COMPONENT:-}")
  # repos-cloned.txt holds 'name@ref' per line. The renderer needs both halves: the name to mark
  # any repository the analysis cites but the run never cloned, and the ref because a line number
  # means nothing until the reader knows which branch it was read from - triage clones the release
  # or hotfix line, not master, so the numbers do not match a fresh master checkout.
  if [ -s repos-cloned.txt ]; then
    ARGS+=(--repos-file repos-cloned.txt)
  fi
  # Same shape as gitea-api.sh's _run_url. Gives the reader the artifacts and the debug log behind
  # this message, which is the only way to tell a thin analysis from a broken run.
  if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITEA_HOST:-}" ]; then
    ARGS+=(--run-url "https://$GITEA_HOST/${GITHUB_REPOSITORY:-$TRIAGE_ORG/ga-common}/actions/runs/$GITHUB_RUN_ID")
  fi
  if [ -s claude-structured.json ]; then
    ARGS+=(--structured claude-structured.json)
  else
    ARGS+=(--fallback "the triage run produced no valid structured output (job status: ${JOB_STATUS:-unknown})")
    # A green run that posts this is still a malfunction: the bug got no analysis. Recorded here,
    # where the pipeline knows it happened, and reported by the notify step at the end.
    # pipeline-failure.txt is read by the last step of the workflow, Notify on failure, which
    # cannot source anything from here: it has to work when the failure happened before the
    # checkout. The name is spelled out in both places on purpose.
    echo "no analysis produced (job status: ${JOB_STATUS:-unknown})" > pipeline-failure.txt
  fi

  # Who last changed the exact line each location points at, plus the host and org the renderer
  # needs to build links. Extra API calls, no model spend, silent per location when it cannot be
  # established - see line-history.py for why the line and not the file.
  #
  # Guarded as a whole, and not merely per command: under set -euo pipefail a jq or awk reading a
  # file that is not there fails the assignment and takes the whole function with it - and the
  # file that is not there is claude-structured.json, which is precisely the failed run this
  # function still has to report.
  local FIRST_REPO="" FIRST_PATH="" FIRST_LINE="" FIRST_REF="" FIRST_URL=""
  : > line-history.txt
  if [ -s claude-structured.json ] && [ -s repos-cloned.txt ]; then
    local LOC_INDEX=0 LOC_REPO LOC_PATH LOC_LINE LOC_REF
    while IFS=$'\t' read -r LOC_REPO LOC_PATH LOC_LINE; do
      LOC_INDEX=$((LOC_INDEX + 1))
      LOC_REF=$(awk -F@ -v r="$LOC_REPO" 'tolower($1) == tolower(r) { print substr($0, index($0, "@") + 1); exit }' repos-cloned.txt 2>/dev/null || true)
      # _clone_repo writes "unknown" when it cannot read the checked-out branch. Following it
      # would mean a history lookup on a ref that does not exist and a link to a guaranteed 404.
      [ "$LOC_REF" = "unknown" ] && LOC_REF=""
      if [ "$LOC_INDEX" = "1" ]; then
        FIRST_REPO="$LOC_REPO" FIRST_PATH="$LOC_PATH" FIRST_LINE="$LOC_LINE" FIRST_REF="$LOC_REF"
      fi
      if [ -n "$LOC_REPO" ] && [ -n "$LOC_PATH" ] && [ -n "$LOC_REF" ] && [[ "$LOC_LINE" =~ ^[0-9]+$ ]]; then
        local FOUND
        FOUND=$(python3 .gitea/scripts/line-history.py --repo "$LOC_REPO" --ref "$LOC_REF" \
          --path "$LOC_PATH" --line "$LOC_LINE" 2>/dev/null || true)
        [ -n "$FOUND" ] && printf '%s\t%s\n' "$LOC_INDEX" "$FOUND" >> line-history.txt
      fi
    done < <(jq -r '(.locations // [])[0:6][] | [(.repository // ""), (.path // ""), ((.line // "") | tostring)] | @tsv' claude-structured.json 2>/dev/null || true)
    if [ -n "${GITEA_HOST:-}" ] && [ -n "$FIRST_REPO" ] && [ -n "$FIRST_REF" ] && [ -n "$FIRST_PATH" ]; then
      FIRST_URL="https://$GITEA_HOST/${TRIAGE_ORG:-ONLYOFFICE}/$FIRST_REPO/src/branch/$FIRST_REF/$FIRST_PATH"
      if [[ "$FIRST_LINE" =~ ^[0-9]+$ ]]; then
        FIRST_URL="$FIRST_URL#L$FIRST_LINE"
      fi
    fi
  fi
  if [ -s line-history.txt ]; then
    ARGS+=(--line-history line-history.txt)
  fi
  ARGS+=(--gitea-host "${GITEA_HOST:-}" --org "${TRIAGE_ORG:-ONLYOFFICE}")
  # The renderer takes the status of a resembling bug from here rather than from the analysis: it
  # is a fact already fetched, and one the answer should not get a chance to restate wrongly.
  if [ -s related-bugs.txt ]; then
    ARGS+=(--related-file related-bugs.txt)
  fi

  python3 .gitea/scripts/render-triage.py "${ARGS[@]}" --output triage-message.txt > /dev/null

  echo "--- triage message ---"
  cat triage-message.txt
  echo "--- end ---"

  # Fenced in the summary so the plain-text body is shown verbatim, exactly as Bugzilla would get it.
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    # The link lives here and not in the message: the message becomes a comment on this very bug,
    # where a link back to it is noise, while a reader of the run has no other way to reach it.
    local SUMMARY_LINKS=""
    if [ -n "${BUG_URL:-}" ]; then
      SUMMARY_LINKS="[Bug $BUG_ID in Bugzilla]($BUG_URL)"
    fi
    if [ -n "$FIRST_URL" ]; then
      SUMMARY_LINKS="${SUMMARY_LINKS:+$SUMMARY_LINKS · }[$FIRST_PATH${FIRST_LINE:+:$FIRST_LINE}]($FIRST_URL)"
    fi
    { echo "## Claude triage: Bug $BUG_ID"; echo
      if [ -n "$SUMMARY_LINKS" ]; then echo "$SUMMARY_LINKS"; echo; fi
      echo '```text'; cat triage-message.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
  fi
}
