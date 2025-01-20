# Reusable Github actions for/by ONLYOFFICE

Repository contains reusable actions workflows. Also contains config files for some of them. 

Actions calls from actions in another ONLYOFFICE repositories. 

For example:

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

## Repo content 

### Helm charts linters

Action for checking helm charts for compliance with the rules for formatting yaml files and for compliance with the configured rules for kubernetes manifests.

### k8s Deprecated recources validator

Action for check deprecated api and other resources in k8s yaml manifests

### Organization snyk action scanner

Weekly checks the organization's actions in open repositories for the presence of incorrectly formatted actions
