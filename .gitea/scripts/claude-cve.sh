#!/usr/bin/env bash
# Claude CVE Patch pipeline.
#
# Rediscovers the nightly (cron-built) DocSpace images per active branch, re-runs
# Trivy, routes each High/Critical finding to the repo/file that owns the fix,
# asks Claude to make the minimal version bump, and opens a draft (WIP) PR per
# (repo, branch) group with the mapped reviewer.
#
# Required env (from the workflow job):
#   GITEA_HOST, GITEA_TOKEN            - Gitea host + PAT (clone/push/PR/comment)
#   ANTHROPIC_API_KEY                  - dedicated key for this action
#   DOCKERHUB_USERNAME, DOCKERHUB_TOKEN- pull + tags API for 4testing images
# Optional env (with defaults below):
#   ORG_NAME, BUILDTOOLS_REPO, DOCKER_NAMESPACE, DOCKER_PREFIX, SERVICES,
#   CLAUDE_MODEL, CLAUDE_MODEL_FALLBACK, CLAUDE_EFFORT, CLAUDE_CODE_VERSION,
#   DRY_RUN, BRANCHES_OVERRIDE, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, FIX_LABEL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/gitea-api.sh"

# --- config / defaults ------------------------------------------------------
ORG_NAME="${ORG_NAME:-ONLYOFFICE}"
BUILDTOOLS_REPO="${BUILDTOOLS_REPO:-DocSpace-buildtools}"
DOCKER_NAMESPACE="${DOCKER_NAMESPACE:-onlyoffice}"
DOCKER_PREFIX="${DOCKER_PREFIX:-4testing-docspace}"
SERVICES="${SERVICES:-dotnet node java}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-high}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"
DRY_RUN="${DRY_RUN:-true}"
FIX_LABEL="${FIX_LABEL:-security}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-claude-cve-patch}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-noreply@onlyoffice.com}"
ROUTES_FILE="$SCRIPT_DIR/../config/claude-cve-routes.json"
PROMPT_TEMPLATE="$SCRIPT_DIR/../../review/CVE-FIX.md"
RUN_DATE="${RUN_DATE:-$(date +%Y%m%d)}"
WORK_ROOT="$(mktemp -d)"

# --- small helpers ----------------------------------------------------------

# Sanitize an untrusted string for safe inclusion in the prompt / PR body:
# drop CR/newlines/backticks/$, HTML-escape &<>, cap length. Mirrors review-steps.sh.
_san() { local max="${2:-300}"; printf '%s' "$1" | tr '\n\r`$' '    ' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | cut -c"1-${max}"; }

# Version string that the build derives from a branch name (mirrors main-build.yml prepare).
branch_to_version() {
  printf '%s' "$1" | sed -E 's#^(release|hotfix|feature|bugfix).*/##; s/-git-action$//; s/^v//'
}

# --- Docker Hub -------------------------------------------------------------
_HUB_JWT=""
hub_jwt() {
  [ -n "$_HUB_JWT" ] && { printf '%s' "$_HUB_JWT"; return 0; }
  _HUB_JWT=$(curl -s -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$DOCKERHUB_USERNAME" --arg p "$DOCKERHUB_TOKEN" '{username:$u,password:$p}')" \
    "https://hub.docker.com/v2/users/login/" | jq -r '.token // empty')
  [ -n "$_HUB_JWT" ] || { echo "::error::Docker Hub login failed" >&2; return 1; }
  printf '%s' "$_HUB_JWT"
}

# Newest tag {version}.{run_number} for a service image, or empty if none.
latest_tag() {
  local service="$1" version="$2"
  local repo="${DOCKER_NAMESPACE}/${DOCKER_PREFIX}-${service}"
  local jwt; jwt=$(hub_jwt) || return 1
  # Match tags "<version>.<run_number>" without regex dot-escaping: require the
  # "<version>." prefix and an all-digit run-number suffix, then pick the max.
  curl -s -H "Authorization: JWT $jwt" \
    "https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=100&name=${version}." \
    | jq -r --arg v "$version" '
        [ .results[]?.name
          | select(startswith($v + "."))
          | select(.[($v|length)+1:] | test("^[0-9]+$")) ]
        | max_by(.[($v|length)+1:] | tonumber) // empty'
}

