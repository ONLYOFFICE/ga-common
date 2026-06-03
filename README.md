# Reusable GitHub Actions for ONLYOFFICE

Repository contains reusable workflow actions and configuration files used across ONLYOFFICE repositories.

## Usage

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

Scheduled job that monitors workflow failures across multiple repositories and sends Telegram notifications.

### Workflows keepalive

Monthly empty commit to `feature/keeplive` to keep the repository active and prevent GitHub from disabling scheduled workflows.

### Claude Code Review

Automated AI code review for pull requests across all connected Gitea repositories.

An AWS Lambda webhook (`review/lambda/`) receives PR events, verifies the signature, and dispatches `.gitea/workflows/claude-review.yml`. The workflow runs Claude Code against the PR diff and posts a structured review comment with a `✅ APPROVE` / `❌ BLOCKED` verdict and commit status. On subsequent pushes the same comment is updated in place.

- `.gitea/workflows/claude-review.yml` — workflow definition
- `review/REVIEW.md` — review prompt template
- `.gitea/scripts/gitea-api.sh` — Gitea API helpers
- `.gitea/scripts/bugzilla-api.py` — extracts referenced bug IDs, fetches each as XML, renders them for the prompt
- `review/lambda/` — Lambda webhook dispatcher
