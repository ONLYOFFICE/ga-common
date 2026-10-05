#!/usr/bin/env bash
# Everything the bugzilla-triage.yml workflow runs on the runner, one subcommand per step:
#
#   triage-run.sh prepare   fetch the bug, run the guards, choose and clone repositories, render the prompt
#   triage-run.sh sandbox   run the analysis in the isolated container and, when it is confident, the fix session
#   triage-run.sh open-pr   validate the fix patch and open a draft pull request (the only step that can push)
#   triage-run.sh report    render the result into the job log and step summary
#   triage-run.sh publish   post the result to Bugzilla
#   triage-run.sh notify    send the finished result to Telegram
#
# Run as `bash .gitea/scripts/triage-run.sh <subcommand>`. It can also be sourced to reach the functions
# below directly, which is how the local tests drive them.
#
# The sections are kept in the order the steps run: prepare/report, sandbox, fix.

set -euo pipefail

# ============================================================================
# Prepare, report and publish
# ============================================================================
# Prepare and report: fetch the bug, run the guards, pick and clone repositories, render the prompt
# (prepare_triage_context), then render the result into the job log and step summary
# (report_triage_result) and post it to Bugzilla (publish_triage_comment).
#
# Expects from the job env: BUG_ID, BUGZILLA_HOST, BUGZILLA_API_KEY, GITEA_HOST, GITEA_TOKEN,
# ANTHROPIC_API_KEY (for the repository-selection call). Optional: TRIAGE_ORG (default ONLYOFFICE),
# TRIAGE_ALLOWED_PRODUCTS (default empty - product-repos.json is what admits a product),
# SELECT_MAX_REPOS (see triage-tools.py select-repos).

TRIAGE_ORG="${TRIAGE_ORG:-ONLYOFFICE}"
# Empty by default: product-repos.json is what admits a product. This is only for products
# routed by the model rather than by a list entry - comma-separated, or "*" for any product.
TRIAGE_ALLOWED_PRODUCTS="${TRIAGE_ALLOWED_PRODUCTS:-}"

# Caps by characters, not bytes: bash's own ${var:0:n} slices bytes under a non-UTF-8 locale, which
# both halves the cap and can sever a codepoint mid-sequence on this org's routinely-Cyrillic bug
# text. Kept identical to review-run.sh's helper of the same name.
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
  # A skip is not a failure - the run stays green - but it is the one outcome nobody finds out
  # about otherwise: the bug simply never gets an analysis. An unrouted product is a hole in the
  # routing map, and holes only get filled if somebody hears about them. pipeline-notice.txt is
  # read by the workflow's last step; the name is spelled out there too, since that step cannot
  # source this file.
  echo "skipped - $REASON" >> pipeline-notice.txt
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
    | join("; ")' <<< "$BUG_JSON" | tr -d '\r') || {
    # This function is called as `f || ...`, which switches set -e off inside it: without this an
    # error in the filter above would leave RESTRICTION empty and send a restricted bug to the model.
    echo "::error::Could not evaluate the access restrictions of bug $BUG_ID - not analysing it"
    return 1
  }
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