# --- trivy ------------------------------------------------------------------
# Emit an array of normalized High/Critical findings for a full image reference,
# tagged with a service label. We do NOT pass --ignore-unfixed: OS-package
# (base-image) findings often have no per-package FixedVersion but are still
# remediable by bumping the base-image tag, so the fix-availability filter is
# applied per fix_strategy during routing (main), not at scan time. The package
# ecosystem comes from each Result's .Type (debian/ubuntu/alpine/npm/nuget/
# dotnet-core/jar/...), which routing maps to the owning repo/file/strategy.
# Normalize a Trivy JSON report (on stdin) into our finding objects.
# Args: $1 service label, $2 image/source label.
_trivy_normalize() {
  jq -c --arg svc "$1" --arg img "$2" '
    [ .Results[]?
      | .Type as $type
      | (.Vulnerabilities // [])[]
      | { cve: .VulnerabilityID,
          package: .PkgName,
          type: $type,
          installed: .InstalledVersion,
          fixed_in: (.FixedVersion // ""),
          severity: (.Severity // "" | ascii_downcase | (.[0:1] | ascii_upcase) + .[1:]),
          url: (.PrimaryURL // ""),
          description: (.Description // .Title // ""),
          service: $svc, image: $img } ]'
}

# Scan a container image reference.
scan_ref() {
  local image="$1" service="$2"
  echo "Scanning image $image ..." >&2
  local report
  report=$(trivy image --quiet --format json --severity HIGH,CRITICAL --scanners vuln "$image" 2>/dev/null) \
    || { echo "::warning::trivy image failed for $image" >&2; echo '[]'; return 0; }
  _trivy_normalize "$service" "$image" <<< "$report"
}

# Scan a local checkout's dependency manifests/lockfiles with `trivy fs`.
scan_fs() {
  local dir="$1" label="$2"
  echo "Scanning (fs) $dir ..." >&2
  local report
  report=$(trivy fs --quiet --format json --severity HIGH,CRITICAL --scanners vuln "$dir" 2>/dev/null) \
    || { echo "::warning::trivy fs failed for $dir" >&2; echo '[]'; return 0; }
  _trivy_normalize "$label" "$label" <<< "$report"
}

# Build the 4testing image ref for a service+tag and scan it.
scan_image() { scan_ref "${DOCKER_NAMESPACE}/${DOCKER_PREFIX}-${1}:${2}" "$1"; }

# --- routing ----------------------------------------------------------------
route_repo() { jq -r --arg t "$1" '.types[$t].repo // empty' "$ROUTES_FILE"; }
reviewer_for() { jq -r --arg r "$1" '.reviewers[$r] // empty' "$ROUTES_FILE"; }

# Build the per-repo routing-guidance markdown for the types present in a group.
render_routing_guidance() {
  local group_json="$1" types
  types=$(jq -r '[.[].type] | unique | .[]' <<< "$group_json")
  local t files hint lock strategy
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    files=$(jq -r --arg t "$t" '.types[$t].files | join(", ")' "$ROUTES_FILE")
    hint=$(jq -r --arg t "$t" '.types[$t].hint' "$ROUTES_FILE")
    strategy=$(jq -r --arg t "$t" '.types[$t].fix_strategy // "version-bump"' "$ROUTES_FILE")
    lock=$(jq -r --arg t "$t" 'if .types[$t].regenerate_lock then "has a lockfile (pnpm-lock.yaml) that will be stale after your edit - do NOT run pnpm/install/build; note in warnings that the lockfile must be regenerated before merge" else "no lockfile" end' "$ROUTES_FILE")
    printf -- '- **%s** (strategy: %s) — edit: `%s` · lockfile: %s\n  - %s\n' "$t" "$strategy" "$files" "$lock" "$hint"
  done <<< "$types"
}

# Build the sanitized, XML-wrapped findings block for the prompt.
render_findings_xml() {
  local group_json="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local cve pkg typ inst fix sev url desc
    cve=$(_san "$(jq -r '.cve' <<< "$f")" 40)
    pkg=$(_san "$(jq -r '.package' <<< "$f")" 120)
    typ=$(_san "$(jq -r '.type' <<< "$f")" 40)
    inst=$(_san "$(jq -r '.installed' <<< "$f")" 60)
    fix=$(_san "$(jq -r '.fixed_in' <<< "$f")" 60)
    sev=$(_san "$(jq -r '.severity' <<< "$f")" 20)
    url=$(_san "$(jq -r '.url' <<< "$f")" 200)
    desc=$(_san "$(jq -r '.description' <<< "$f")" 500)
    printf '  <finding cve="%s" severity="%s">\n' "$cve" "$sev"
    printf '    <package type="%s">%s</package>\n' "$typ" "$pkg"
    printf '    <installed>%s</installed><fixed_in>%s</fixed_in>\n' "$inst" "$fix"
    printf '    <advisory>%s</advisory>\n' "$url"
    printf '    <description>%s</description>\n' "$desc"
    printf '  </finding>\n'
  done < <(jq -c '.[]' <<< "$group_json")
}

# --- Claude -----------------------------------------------------------------
# Run the fix agent inside $1 (a clone). Reads prompt from $2, writes result md to $3.
run_claude_fix() {
  local workdir="$1" prompt_file="$2" out_md="$3"
  npm install -g --no-fund --no-audit --loglevel=error "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" >/dev/null 2>&1 || true
  export PATH="$(npm config get prefix)/bin:$PATH"
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  local attempt rc
  for attempt in 1 2; do
    rc=0
    # --bare: do not auto-load the cloned repo's hooks/skills/MCP/CLAUDE.md, so a
    # target repo's .claude/ config cannot execute code on the runner (this agent
    # has write tools, unlike the read-only review pipeline).
    ( cd "$workdir" && timeout -k 30 900 claude -p --bare \
        --allowedTools "Read,Glob,Grep,Edit,Bash" --model "$CLAUDE_MODEL" \
        --effort "$CLAUDE_EFFORT" --max-turns 120 \
        --output-format json < "$prompt_file" > "$workdir/.claude-out.json" ) || rc=$?
    if [ "$rc" -eq 0 ] && jq -e '.is_error == false and ((.result // "") | length > 0)' "$workdir/.claude-out.json" >/dev/null 2>&1; then
      jq -r '.result' "$workdir/.claude-out.json" > "$out_md"
      return 0
    fi
    echo "::warning::Claude fix attempt $attempt failed (rc=$rc, model=$CLAUDE_MODEL)" >&2
    sleep 20
  done
  return 1
}

# Extract the JSON inside the <fix_result>...</fix_result> block of a result md.
extract_fix_result() {
  awk '/<fix_result>/{f=1;next} /<\/fix_result>/{f=0} f' "$1"
}

# --- PR body ----------------------------------------------------------------
build_pr_body() {
  local repo="$1" base="$2" findings_json="$3" fixes_json="$4" unfixable_json="$5" out="$6"
  local n_fix n_unfix
  n_fix=$(jq 'length' <<< "$fixes_json"); n_unfix=$(jq 'length' <<< "$unfixable_json")
  {
    printf '## 🛡️ Automated CVE fix — `%s` (`%s`)\n\n' "$repo" "$base"
    printf 'Opened by the **Claude CVE Patch** action from a Trivy scan of the nightly image. '
    printf '**Draft (WIP):** verify the bump(s), then remove the `WIP:` prefix to trigger Claude review + CI before merge.\n\n'
    printf '**%s CVE(s) fixed', "$n_fix"
    [ "$n_unfix" -gt 0 ] && printf ', %s needing manual attention' "$n_unfix"
    printf '.**\n\n'

    local f cve
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      cve=$(jq -r '.cve' <<< "$f")
      local meta; meta=$(jq -c --arg c "$cve" '.[] | select(.cve==$c)' <<< "$findings_json" | head -1)
      [ -n "$meta" ] || meta='{}'   # fix entry for a CVE not in the scan set — degrade gracefully
      printf '### %s\n\n' "$cve"
      printf '<!-- claude-cve:%s -->\n' "$cve"
      printf -- '- **Severity:** %s · **Package:** `%s` (%s)\n' \
        "$(jq -r '.severity // "?"' <<< "$meta")" "$(jq -r '.package' <<< "$f")" "$(jq -r '.type' <<< "$f")"
      printf -- '- **Version:** `%s` → `%s`\n' "$(jq -r '.from' <<< "$f")" "$(jq -r '.to' <<< "$f")"
      printf -- '- **Found in:** `%s`\n' "$(jq -r '.image // "?"' <<< "$meta")"
      local url; url=$(jq -r '.url // ""' <<< "$meta")
      [ -n "$url" ] && printf -- '- **Advisory:** %s\n' "$url"
      local desc; desc=$(jq -r '.description // ""' <<< "$meta")
      [ -n "$desc" ] && printf -- '- **What it is:** %s\n' "$desc"
      printf -- '- **Fix:** %s\n' "$(jq -r '.how // "version bump"' <<< "$f")"
      printf -- '- **Files:** %s\n' "$(jq -r '(.files // []) | map("`"+.+"`") | join(", ")' <<< "$f")"
      local warn; warn=$(jq -r '.warnings // ""' <<< "$f")
      [ -n "$warn" ] && printf -- '- ⚠️ **Warning:** %s\n' "$warn"
      printf '\n'
    done < <(jq -c '.[]' <<< "$fixes_json")

    if [ "$n_unfix" -gt 0 ]; then
      printf -- '---\n\n### ⚠️ Needs manual attention\n\n'
      local u
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        printf -- '- **%s** (`%s`): %s\n' \
          "$(jq -r '.cve' <<< "$u")" "$(jq -r '.package // "?"' <<< "$u")" "$(jq -r '.reason // ""' <<< "$u")"
      done < <(jq -c '.[]' <<< "$unfixable_json")
      printf '\n'
    fi
    printf -- '<!-- claude-cve -->\n'
  } > "$out"
}

# --- per-group processing ---------------------------------------------------
process_group() {
  local repo="$1" branch="$2" group_json="$3" guidance_override="${4:-}"
  local repo_path="$ORG_NAME/$repo"
  local branch_slug; branch_slug=$(printf '%s' "$branch" | tr '/' '-')
  local fix_branch="bugfix/claude-cve-${branch_slug}-${RUN_DATE}"
  echo "── Group: $repo @ $branch ($(jq 'length' <<< "$group_json") findings) → $fix_branch"

  # 1. CVE-level dedup against existing PRs (open + closed).
  local pulls; pulls=$(fetch_all_pulls "$repo_path" all) || pulls='[]'
  local kept="[]" f cve
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cve=$(jq -r '.cve' <<< "$f")
    if jq -e --arg m "<!-- claude-cve:$cve -->" 'any(.[]; (.body // "") | contains($m))' <<< "$pulls" >/dev/null; then
      echo "  skip $cve — already covered by an existing PR"
    else
      kept=$(jq -c --argjson x "$f" '. + [$x]' <<< "$kept")
    fi
  done < <(jq -c '.[]' <<< "$group_json")
  [ "$(jq 'length' <<< "$kept")" -gt 0 ] || { echo "  nothing new for $repo @ $branch — skipping"; return 0; }

  # 2. Branch/PR-level idempotency.
  local clone_url="https://$GITEA_HOST/$repo_path"
  if git ls-remote --heads "$clone_url" "$fix_branch" 2>/dev/null | grep -q .; then
    echo "  branch $fix_branch already exists on $repo — skipping"; return 0
  fi

  # 3. Clone the target at the affected branch.
  local workdir="$WORK_ROOT/$repo-$branch_slug"
  git clone --depth 1 --branch "$branch" "$clone_url" "$workdir" 2>/dev/null \
    || { echo "::warning::clone failed for $repo_path@$branch"; return 0; }

  # 4. Render prompt.
  local FINDINGS_XML ROUTING_GUIDANCE
  FINDINGS_XML=$(render_findings_xml "$kept")
  ROUTING_GUIDANCE="${guidance_override:-$(render_routing_guidance "$kept")}"
  export TARGET_REPO="$repo" TARGET_BRANCH="$branch" FINDINGS_XML ROUTING_GUIDANCE
  envsubst '$TARGET_REPO $TARGET_BRANCH $FINDINGS_XML $ROUTING_GUIDANCE' \
    < "$PROMPT_TEMPLATE" > "$workdir/.cve-fix-prompt.txt"

  # 5. Run the fix agent.
  if ! run_claude_fix "$workdir" "$workdir/.cve-fix-prompt.txt" "$workdir/.fix-result.md"; then
    echo "::warning::Claude did not produce a fix for $repo @ $branch"; return 0
  fi
  local result_json fixes unfixable
  result_json=$(extract_fix_result "$workdir/.fix-result.md")
  jq -e . <<< "$result_json" >/dev/null 2>&1 || { echo "::warning::unparsable fix_result for $repo @ $branch"; return 0; }
  fixes=$(jq -c '.fixes // []' <<< "$result_json")
  unfixable=$(jq -c '.unfixable // []' <<< "$result_json")

  # 6. Bail if no actual change landed.
  if ! git -C "$workdir" diff --quiet 2>/dev/null; then :; else
    echo "  no file changes produced for $repo @ $branch — skipping (unfixable: $(jq 'length' <<< "$unfixable"))"; return 0
  fi

  # 7. Build PR body + commit.
  local body_file="$workdir/.pr-body.md"
  build_pr_body "$repo" "$branch" "$kept" "$fixes" "$unfixable" "$body_file"
  local title="WIP: fix High/Critical CVEs reported by Trivy (auto)"

  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would open PR '$title' on $repo_path (base $branch, head $fix_branch)"
    echo "  ---- diff ----"; git -C "$workdir" --no-pager diff --stat
    echo "  ---- PR body ----"; sed 's/^/  | /' "$body_file"
    return 0
  fi

  git -C "$workdir" config user.name "$GIT_AUTHOR_NAME"
  git -C "$workdir" config user.email "$GIT_AUTHOR_EMAIL"
  git -C "$workdir" checkout -b "$fix_branch"
  git -C "$workdir" add -A
  git -C "$workdir" commit -m "fix High/Critical CVEs reported by Trivy (auto)" >/dev/null
  git -C "$workdir" push origin "$fix_branch" >/dev/null

  # 8. Open the draft PR, request reviewer, add label.
  local pr_number reviewer
  pr_number=$(create_pull_request "$repo_path" "$branch" "$fix_branch" "$title" "$body_file")
  [ -n "$pr_number" ] || { echo "::warning::PR creation returned no number for $repo_path"; return 0; }
  echo "  opened $repo_path#$pr_number ($fix_branch → $branch)"
  reviewer=$(reviewer_for "$repo")
  [ -n "$reviewer" ] && request_reviewers "$repo_path" "$pr_number" "$reviewer"
  add_labels "$repo_path" "$pr_number" "$FIX_LABEL"
}

# --- repo (manifest) scan ---------------------------------------------------
# Some fixes belong to a repo whose vulnerable deps cannot be attributed from an
# image scan (e.g. the standalone docspace-ui-kit-react library, bundled into the
# images via DocSpace-client/libs/ui-kit). For each entry in the config's
# `repo_scans`, clone the repo, `trivy fs`-scan its manifests, and open a fix PR
# on that repo directly. Independent of the DocSpace branch loop.
process_repo_scan() {
  local entry="$1"
  local repo branch files regen hint scandir findings guidance
  repo=$(jq -r '.repo' <<< "$entry")
  branch=$(jq -r '.branch // "develop"' <<< "$entry")
  files=$(jq -r '(.files // []) | join(", ")' <<< "$entry")
  regen=$(jq -r 'if .regenerate_lock then "has a lockfile (pnpm-lock.yaml) that will be stale after your edit - do NOT run pnpm/install/build; note in warnings that it must be regenerated before merge" else "no lockfile" end' <<< "$entry")
  hint=$(jq -r '.hint // ""' <<< "$entry")
  echo "═══ Repo scan: $repo @ $branch ═══"

  scandir="$WORK_ROOT/scan-$repo"
  git clone --depth 1 --branch "$branch" "https://$GITEA_HOST/$ORG_NAME/$repo" "$scandir" 2>/dev/null \
    || { echo "::warning::clone failed for $ORG_NAME/$repo@$branch — skipping repo scan"; return 0; }

  findings=$(scan_fs "$scandir" "$repo")
  # version-bump strategy: keep only findings with a known upstream fix, dedup.
  findings=$(jq -c 'map(select((.fixed_in // "") != "")) | unique_by([.cve, .package])' <<< "$findings")
  local total; total=$(jq 'length' <<< "$findings")
  echo "  $total fixable finding(s) in $repo"
  [ "$total" -gt 0 ] || return 0

  guidance=$(printf -- '- **%s** (strategy: version-bump) — edit: `%s` · regenerate lock: %s\n  - %s' "$repo" "$files" "$regen" "$hint")
  process_group "$repo" "$branch" "$findings" "$guidance"
}

# --- main -------------------------------------------------------------------
main() {
  # DOCKERHUB_* only needed to pull the private 4testing images; in TEST_IMAGE
  # mode we scan a public image, so they are not required.
  local required="GITEA_HOST GITEA_TOKEN ANTHROPIC_API_KEY"
  [ -z "${TEST_IMAGE:-}" ] && required="$required DOCKERHUB_USERNAME DOCKERHUB_TOKEN"
  for v in $required; do
    [ -n "${!v:-}" ] || { echo "::error::$v is required"; exit 1; }
  done
  # Credential helper so clone/push use the PAT without embedding it in URLs.
  git config --global credential.helper '!f(){ echo "username=oauth2"; echo "password=$GITEA_TOKEN"; }; f'
  git config --global "url.https://$GITEA_HOST/.insteadOf" "https://$GITEA_HOST/"
  export ANTHROPIC_API_KEY

  # Discover active branches (override or live query against buildtools).
  local branches
  if [ -n "${BRANCHES_OVERRIDE:-}" ]; then
    branches=$(printf '%s' "$BRANCHES_OVERRIDE" | jq -r 'if type=="array" then .[] else . end' 2>/dev/null || printf '%s' "$BRANCHES_OVERRIDE" | tr ' ,' '\n\n')
  elif [ -n "${TEST_IMAGE:-}" ]; then
    branches="develop"   # test mode: base branch for cloning target repos / PR base
  else
    branches=$(git ls-remote --heads "https://$GITEA_HOST/$ORG_NAME/$BUILDTOOLS_REPO" \
      | grep -Po 'refs/heads/\K((release|hotfix)/v[0-9][^ ]*|develop)' || true)
  fi
  [ -n "$branches" ] || { echo "::error::no active branches discovered"; exit 1; }
  echo "Active branches:"; printf '  - %s\n' $branches

  local branch version tag all_findings routed unrouted repos repo group
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    version=$(branch_to_version "$branch")
    echo "═══ Branch $branch (version $version) ═══"

    # Collect findings. TEST_IMAGE mode scans one explicit image (no discovery /
    # Docker login); normal mode discovers the newest 4testing tag per service.
    all_findings="[]"
    if [ -n "${TEST_IMAGE:-}" ]; then
      echo "  TEST MODE: scanning $TEST_IMAGE (skipping tag discovery / Docker login)"
      all_findings=$(scan_ref "$TEST_IMAGE" "test")
    else
      for service in $SERVICES; do
        tag=$(latest_tag "$service" "$version") || tag=""
        [ -n "$tag" ] || { echo "::warning::no image tag found for $service / $version"; continue; }
        local svc_findings; svc_findings=$(scan_image "$service" "$tag")
        all_findings=$(jq -n --argjson a "$all_findings" --argjson b "$svc_findings" '$a + $b')
      done
    fi
    all_findings=$(jq -c 'unique_by([.cve, .package])' <<< "$all_findings")
    local total; total=$(jq 'length' <<< "$all_findings")
    echo "  $total unique High/Critical finding(s)"
    [ "$total" -gt 0 ] || continue

    # Attach target repo + fix_strategy per finding.
    routed=$(jq -c --slurpfile r "$ROUTES_FILE" '
      map(. + {repo: ($r[0].types[.type].repo // null),
               fix_strategy: ($r[0].types[.type].fix_strategy // null)})' <<< "$all_findings")

    # Log findings with no route (unknown type) — never drop silently.
    unrouted=$(jq -c 'map(select(.repo == null))' <<< "$routed")
    [ "$(jq 'length' <<< "$unrouted")" -gt 0 ] && \
      echo "::warning::no route for: $(jq -r 'map("\(.cve) (\(.type))") | join(", ")' <<< "$unrouted") — left for manual handling"

    # Log version-bump findings with no upstream fix — cannot bump to a nonexistent version.
    local nofix
    nofix=$(jq -c 'map(select(.repo != null and .fix_strategy == "version-bump" and (.fixed_in // "") == ""))' <<< "$routed")
    [ "$(jq 'length' <<< "$nofix")" -gt 0 ] && \
      echo "::warning::no upstream fix (skipped): $(jq -r 'map("\(.cve) (\(.package))") | join(", ")' <<< "$nofix")"

    # Keep routable findings that are actionable: base-image findings always
    # (fixed via base-image tag bump), version-bump findings only with a FixedVersion.
    routed=$(jq -c 'map(select(.repo != null and (.fix_strategy == "base-image" or (.fixed_in // "") != "")))' <<< "$routed")
    [ "$(jq 'length' <<< "$routed")" -gt 0 ] || { echo "  nothing actionable on $branch"; continue; }

    # Process each repo group.
    repos=$(jq -r '[.[].repo] | unique | .[]' <<< "$routed")
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      group=$(jq -c --arg r "$repo" 'map(select(.repo == $r))' <<< "$routed")
      process_group "$repo" "$branch" "$group" || echo "::warning::group $repo @ $branch failed — continuing"
    done <<< "$repos"
  done <<< "$branches"

  # Repo (manifest) scans — deps that can't be attributed from an image scan
  # (e.g. the standalone docspace-ui-kit-react library). Independent of branches.
  local rs
  while IFS= read -r rs; do
    [ -n "$rs" ] || continue
    process_repo_scan "$rs" || echo "::warning::repo scan failed — continuing"
  done < <(jq -c '.repo_scans[]?' "$ROUTES_FILE")

  echo "CVE auto-fix run complete."
}

main "$@"
