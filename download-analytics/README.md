# Download Analytics

Collects GitHub release download counts for `ONLYOFFICE/DesktopEditors` and
`ONLYOFFICE/DocumentServer` and updates `ONLYOFFICE-Download-Statistics-YYYY.xlsx`
on ONLYOFFICE DocSpace. Every workflow run publishes the report.
The year uses the collection timezone (Asia/Tashkent by default), for example
`ONLYOFFICE-Download-Statistics-2026.xlsx`. Each year starts a new document with
the five latest stable releases per product; previous yearly reports are left untouched.

## Report

- Two permanent visible sheets: **Desktop Editors** and **Document Server**.
- Every run collects the five latest published stable releases of each product.
- New releases appear automatically. Versions outside the latest five retain their
  earlier history, but no longer receive fresh counts; new date columns show a dash.
- Each run adds a date column. New releases appear above older releases;
  historical counts stay matched by product, release ID, and asset ID.
- Artifacts are grouped by category and platform, with platform and category totals.
- `addon-*` files are Add-ons, other ZIP files are Updates, and other packages
  are Installations. Linux `.tar.xz` archives are excluded from rows and totals.
- Drafts, prereleases, and automatic source archives are excluded.
- Missing observations show a dash; actual zero counts remain zero.
- The hidden `_history` sheet stores history. Do not edit or delete it.

## Gitea setup

Configure these repository or organization secrets and variables:

| Type | Name | Purpose |
| --- | --- | --- |
| Secret | `DOCSPACE_API_KEY` | DocSpace API key with Files & Folders read/write access |
| Variable | `DOCSPACE_FOLDER_ID` | Destination folder ID, e.g. `17974` |
| Variable (optional) | `DOCSPACE_URL` | Defaults to `https://nct2.onlyoffice.com` |

Checkout uses the built-in Gitea job token; no personal Gitea token or hostname secret is needed.
GitHub release metadata is collected without authentication; no GitHub token is required.
The public API limit is 60 requests per hour per source IP, shared with other jobs.
The DocSpace key owner must have access to the destination folder.
The Linux runner needs Git, Bash, Python 3.10+ with venv support, and network access
to Gitea, GitHub API, PyPI, and DocSpace. Dependencies are installed in a temporary venv.

## Run

Open **Actions > Download Analytics > Run workflow** in Gitea.
The workflow is `.gitea/workflows/download-analytics.yml`.
Scheduled runs are every Thursday at **05:00 UTC (10:00 Asia/Tashkent)**.
Keep the workflow on the repository's default branch for scheduled runs.

The existing workbook is downloaded before a new column is added. Collection,
history-read, duplicate-name, or file-version errors stop publication.
Close the report in the editor before updating it. Old snapshot-style reports
are not migrated; start with a new document when switching from that format.
Reports are not committed or uploaded as CI artifacts.