# Renders the <bug> data block (common.py bugzilla-context does its own sanitizing and mojibake repair).
_render_bug_context() {
  python3 .gitea/scripts/common.py bugzilla-context "$BUG_ID" > bug-context.txt || true
  # common.py bugzilla-context never exits non-zero: a failed fetch still prints a "data not retrieved" stub
  # and returns 0, and that stub is non-empty, so testing the exit status (or just -s) would feed
  # an empty bug report into a full-budget analysis. The rendered Summary line is the real signal.
  if ! grep -q '^- Summary: .' bug-context.txt; then
    echo "::warning::common.py bugzilla-context returned no usable bug data - falling back to the metadata already fetched"
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
  # reason common.py bugzilla-context escapes them: these summaries are text a reporter wrote, they go into a
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
    # used as a clone target (triage-tools.py select-repos takes field one).
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
  # Already cloned (a routing entry listing a name twice, or two spellings of it): cloning again
  # would fail on the existing directory, and the failure handler below would delete the first clone.
  if [ -d "repos/$REPO" ]; then
    return 0
  fi
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

# Model-driven selection (see triage-tools.py select-repos) followed by the clones; at least one repo must land.
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
    SELECTED=$(python3 .gitea/scripts/triage-tools.py select-repos \
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
# package.json / .gitmodules - see triage-tools.py expand-repos for the measured case (Bug 83616).
_expand_and_clone_declared_repos() {
  local EXTRA
  sed 's/@[^@]*$//' repos-cloned.txt > repos-cloned-names.txt
  EXTRA=$(python3 .gitea/scripts/triage-tools.py expand-repos \
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
#
# Takes the schema path and, optionally, "warning" as a second argument: the fix schema is optional
# machinery, and a mistake in it must not be reported as an error in an otherwise good analysis run.
_validate_triage_schema() {
  python3 - "${1:-triage/triage-schema.json}" "${2:-error}" <<'PY' || return 1
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
    print(f"::{sys.argv[2]}::{sys.argv[1]} is unreadable ({error})")
    raise SystemExit(1)
offenders = walk(schema, "root")
if offenders:
    print(f"::{sys.argv[2]}::{sys.argv[1]} has keywords the CLI rejects in strict mode: "
          + ", ".join(offenders))
    raise SystemExit(1)
PY
}

# A bug that already has its fix branch in one of the cloned repositories gets no second fix session:
# the pull request step would refuse to open one anyway, and by then the session would be paid for.
# Only a clear answer counts; the pull request step still makes its own check before it pushes.
_note_existing_fix_branch() {
  if [ ! -s repos-cloned.txt ] || [ -s fix-disabled.txt ]; then return 0; fi
  local NAME FOUND
  while IFS= read -r NAME || [ -n "$NAME" ]; do
    NAME="${NAME%%@*}"
    if [ -z "$NAME" ]; then continue; fi
    FOUND=$(timeout 30 git ls-remote --heads "https://$GITEA_HOST/$TRIAGE_ORG/$NAME" "refs/heads/${FIX_BRANCH_PREFIX}${BUG_ID}" 2>/dev/null || true)
    if [ -n "$FOUND" ]; then
      echo "a fix branch for this bug already exists in $NAME" > fix-disabled.txt
      echo "A fix branch for bug $BUG_ID already exists in $NAME - no fix session will run"
      return 0
    fi
  done < repos-cloned.txt
}

prepare_triage_context() {
  _validate_triage_schema
  rm -f fix-disabled.txt
  if ! _validate_triage_schema triage/fix-schema.json warning; then
    echo "the fix schema is invalid" > fix-disabled.txt
  fi
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
  # is regularly the only place the symptom is actually visible - see triage-tools.py fetch-attachments.
  rm -rf attachments; : > attachments.txt
  python3 .gitea/scripts/triage-tools.py fetch-attachments --bug-id "$BUG_ID" --out-dir attachments > attachments.txt || true
  # Unpacks any zip/tar among them in place, on this runner and before the sandbox exists - see
  # triage-tools.py expand-attachments for why that order matters. Extracted paths are appended to the same
  # manifest the model sees, right after the archive that produced them.
  ATTACHMENTS_EXTRACTED=$(python3 .gitea/scripts/triage-tools.py expand-attachments attachments 2>attachments-expand.log || true)
  # Tolerated, not required: a listed product already knows its repositories, and the listing only
  # validates their spelling and feeds triage-tools.py expand-repos. It is mandatory solely for model selection,
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
  _note_existing_fix_branch
  _render_repositories_block

  BUGZILLA_CONTEXT=$(cat bug-context.txt)
  # Rendered from the TSV rather than passed through raw, so the prompt shows aligned columns and
  # the block is empty - not the word "none" - when there was nothing to fetch.
  RELATED_BUGS=$(awk -F'\t' '{ printf "%s  %-16s %s\n", $1, $2, $3 }' related-bugs.txt 2>/dev/null || true)
  # "attachments/<file> - <what the reporter called it>: <their description>", one per line. The
  # path is what the model opens; the rest is context and is already escaped by the fetcher.
  ATTACHMENTS=$(awk -F'\t' '{ printf "attachments/%s - %s%s\n", $1, $2, ($3 == "" ? "" : ": " $3) }' attachments.txt 2>/dev/null || true)
  if [ -n "${ATTACHMENTS_EXTRACTED:-}" ]; then
    local EXTRACTED_LINES
    EXTRACTED_LINES=$(printf '%s' "$ATTACHMENTS_EXTRACTED" | sed 's/^/attachments\//; s/$/ - extracted from the archive above/')
    ATTACHMENTS="${ATTACHMENTS:+$ATTACHMENTS$'\n'}$EXTRACTED_LINES"
  fi
  [ -n "$ATTACHMENTS" ] || ATTACHMENTS="(none)"
  [ -n "$RELATED_BUGS" ] || RELATED_BUGS="(none available)"
  export BUG_ID BUG_URL PRODUCT COMPONENT BUGZILLA_CONTEXT REPOSITORIES RELATED_BUGS ATTACHMENTS
  # Explicit variable list, so a stray $-looking token in the template is left alone. The single
  # quotes are required: envsubst takes the variable *names*, so expanding them here would defeat it.
  envsubst '$BUG_ID $BUG_URL $PRODUCT $COMPONENT $BUGZILLA_CONTEXT $REPOSITORIES $RELATED_BUGS $ATTACHMENTS' \
    < triage/TRIAGE.md > claude-prompt.txt
  echo "Prompt rendered: $(wc -c < claude-prompt.txt | tr -d ' ') bytes"

  # Read back by report_triage_result, which runs in a later step with a fresh shell.
  { echo "PRODUCT=$PRODUCT"; echo "COMPONENT=$COMPONENT"; echo "BUG_URL=$BUG_URL"; echo "BUG_STATUS=$BUG_STATUS"; } >> "$GITHUB_ENV"
}

# The body of the Bugzilla comment: the link to the draft pull request the fix stage opened, and nothing
# else. What a bug needs from this pipeline is the proposed fix; the analysis stays in the run, so nothing
# from the repositories (paths, code, names) is copied into the tracker. Returns 1 when there is no
# pull request to link to.
_publish_body() {
  local PR_URL=""
  if [ -s fix-pr-url.txt ]; then
    PR_URL=$(head -1 fix-pr-url.txt | tr -d '\r' | tr -d ' ')
    # Only a plain https link goes into the tracker, whatever the file holds.
    case "$PR_URL" in https://*) ;; *) PR_URL="" ;; esac
  fi
  if [ -z "$PR_URL" ]; then
    return 1
  fi
  printf 'Claude Bug Triage\n'
  printf 'Pull request (draft, not reviewed): %s\n' "$PR_URL"
  return 0
}

# Posts a short comment on the bug with the link to the draft pull request, when the fix stage opened one.
# Called by its own step, after the full message has already been written to the job log and the step summary.
#
# A comment, never the description: the description is the reporter's text and belongs to them.
#
# The pull request link only, not the analysis: a bug thread is read by people who want the fix, and the run
# holds the analysis for anyone who wants it. A run that opened no pull request (a deliberate skip, a
# low-confidence analysis, a refused patch, a failure) writes nothing into the bug.
publish_triage_comment() {
  if [ "${TRIAGE_PUBLISH:-false}" != "true" ]; then
    echo "Publishing is off (TRIAGE_PUBLISH=${TRIAGE_PUBLISH:-false}) - the comment was not posted"
    return 0
  fi
  if [ -s triage-skip-reason.txt ]; then
    echo "Bug $BUG_ID was skipped - nothing to publish"
    return 0
  fi
  if ! _publish_body > /dev/null; then
    echo "No pull request was opened for bug $BUG_ID - nothing to publish"
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
  local EXISTING COMMENTS_JSON
  COMMENTS_JSON=$(_bugzilla_get "bug/$BUG_ID/comment" 2>/dev/null) || {
    echo "::warning::Could not read the comments of bug $BUG_ID to check for an earlier triage comment - not posting"
    return 0
  }
  EXISTING=$(jq -r '[.bugs[]?.comments[]? | select(.text | contains("Claude Bug Triage"))] | length' <<< "$COMMENTS_JSON" 2>/dev/null) || {
    echo "::warning::Could not parse the comments of bug $BUG_ID - not posting"
    return 0
  }
  if [ "${EXISTING:-0}" != "0" ]; then
    echo "Bug $BUG_ID already carries a Claude triage comment - not posting another"
    return 0
  fi

  local BODY CODE
  BODY=$(_publish_body)
  CODE=$(curl -s --max-time 45 --retry 2 --retry-delay 3 -o publish-response.json -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" \
    "https://$BUGZILLA_HOST/rest/bug/$BUG_ID/comment?api_key=$BUGZILLA_API_KEY" \
    -d "$(printf '%s\n' "$BODY" | jq -Rs '{comment: .}')")
  # Never fatal. The analysis is already in the log, the summary and the artifacts; a tracker that
  # refuses the write must not turn a finished run red.
  if [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then
    echo "Posted the pull request link as a comment on bug $BUG_ID (HTTP $CODE)"
  else
    echo "::warning::Could not post the comment on bug $BUG_ID (HTTP $CODE): $(head -c 200 publish-response.json | tr -d '\n')"
    # A finished analysis that never reached the bug is worth a message: nothing outside this
    # step sees it otherwise, since the step is continue-on-error and the run still ends green.
    echo "could not post the comment on bug $BUG_ID (HTTP $CODE)" >> pipeline-notice.txt
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
  # Same shape as review-run.sh's _run_url. Gives the reader the artifacts and the debug log behind
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
  # established - see triage-tools.py line-origin for why the line and not the file.
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
        FOUND=$(python3 .gitea/scripts/triage-tools.py line-origin --repo "$LOC_REPO" --ref "$LOC_REF" \
          --path "$LOC_PATH" --line "$LOC_LINE" 2>/dev/null || true)
        [ -n "$FOUND" ] && printf '%s\t%s\n' "$LOC_INDEX" "$FOUND" >> line-history.txt
      fi
    done < <(jq -r '(.locations // [])[0:6][] | [(.repository // ""), (.path // ""), ((.line // "") | tostring)] | @tsv' claude-structured.json 2>/dev/null || true)
    # The three names come from model output and land in a markdown link, so only a plain path
    # spelling is accepted: a "](https://..." in a path would otherwise define a link of its own.
    local PLAIN_NAME='^[A-Za-z0-9._/@+-]+$'
    if [ -n "${GITEA_HOST:-}" ] && [ -n "$FIRST_REPO" ] && [ -n "$FIRST_REF" ] && [ -n "$FIRST_PATH" ] \
       && [[ "$FIRST_REPO" =~ $PLAIN_NAME ]] && [[ "$FIRST_REF" =~ $PLAIN_NAME ]] && [[ "$FIRST_PATH" =~ $PLAIN_NAME ]]; then
      FIRST_URL="https://$GITEA_HOST/${TRIAGE_ORG:-ONLYOFFICE}/$FIRST_REPO/src/branch/$FIRST_REF/$FIRST_PATH"
      if [[ "$FIRST_LINE" =~ ^[0-9]+$ ]]; then
        FIRST_URL="$FIRST_URL#L$FIRST_LINE"
      fi
    fi
  fi
  if [ -s line-history.txt ]; then
    ARGS+=(--line-history line-history.txt)
  fi
  # The analysis saying "the cause is in code you did not give me" is a routing-map hole reported
  # from the other side, and the most valuable one: it is how onlyoffice-ai-chat and Docker-MailServer
  # were found. It reaches the message too, but only somebody reading that bug sees it there.
  if [ -s claude-structured.json ]; then
    local WANTED
    WANTED=$(jq -r '.missing_repository // ""' claude-structured.json 2>/dev/null | tr -d '\r' | head -c 120 || true)
    if [ -n "$WANTED" ] && [ "$WANTED" != "null" ]; then
      echo "analysis places the cause in $WANTED, which the routing map did not supply" >> pipeline-notice.txt
    fi
  fi
  ARGS+=(--gitea-host "${GITEA_HOST:-}" --org "${TRIAGE_ORG:-ONLYOFFICE}")
  # The renderer takes the status of a resembling bug from here rather than from the analysis: it
  # is a fact already fetched, and one the answer should not get a chance to restate wrongly.
  if [ -s related-bugs.txt ]; then
    ARGS+=(--related-file related-bugs.txt)
  fi

  if [ -s fix-pr-url.txt ]; then
    ARGS+=(--pr-url "$(cat fix-pr-url.txt)")
  fi

  python3 .gitea/scripts/triage-tools.py render "${ARGS[@]}" --output triage-message.txt > /dev/null

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

# One line of model output as plain text: no control characters, one line, capped by characters.
_plain_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' | tr -s ' ' | _trim_chars "${2:-200}" | sed 's/^ *//; s/ *$//'
}

# The finished result as a Telegram message, one per analysed bug, to every chat id in TELEGRAM_CHAT_ID
# (comma-separated, as the other workflows read it). A run with no analysis says nothing here: the alert
# step of the workflow already reports it. Plain text, no parse mode, so nothing the model wrote is markup.
notify_result() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "::warning::TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is unset - the result is not sent"
    return 0
  fi
  if [ -s triage-skip-reason.txt ] || [ -s pipeline-failure.txt ] || [ ! -s claude-structured.json ]; then
    echo "No analysis for bug $BUG_ID - nothing to send"
    return 0
  fi

  local CONFIDENCE NOTE PR_URL="" PR_LINE RUN_URL="" TEXT CHAT_ID CODE
  CONFIDENCE=$(_plain_line "$(jq -r '.summary.confidence // "unstated"' claude-structured.json 2>/dev/null || true)" 20)
  NOTE=$(_plain_line "$(jq -r '.summary.note_kind // ""' claude-structured.json 2>/dev/null || true)" 40)

  if [ -s fix-pr-url.txt ]; then
    PR_URL=$(head -1 fix-pr-url.txt | tr -d '\r ')
    case "$PR_URL" in https://*) ;; *) PR_URL="" ;; esac
  fi
  if [ -n "$PR_URL" ]; then
    PR_LINE="PR: $PR_URL"
  elif [ -s fix-skip-reason.txt ]; then
    PR_LINE="No PR: $(_plain_line "$(head -1 fix-skip-reason.txt)" 100)"
  else
    PR_LINE="No PR"
  fi
  if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITEA_HOST:-}" ]; then
    RUN_URL="https://$GITEA_HOST/${GITHUB_REPOSITORY:-$TRIAGE_ORG/ga-common}/actions/runs/$GITHUB_RUN_ID"
  fi

  TEXT=$(printf 'Bug %s · %s%s' "$BUG_ID" "$CONFIDENCE" "${NOTE:+ · $NOTE}")
  TEXT+=$(printf '\n%s' "$PR_LINE")
  if [ -n "$RUN_URL" ]; then TEXT+=$(printf '\nRun: %s' "$RUN_URL"); fi

  for CHAT_ID in ${TELEGRAM_CHAT_ID//,/ }; do
    CODE=$(curl -s --max-time 20 --retry 2 -o /dev/null -w '%{http_code}' -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg id "$CHAT_ID" --arg text "$TEXT" '{chat_id: $id, text: $text, disable_web_page_preview: true}')" || true)
    if [ "$CODE" = "200" ]; then
      echo "Result sent to Telegram"
    else
      echo "::warning::Telegram refused the result (HTTP ${CODE:-none})"
    fi
  done
  return 0
}

# ============================================================================
# Isolated-container sandbox
# ============================================================================
# Isolated-container sandbox helpers for bugzilla-triage.yml's "Run triage" step; expects
# ANTHROPIC_API_KEY/CLAUDE_MODEL/CLAUDE_CODE_VERSION/CLAUDE_EFFORT/CLAUDE_MAX_BUDGET_USD from the job env.
# Optional tuning: SANDBOX_PIDS_LIMIT (default 1024), SANDBOX_MEMORY (unset = no ceiling).
#
# Deliberately a sibling of review-run.sh rather than a shared refactor of it: that file is the
# battle-tested path for every repo's PR review, and the differences here are structural (several
# repositories side by side under /workspace instead of one, its own prompt/schema paths), not
# parameters. Fixes that apply to both - the DooD host-path resolution, the backgrounded exec so
# traps fire, the capability drop - are worth porting by hand in both directions.

# Names this run's resources (per-run, never fixed: a fixed name lets one run's cleanup kill another's live sandbox) and pre-creates claude-output/.
name_triage_resources() {
  local RUN_TAG="${GITHUB_RUN_ID:-$$}"
  NET_NAME="triage-internal-$RUN_TAG"
  PROXY_NAME="triage-proxy-$RUN_TAG"
  SANDBOX_NAME="claude-triage-$RUN_TAG"

  mkdir -p claude-output
  # Pre-create both before anything below can fail under `set -e`, so the upload/report steps always find real (if empty) files.
  touch claude-output/claude-output.json claude-output/claude-debug.log
}

# Sandbox and proxy are siblings on the HOST daemon, not children of this job, so a cancelled job does not stop them - clean up on every exit path.
cleanup_triage_sandbox() {
  docker rm -f "$PROXY_NAME" "$SANDBOX_NAME" > /dev/null 2>&1 || true
  docker network rm "$NET_NAME" > /dev/null 2>&1 || true
  scrub_claude_output
}

# /output is a bind mount the model can write to, and the artifact upload and the patch reader both
# follow symlinks: a link to /proc/self/environ or a runner file would leave in a downloadable
# artifact. Anything that is not a plain file or a directory is removed on every exit path.
scrub_claude_output() {
  [ -d claude-output ] || return 0
  find claude-output \( -type l -o -type p -o -type s -o -type b -o -type c \) -delete 2>/dev/null || true
}

# Resolves the host path backing $PWD (docker -v resolves on the HOST under DooD); empty HOST_OUTPUT_DIR means callers fall back to docker cp.
resolve_triage_output_dir() {
  HOST_OUTPUT_DIR=""
  # By container ID from cgroup, not hostname: this runner sets a custom --hostname unrelated to the real container ID.
  local SELF_ID
  SELF_ID=$(grep -oE '[0-9a-f]{64}' /proc/self/cgroup 2>/dev/null | head -1 || true)
  [ -n "$SELF_ID" ] || SELF_ID="$(hostname)"
  local HOST_PWD
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

# Builds the isolated network + egress-restricted proxy + sandbox, copies the cloned repos and triage/ in, installs the CLI.
# Expects NET_NAME/PROXY_NAME/SANDBOX_NAME/HOST_OUTPUT_DIR set, repos under ./repos/<name>, and claude-prompt.txt in $PWD.
setup_triage_sandbox() {
  docker network create --internal "$NET_NAME" > /dev/null
  mkdir -p /tmp/squid-triage
  cat > /tmp/squid-triage/squid.conf << 'EOF'
http_port 3128
acl allowed_dst dstdomain .npmjs.org api.anthropic.com
http_access allow allowed_dst
http_access deny all
EOF
  docker create --name "$PROXY_NAME" --network "$NET_NAME" ubuntu/squid:latest > /dev/null
  # docker cp streams over the API, so it works under DooD regardless of whose filesystem the source is on, unlike -v.
  docker cp /tmp/squid-triage/squid.conf "$PROXY_NAME":/etc/squid/squid.conf
  docker start "$PROXY_NAME" > /dev/null
  docker network connect bridge "$PROXY_NAME"
  # Wait for squid to actually accept connections: the npm install below is the first thing through
  # the proxy and fails outright if it is not listening. /dev/tcp needs bash - the image's sh is dash.
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
  # Triage is untrusted-input processing by definition (the bug report is written by anyone who can
  # file a bug), so drop the default capability set and keep only what the chown/npm work needs.
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
    -e CLAUDE_MAX_BUDGET_USD \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    -e "HTTP_PROXY=http://$PROXY_NAME:3128" \
    -e "HTTPS_PROXY=http://$PROXY_NAME:3128" \
    -e "http_proxy=http://$PROXY_NAME:3128" \
    -e "https_proxy=http://$PROXY_NAME:3128" \
    -e NO_PROXY=localhost,127.0.0.1 \
    -w /workspace \
    node:24 sleep infinity > /dev/null

  docker exec "$SANDBOX_NAME" mkdir -p /workspace /output
  # Each selected repository lands as its own directory under /workspace, matching the names
  # TRIAGE.md lists in <repositories> so the model's `repository` field is directly usable.
  local REPO_PATH REPO_NAME
  for REPO_PATH in repos/*; do
    [ -d "$REPO_PATH" ] || continue
    REPO_NAME=$(basename "$REPO_PATH")
    docker cp "$REPO_PATH" "$SANDBOX_NAME":/workspace/
    echo "Copied $REPO_NAME into the sandbox"
  done
  docker cp claude-prompt.txt "$SANDBOX_NAME":/workspace/claude-prompt.txt
  # The sandbox cannot reach Bugzilla - egress is npm and Anthropic only - so the attachments have
  # to arrive the same way the repositories do. Already vetted: triage-tools.py expand-attachments unpacked any
  # zip among them on the runner, before this copy, so nothing here runs an extractor on untrusted
  # bytes itself.
  if [ -d attachments ] && [ -n "$(ls -A attachments 2>/dev/null)" ]; then
    docker cp attachments "$SANDBOX_NAME":/workspace/
    # find, not ls: an extracted archive's files sit in a subdirectory, and a top-level-only count
    # would silently stop mentioning them the moment triage-tools.py expand-attachments had anything to unpack.
    echo "Copied $(find attachments -type f | wc -l | tr -d ' ') attachment file(s) into the sandbox"
  fi
  # TRIAGE.md references /triage/triage-schema.json, and run_claude_triage reads the schema from there.
  docker cp triage/. "$SANDBOX_NAME":/triage/
  echo "Files inside container: $(docker exec "$SANDBOX_NAME" sh -c 'find /workspace -type f | wc -l')"

  docker exec "$SANDBOX_NAME" npm install -g --no-fund --no-audit --no-update-notifier --loglevel=error "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
  docker exec "$SANDBOX_NAME" sh -c 'echo "Running triage with model: $CLAUDE_MODEL, effort: $CLAUDE_EFFORT (claude-code $(claude --version || echo unknown))"'
  # --dangerously-skip-permissions refuses to run as root, and docker cp leaves files root-owned.
  docker exec "$SANDBOX_NAME" chown -R node:node /workspace /output
  echo '{"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' > /tmp/claude-trust-triage.json
  docker cp /tmp/claude-trust-triage.json "$SANDBOX_NAME":/home/node/.claude.json
  docker exec "$SANDBOX_NAME" chown node:node /home/node/.claude.json
}

# Runs claude -p unprivileged, pulls /output out, validates the envelope; returns non-zero (after an ::error::) on failure.
run_claude_triage() {
  local rc=0
  # --disallowedTools Task: a spawned subagent starts with a fresh context instead of reusing the
  # cheap cached one, which trades money for wall-clock (see review-run.sh for the measured case).
  #
  # timeout inside the container: without it a hung session just sits there until something outside
  # kills the job, and that kill takes the step's whole log with it (seen live - 12 minutes of
  # silence, then every remaining step failed in the same second, including one with if: always()).
  # An exit 124 here is a clean failure the reporting step can still describe.
  docker exec --user node -w /workspace -e TRIAGE_CLI_TIMEOUT "$SANDBOX_NAME" bash -c '
    set -euo pipefail
    timeout "${TRIAGE_CLI_TIMEOUT:-900}" \
    claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --max-budget-usd "$CLAUDE_MAX_BUDGET_USD" \
      --debug-file /output/claude-debug.log --output-format json --dangerously-skip-permissions --permission-prompts none \
      --disallowedTools "Task" \
      --json-schema "$(cat /triage/triage-schema.json)" \
      < claude-prompt.txt > /output/claude-output.json
  ' &
  local TRIAGE_PID=$!

  # Heartbeat into the step log while the analysis runs. The debug file lives inside the container
  # and is only copied out at the end, so without this a run that dies mid-flight leaves nothing at
  # all to look at - which is exactly what happened on the first long run.
  local STARTED=$SECONDS
  (
    while kill -0 "$TRIAGE_PID" 2>/dev/null; do
      sleep "${TRIAGE_HEARTBEAT_SECS:-60}"
      kill -0 "$TRIAGE_PID" 2>/dev/null || break
      local_tail=$(docker exec "$SANDBOX_NAME" sh -c 'tail -c 300 /output/claude-debug.log 2>/dev/null | tr "\n" " "' 2>/dev/null || true)
      echo "  [triage +$((SECONDS - STARTED))s] still running${local_tail:+ | ...${local_tail: -160}}"
    done
  ) &
  local HEARTBEAT_PID=$!
  # Backgrounded + waited on, not foreground: POSIX defers trap delivery until the current
  # foreground command exits, so a cancelled job would otherwise keep the container running.
  trap 'docker stop -t 5 "$SANDBOX_NAME" > /dev/null 2>&1 || true' TERM INT
  wait "$TRIAGE_PID" || rc=$?
  trap 'exit 143' TERM; trap 'exit 130' INT
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  echo "  [triage] finished after $((SECONDS - STARTED))s (exit $rc)"
  # Pull the debug log out before anything else can fail: on a bad run it is the only evidence.
  docker cp "$SANDBOX_NAME":/output/claude-debug.log ./claude-output/claude-debug.log 2>/dev/null || true
  if [ "$rc" -eq 124 ]; then
    echo "::error::Triage hit the ${TRIAGE_CLI_TIMEOUT:-900}s CLI timeout - raise TRIAGE_CLI_TIMEOUT or lower the effort"
    echo "Debug tail: $(tail -c 400 claude-output/claude-debug.log 2>/dev/null | tr '\n' ' ' || true)"
  fi
  if [ -z "$HOST_OUTPUT_DIR" ]; then
    docker cp "$SANDBOX_NAME":/output/claude-output.json ./claude-output/claude-output.json 2>/dev/null || true
    docker cp "$SANDBOX_NAME":/output/claude-debug.log ./claude-output/claude-debug.log 2>/dev/null || true
  fi
  [ -s claude-output/claude-output.json ] || echo '{}' > claude-output/claude-output.json

  if [ "$rc" -ne 0 ] || ! jq -e '.is_error == false and ((.result // "") | length > 0)' claude-output/claude-output.json > /dev/null 2>&1; then
    local subtype oom
    subtype=$(jq -r '.subtype // "unknown"' claude-output/claude-output.json 2>/dev/null || echo "unparsable")
    oom=$(docker inspect "$SANDBOX_NAME" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "unknown")
    echo "::error::Triage failed (exit $rc, subtype: $subtype, OOMKilled: $oom)"
    # Flattened: the runner reads workflow commands (::set-env::, ::add-path::, ...) at the start of
    # any log line, and the model's text is untrusted, so no line of it may begin at column 0.
    echo "Result excerpt: $(jq -r '.result // empty' claude-output/claude-output.json 2>/dev/null | head -c 300 | tr '\n\r' '  ' || true)"
    return 1
  fi
}

# Extracts+validates the model's JSON into claude-structured.json (best-effort - the report step has a fallback) and echoes one summary line.
summarize_claude_triage() {
  jq -r '.result' claude-output/claude-output.json \
    | EXTRACT_JSON_SCHEMA=triage/triage-schema.json python3 .gitea/scripts/common.py extract-json > claude-structured.json || {
    echo "::warning::Could not extract a valid triage JSON from the model's response - reporting fallback"
    echo "Result tail: $(jq -r '.result // empty' claude-output/claude-output.json 2>/dev/null | tail -c 500 | tr '\n\r' '  ' || true)"
  }
  local STATS LOCATIONS CONFIDENCE COST USAGE
  STATS=$(jq -r '"\(.num_turns // "?") turns / \((.duration_ms // 0) / 1000 | round)s"' claude-output/claude-output.json)
  LOCATIONS=$([ -s claude-structured.json ] && jq '.locations | length' claude-structured.json 2>/dev/null || echo '?')
  CONFIDENCE=$([ -s claude-structured.json ] && jq -r '.summary.confidence // "?"' claude-structured.json 2>/dev/null || echo '?')
  COST=$(jq -r '.total_cost_usd // 0 | (. * 1000 | round) / 1000' claude-output/claude-output.json)
  USAGE=$(jq -r '.modelUsage // {} | to_entries | map("\(.key): \(.value.inputTokens // 0)in/\(.value.outputTokens // 0)out") | join(", ")' claude-output/claude-output.json 2>/dev/null || echo "n/a")
  echo "Triage OK: $STATS, $LOCATIONS location(s), confidence $CONFIDENCE, \$$COST ($USAGE)"
}

# Runs the fix session in the sandbox that already holds the repositories, then pulls the result out
# as a patch. A second session rather than a continuation of the analysis: the analysis was asked to
# change nothing and its context is full of searching, while this one is asked to change exactly the
# thing the analysis found, starting from a clean checkout.
#
# Expects FIX_REPO, fix-prompt.txt and the sandbox variables (SANDBOX_NAME, HOST_OUTPUT_DIR) set.
# Optional: FIX_MAX_BUDGET_USD (default 1), FIX_CLI_TIMEOUT (default 600).
run_claude_fix() {
  local rc=0 CONTAINER_REPO="/workspace/$FIX_REPO"

  # Restore the untouched checkout: the analysis session had full tool access and may have left
  # scratch files behind, and the patch must contain the fix and nothing else.
  # Every step returns on failure: this function is called as `run_claude_fix || ...`, which turns
  # set -e off inside it, and a paid session must never start on a half-restored checkout.
  docker exec "$SANDBOX_NAME" rm -rf "$CONTAINER_REPO" || return 1
  docker cp "repos/$FIX_REPO" "$SANDBOX_NAME":/workspace/ || return 1
  docker exec "$SANDBOX_NAME" chown -R node:node "$CONTAINER_REPO" || return 1
  # A throwaway repository with one commit: the diff against it, not a file comparison, is what
  # leaves the sandbox. The clone had its .git removed, so there is no history to collide with.
  docker exec --user node -w "$CONTAINER_REPO" "$SANDBOX_NAME" bash -c \
    'git init -q && git add -A && git -c user.name=baseline -c user.email=baseline@localhost commit -q -m baseline' || return 1
  docker cp fix-prompt.txt "$SANDBOX_NAME":/workspace/fix-prompt.txt || return 1
  docker exec "$SANDBOX_NAME" chown node:node /workspace/fix-prompt.txt || return 1

  # Same containment as the analysis session, with the timeout inside the container for the same
  # reason: a hung session must end as a clean exit 124 the step can describe, not as a job kill
  # that takes the step log with it.
  docker exec --user node -w /workspace -e FIX_MAX_BUDGET_USD -e FIX_CLI_TIMEOUT "$SANDBOX_NAME" bash -c '
    set -euo pipefail
    timeout "${FIX_CLI_TIMEOUT:-600}" \
    claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --max-budget-usd "${FIX_MAX_BUDGET_USD:-1}" \
      --debug-file /output/fix-debug.log --output-format json --dangerously-skip-permissions --permission-prompts none \
      --disallowedTools "Task" \
      --json-schema "$(cat /triage/fix-schema.json)" \
      < fix-prompt.txt > /output/fix-output.json
  ' &
  local FIX_PID=$!
  trap 'docker stop -t 5 "$SANDBOX_NAME" > /dev/null 2>&1 || true' TERM INT
  wait "$FIX_PID" || rc=$?
  trap 'exit 143' TERM; trap 'exit 130' INT

  docker cp "$SANDBOX_NAME":/output/fix-debug.log ./claude-output/fix-debug.log 2>/dev/null || true
  docker cp "$SANDBOX_NAME":/output/fix-output.json ./claude-output/fix-output.json 2>/dev/null || true
  # A session that timed out or errored leaves a half-finished edit in the tree. That edit would
  # still be a valid-looking patch, and a plausible broken fix is the one outcome worse than none,
  # so it is discarded unread rather than collected and hoped about.
  if [ "$rc" -ne 0 ] || ! jq -e '.is_error == false and ((.result // "") | length > 0)' claude-output/fix-output.json > /dev/null 2>&1; then
    if [ "$rc" -eq 124 ]; then
      echo "::warning::The fix session hit the ${FIX_CLI_TIMEOUT:-600}s timeout - its edit is discarded"
    else
      echo "::warning::The fix session did not finish cleanly (exit $rc) - its edit is discarded"
    fi
    return 1
  fi

  docker exec --user node -w "$CONTAINER_REPO" "$SANDBOX_NAME" bash -c \
    'git add -A && git diff --cached --binary --no-color HEAD > /output/fix.patch' || true
  docker cp "$SANDBOX_NAME":/output/fix.patch ./claude-output/fix.patch 2>/dev/null || true

  jq -r '.result' claude-output/fix-output.json \
    | EXTRACT_JSON_SCHEMA=triage/fix-schema.json python3 .gitea/scripts/common.py extract-json > claude-fix-structured.json || {
    echo "::warning::Could not extract a valid fix description from the model's response - no pull request"
    rm -f claude-fix-structured.json
  }
  local STATS COST
  STATS=$(jq -r '"\(.num_turns // "?") turns / \((.duration_ms // 0) / 1000 | round)s"' claude-output/fix-output.json 2>/dev/null || echo "?")
  COST=$(jq -r '.total_cost_usd // 0 | (. * 1000 | round) / 1000' claude-output/fix-output.json 2>/dev/null || echo "?")
  echo "Fix session OK: $STATS, \$$COST, patch $(wc -c < claude-output/fix.patch 2>/dev/null | tr -d ' ' || echo 0) bytes"
}

# ============================================================================
# Bug -> draft pull request
# ============================================================================
# Runner-side helpers for the "bug -> pull request" stage of bugzilla-triage.yml. Used by two steps:
#   attempt_fix   (inside "Run triage", where the sandbox is still alive) - decides whether a fix is
#                 worth attempting, and if so runs the fix session and collects its patch;
#   open_fix_pr   (its own step, the only one holding a token that can push) - validates that patch
#                 and turns it into a draft pull request.
#
# The split is the point. The model that writes the change works in the sandbox with no token, no
# Bugzilla key and no route to Gitea; everything it produces crosses to this side as a patch, and the
# patch is judged by triage-tools.py check-patch before anything is pushed. Nothing here trusts the sandbox.
#
# Expects from the job env: BUG_ID, GITEA_HOST. Optional: TRIAGE_ORG (default ONLYOFFICE),
# TRIAGE_FIX_PR (must be "true" for anything to happen), TRIAGE_FIX_MAX_OPEN (default 5).

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

  # High and medium both go ahead: a person reads the draft either way, and the analysis, with its stated
  # confidence, is in the pull request description.
  if [ "$CONFIDENCE" != "high" ] && [ "$CONFIDENCE" != "medium" ]; then
    FIX_WHY="confidence is '${CONFIDENCE:-unstated}', not high or medium"
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
    echo "$FIX_WHY" > fix-skip-reason.txt
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

# Text written by a model that read the bug is shown as code, never as markup: a mention, a link or an
# image in it would otherwise be live in the pull request. The fence is longer than any run of backticks
# in the text, so the text cannot close it.
_fenced_block() {
  local TEXT="$1" FENCE='```'
  while grep -qF -- "$FENCE" <<< "$TEXT"; do FENCE+='`'; done
  printf '%s\n%s\n%s' "$FENCE" "$TEXT" "$FENCE"
}

# The analysis as the reader of the pull request should see it: the same message the run logs, in a fence
# so that nothing in it is read as markup, without its closing disclaimer (it says nothing was changed, which
# is the one thing a pull request contradicts). Prints nothing and fails when there is no analysis to show.
_pr_analysis_block() {
  [ -s claude-structured.json ] || return 1
  local RENDER_ARGS=(--structured claude-structured.json --bug-id "$BUG_ID" --product "${PRODUCT:-}" --component "${COMPONENT:-}" --output pr-analysis.txt)
  if [ -s repos-cloned.txt ]; then RENDER_ARGS+=(--repos-file repos-cloned.txt); fi
  if [ -n "${GITEA_HOST:-}" ]; then RENDER_ARGS+=(--gitea-host "$GITEA_HOST" --org "$TRIAGE_ORG"); fi
  if [ -s related-bugs.txt ]; then RENDER_ARGS+=(--related-file related-bugs.txt); fi
  python3 .gitea/scripts/triage-tools.py render "${RENDER_ARGS[@]}" > /dev/null 2>&1 || return 1
  [ -s pr-analysis.txt ] || return 1

  local TEXT
  TEXT=$(sed '/^--$/,$d' pr-analysis.txt | _trim_chars 12000)
  [ -n "$TEXT" ] || return 1
  printf '### Analysis (generated, not reviewed)\n\n%s\n' "$(_fenced_block "$TEXT")"
}

# Turns the collected patch into a draft pull request. Its own step, and the only one that holds a
# token able to push. Every early return is a quiet one: no patch is the normal outcome.
open_fix_pr() {
  scrub_claude_output
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
  CHECK_OUT=$(python3 .gitea/scripts/triage-tools.py check-patch claude-output/fix.patch "fix-work/$REPO" 2> fix-check.err) || CHECK_RC=$?
  if [ "$CHECK_RC" = "3" ]; then
    echo "The fix session changed nothing - no pull request"
    return 0
  fi
  if [ "$CHECK_RC" != "0" ]; then
    echo "::warning::Fix patch not accepted: $(head -c 300 fix-check.err | tr '\n\r' '  ')"
    _fix_notice "fix patch for $REPO not accepted - $(head -1 fix-check.err | tr -d '\r' | sed 's/^refused: //')"
    return 0
  fi
  echo "Fix patch accepted: $CHECK_OUT"

  local BRANCH="${FIX_BRANCH_PREFIX}${BUG_ID}" BRANCH_ENC
  BRANCH_ENC=${BRANCH//\//%2F}
  # Only a clear 404 lets the branch be created: any other answer, including none, means the state
  # is unknown, and pushing on an unknown state is how a second proposal for one bug appears.
  local EXISTS
  EXISTS=$(_fix_api GET "/repos/$TRIAGE_ORG/$REPO/branches/$BRANCH_ENC" -o /dev/null -w '%{http_code}' || true)
  if [ "$EXISTS" = "200" ]; then
    echo "Branch $BRANCH already exists in $REPO - not opening a second pull request"
    return 0
  fi
  if [ "$EXISTS" != "404" ]; then
    echo "::warning::Could not tell whether $BRANCH exists in $REPO (HTTP ${EXISTS:-none}) - not opening a pull request"
    _fix_notice "no fix pull request opened for $REPO: the branch check failed (HTTP ${EXISTS:-none})"
    return 0
  fi
  # A cap on open proposals per repository: if nobody is reading them, more of them is not help.
  # Paged until an empty page, as the repository listing is: this Gitea's page sizes vary, so a short
  # page proves nothing. An unreadable page is an unknown count, which refuses rather than passes.
  local OPEN_COUNT=0 PAGE=1 PAGE_JSON PAGE_COUNT
  while [ "$PAGE" -le 10 ]; do
    PAGE_JSON=$(_fix_api GET "/repos/$TRIAGE_ORG/$REPO/pulls?state=open&limit=50&page=$PAGE" || true)
    if ! jq -e 'type == "array"' <<< "$PAGE_JSON" > /dev/null 2>&1; then
      echo "::warning::Could not read the open pull requests of $REPO - not opening another"
      _fix_notice "no fix pull request opened for $REPO: its open pull requests could not be counted"
      return 0
    fi
    [ "$(jq 'length' <<< "$PAGE_JSON")" = "0" ] && break
    PAGE_COUNT=$(jq -r --arg p "$FIX_BRANCH_PREFIX" '[.[] | select((.head.ref // "") | startswith($p))] | length' <<< "$PAGE_JSON")
    OPEN_COUNT=$((OPEN_COUNT + PAGE_COUNT))
    PAGE=$((PAGE + 1))
  done
  if [ "$PAGE" -gt 10 ]; then
    echo "::warning::$REPO has more than ten pages of open pull requests - not opening another"
    _fix_notice "no fix pull request opened for $REPO: too many open pull requests to count"
    return 0
  fi
  if [ "$OPEN_COUNT" -ge "${TRIAGE_FIX_MAX_OPEN:-5}" ]; then
    echo "$REPO already has $OPEN_COUNT open proposals from this pipeline - not adding another"
    _fix_notice "no fix pull request opened for $REPO: $OPEN_COUNT proposals from this pipeline are still open"
    return 0
  fi

  local TITLE SUMMARY UNVERIFIED SUBJECT FIX_CONFIDENCE
  # The schema's enum and maxLength are requests to the model, not guarantees: extract-json checks
  # required keys, not these. So the value is checked here, and the lengths are enforced here, by
  # characters (a byte cut severs a Cyrillic letter and leaves an invalid byte in the commit subject).
  FIX_CONFIDENCE=$(jq -r '.confidence // ""' claude-fix-structured.json | tr -d '\r')
  if [ "$FIX_CONFIDENCE" != "high" ] && [ "$FIX_CONFIDENCE" != "medium" ]; then
    echo "The fix session rated its own edit '${FIX_CONFIDENCE:-unstated}' - no pull request"
    _fix_notice "fix for $REPO not proposed: the fix session rated its own edit '${FIX_CONFIDENCE:-unstated}'"
    return 0
  fi
  TITLE=$(jq -r '.title // ""' claude-fix-structured.json | tr -d '\r' | tr '\n' ' ' | _trim_chars 90 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  SUMMARY=$(jq -r '.summary // ""' claude-fix-structured.json | tr -d '\r' | _trim_chars 600)
  UNVERIFIED=$(jq -r '.not_verified // ""' claude-fix-structured.json | tr -d '\r' | _trim_chars 300)
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
    echo "::warning::git apply failed after the check passed: $(head -c 200 fix-apply.err | tr '\n\r' '  ')"
    return 0
  fi
  git -C "fix-work/$REPO" checkout -q -b "$BRANCH"
  git -C "fix-work/$REPO" "${GIT_ID[@]}" commit -q -m "$SUBJECT"
  if ! git -C "fix-work/$REPO" push -q origin "$BRANCH" 2>fix-push.err; then
    echo "::warning::Could not push $BRANCH: $(head -c 200 fix-push.err | tr '\n\r' '  ')"
    _fix_notice "fix branch for $REPO could not be pushed"
    return 0
  fi

  local RUN_URL="" BODY PAYLOAD RESPONSE PR_URL ANALYSIS_BLOCK ANALYSIS_CONFIDENCE
  ANALYSIS_BLOCK=$(_pr_analysis_block || true)
  ANALYSIS_CONFIDENCE=$(jq -r '.summary.confidence // "unstated"' claude-structured.json 2>/dev/null | tr -d '\r' || true)
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    RUN_URL="https://$GITEA_HOST/${GITHUB_REPOSITORY:-$TRIAGE_ORG/ga-common}/actions/runs/$GITHUB_RUN_ID"
  fi
  BODY="**Automated proposal for Bug $BUG_ID.** Written by the Claude Bug Triage pipeline and **not reviewed by a person**; treat it as a suggestion to check, not a change to trust."
  BODY+=$'\n\n'"**What it does** (the fix session's own confidence: $FIX_CONFIDENCE):"$'\n'"$(_fenced_block "$SUMMARY")"
  BODY+=$'\n\n'"**Analysis confidence:** ${ANALYSIS_CONFIDENCE:-unstated}"
  if [ -n "$UNVERIFIED" ]; then
    BODY+=$'\n\n'"**Not verified:**"$'\n'"$(_fenced_block "$UNVERIFIED")"
  fi
  BODY+=$'\n\n'"**Analysed at:** \`$REPO@$REF\` - this branch is based on it; port it to another line if the fix belongs there."
  if [ -n "$RUN_URL" ]; then
    BODY+=$'\n\n'"**Run:** $RUN_URL"
  fi
  if [ -n "$ANALYSIS_BLOCK" ]; then
    BODY="$BODY"$'\n\n'"$ANALYSIS_BLOCK"
  fi
  # The WIP: prefix is what makes Gitea treat this as a draft, which it will not let anyone merge
  # until the prefix is removed - a deliberate second step by a person.
  PAYLOAD=$(jq -n --arg title "WIP: $SUBJECT" --arg head "$BRANCH" --arg base "$REF" --arg body "$BODY" \
    '{title: $title, head: $head, base: $base, body: $body}')
  RESPONSE=$(_fix_api POST "/repos/$TRIAGE_ORG/$REPO/pulls" -d "$PAYLOAD" || true)
  PR_URL=$(jq -r '.html_url // empty' <<< "$RESPONSE" 2>/dev/null | tr -d '\r' || true)
  if [ -z "$PR_URL" ]; then
    echo "::warning::The branch was pushed but the pull request was not created: $(head -c 200 <<< "$RESPONSE" | tr '\n\r' '  ')"
    _fix_notice "fix branch $BRANCH pushed to $REPO but the pull request was not created"
    return 0
  fi
  echo "$PR_URL" > fix-pr-url.txt
  echo "Opened draft pull request: $PR_URL"
  _fix_notice "opened a draft pull request with a proposed fix: $PR_URL"
  return 0
}


# =====================================================================
# Entry points
# =====================================================================

# The whole "Run triage" step. The sandbox is still alive when the fix is attempted, which is the only
# reason the fix is not a step of its own.
triage_sandbox_step() {
  # DooD: the CLI runs in a throwaway nested container with only ANTHROPIC_API_KEY, egress
  # restricted to npm + Anthropic - no GITEA_TOKEN, no BUGZILLA_API_KEY, no docker.sock.
  name_triage_resources
  # EXIT does the cleanup; TERM and INT must end the script (a bare handler would run and carry on,
  # and a cancelled job could go on to start the paid session).
  trap cleanup_triage_sandbox EXIT
  trap 'exit 143' TERM; trap 'exit 130' INT
  cleanup_triage_sandbox

  resolve_triage_output_dir
  setup_triage_sandbox
  run_claude_triage
  summarize_claude_triage

  # Only when the analysis is confident, the bug is open and the repository is allowlisted; never fatal.
  attempt_fix
}

triage_main() {
  case "${1:-}" in
    prepare) prepare_triage_context ;;
    sandbox) triage_sandbox_step ;;
    open-pr) open_fix_pr ;;
    report)  report_triage_result ;;
    publish) publish_triage_comment ;;
    notify)  notify_result ;;
    *)
      echo "usage: triage-run.sh {prepare|sandbox|open-pr|report|publish|notify}" >&2
      return 2
      ;;
  esac
}

# Sourcing (tests) only defines the functions; running the file dispatches.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  triage_main "$@"
fi
