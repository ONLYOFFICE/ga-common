# GitHub Actions for ONLYOFFICE

Repository contains reusable workflow actions and configuration files used across ONLYOFFICE repositories.

## Reusable actions usage

Workflows are called from other ONLYOFFICE repositories. Example:

```yaml
name: lint

on:
  pull_request:
    types: [opened, reopened, synchronize]
    paths-ignore:
      - '.github/**'
      - '**/README.md'
      - '**/CHANGELOG.md'
      - '**/LICENSE'

jobs:
  lint-chart:
    name: lint chart ${{ github.event.repository.name }}
    uses: ONLYOFFICE/ga-common/.github/workflows/helm-units.yaml@master
    with:
      ct_version: 3.8.0
      enable_yaml_lint: true
      enable_kube_lint: true
```

---

## Workflows

### Helm charts linter

Checks Helm charts for YAML formatting compliance and Kubernetes manifest rules.

### k8s Deprecated resources validator

Checks Kubernetes YAML manifests for deprecated API versions and resources.

### Snyk scanner

Weekly scan of the organization's open repositories for incorrectly formatted GitHub Actions.

### Workflows notification

Scheduled job that monitors workflow and buildserver failures across multiple repositories and sends Telegram notifications.

### Workflows keepalive

Monthly empty commit to `feature/keeplive` to keep the repository active and prevent GitHub from disabling scheduled workflows.

### Document Server / Desktop CI (install & test)

Manually dispatched job that installs a given Document Server / Desktop Editors build across Windows and macOS runners for each edition and package type (inno-setup, MSI/advanced-installer, portable, DMG). The Windows Document Server job additionally waits for a healthcheck and runs the Puppeteer smoke-test suite; the Desktop Windows/macOS jobs verify the install/mount and report the installed version.

### Claude Code Review

Automated AI code review for pull requests across all connected Gitea repositories.

An AWS Lambda webhook (`review/lambda/`) receives PR events, verifies the signature, and dispatches `.gitea/workflows/claude-review.yml`. The workflow runs Claude Code against the PR diff and posts a structured review comment with a `✅ APPROVE` / `❌ BLOCKED` verdict and commit status. On subsequent pushes the same comment is updated in place.

- `.gitea/workflows/claude-review.yml` — workflow definition
- `review/REVIEW.md` — review prompt template
- `.gitea/scripts/review-run.sh` — the workflow's shell steps (Gitea API helpers, prepare/post, sandbox)
- `.gitea/scripts/common.py bugzilla-context` — extracts referenced bug IDs, fetches each via the REST API, renders them for the prompt
- `review/lambda/` — Lambda webhook dispatcher

### Jenkins Build-Failure Review

Automated AI root-cause analysis for failed Jenkins builds of the ONLYOFFICE editors.

When a Jenkins build fails, Jenkins triggers `.github/workflows/jenkins-analyze-build.yaml` (via `gh workflow run`, passing the branch and build number). The workflow pulls only the failed stages' logs from the Jenkins API, resolves the exact as-built commit of every repo, lets Claude pick which repos it needs and clones them at those commits, then runs Claude Code against each failed stage to find the root cause. It reports a per-stage diagnosis (cause + fix) to Telegram as Markdown files plus a full report archive.

#### Flow

1. **Fetch failed stages** — `wfapi` lists the pipeline stages; only `FAILED` ones are pulled, decoded (HTML/ANSI stripped) and saved as `stage_<id>_<slug>.log`.
2. **Resolve checkout** — the build's `BuildData` (Git plugin) gives `repo -> commit` for all repos, straight from the Jenkins API (no console log parsing).
3. **Select repos (phase 1)** — Claude reads the stage logs + the repo list and returns the smallest set of repos needed to investigate (base repos always added).
4. **Clone** — the selected repos are cloned at their exact as-built commits under `src/`.
5. **Root-cause (phase 2)** — Claude Code analyzes each failed stage over `src/`, guided by a build map, and emits a schema-validated JSON diagnosis.
6. **Report** — each diagnosis is rendered to `stage_<slug>.md` and sent to Telegram, with a full `stages_report_<build>.zip`.

#### Files

- `.github/workflows/jenkins-analyze-build.yaml` — workflow definition (triggered by Jenkins)
- `jenkins_review_tools/fetch_failed_stages.sh` — pulls & cleans the logs of the FAILED pipeline stages via `wfapi`
- `jenkins_review_tools/jenkins_checkout.py` — builds `checkout.json` (repo → commit → branch) from the Jenkins `BuildData` API
- `jenkins_review_tools/select-repos.tmpl` — phase-1 prompt: which repos to clone
- `jenkins_review_tools/select_repos.py` — validates Claude's picks against the checkout and adds base repos
- `jenkins_review_tools/build-prompt.tmpl` — phase-2 prompt: the root-cause task template
- `jenkins_review_tools/build-overview.md` — static map of how ONLYOFFICE builds (orientation for Claude)
- `jenkins_review_tools/diag-schema.json` — JSON schema that the diagnosis must match (`--json-schema`)
- `jenkins_review_tools/extract_diag.py` — extracts the diagnosis object from the `claude -p` output
- `jenkins_review_tools/render_md.py` — renders a diagnosis into a readable `stage_<slug>.md`

#### Configuration

- **vars:** `JENKINS_URL`, `GITEA_URL`
- **secrets:** `JENKINS_USER`, `JENKINS_TOKEN`, `GITEA_TOKEN`, `ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
