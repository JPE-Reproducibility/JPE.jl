# CLAUDE.md — JPE.jl Codebase Guide

---

## What This Project Does

**JPE.jl** is a Julia package that manages the full lifecycle of replication-package verification for the *Journal of Political Economy*. It is the Data Editor's (DE) primary tool: it tracks papers through a multi-stage editorial workflow stored in an embedded DuckDB database, orchestrating Dropbox file requests, GitHub repository creation, Google Sheets/Forms ingestion, Gmail notifications, external replicator assignment, and final publication to Dataverse.

---

## Technology Stack

| Layer | Technology | How Used |
|---|---|---|
| Primary language | Julia | All business logic |
| Database | DuckDB (embedded, file-based) | Single `jpe.duckdb` file, no server needed |
| Dropbox API | Python (`dropbox` lib) via `PyCall` | File requests, shared links, folder ops |
| Gmail API | Python (`google-api-python-client`) via `PyCall` | Email drafts/sends |
| Google Sheets | R (`googlesheets4`) via `RCall` | Read arrivals & reports forms, write workload sheets |
| GitHub | `gh` CLI (shell-out) | Repo creation, branch management |
| Package analysis | `PackageScanner.jl` (external) | Scans replication packages |
| Publication | Dataverse REST API via `HTTP.jl` | MD5 verification, marking published |

## Code Execution and Testing

- use the julia-mcp to run julia code in a persistent session.
- execute tests via `julia_eval(code, test/, timeout?)` where test/ is relative to the package root.

## git commits

- make incremental commits
- checkout new branches for new features
- create tests for new features and run them
- use the gh cli as user `jpedataeditor`. execute `gh auth status` to confirm and execute `gh auth switch` if user is not jpedataeditor. You have permissions to do that.

---

## Required Environment Variables

The module errors on load if `JPE_DB` is missing. All others are needed for their respective subsystems.

```bash
JPE_DB              # Directory where jpe.duckdb lives (e.g. /Users/you/dbs/jpe)
JPE_GOOGLE_KEY      # Path to Google OAuth2 credentials JSON
JPE_DBOX_APPS       # Local Dropbox Apps folder (e.g. /Users/you/Dropbox/Apps/JPE-packages)
JPE_DBOX_APP        # Dropbox app key
JPE_DBOX_APP_SECRET # Dropbox app secret
JPE_DBOX_APP_REFRESH# Dropbox refresh token (long-lived)
JPE_DV              # Dataverse API token
JULIA_RUNNER_ENV    # Path to Julia environment used for local preprocessing
```

`JPE_TEST=1` activates test mode (suppresses certain side effects).

---

## Module Map (`src/`)

| File | Purpose |
|---|---|
| `JPE.jl` | Entry point: loads Python/R modules, refreshes Dropbox token, prints status table |
| `db.jl` | All DuckDB ops: connection management, CRUD, transactions, schema, integrity checks |
| `google.jl` | Google Sheets/Forms I/O: read arrivals, read reports, read replicator list, write workload |
| `dropbox.jl` | Dropbox API: token refresh, file requests, shared links, folder size, download helpers |
| `github.jl` | GitHub via `gh` CLI: repo creation, branch ops, clone, name sanitization |
| `actions.jl` | High-level workflow: `dispatch`, `assign`, `collect_reports`, `de_make_decision`, `finalize_publication`, `monitor_file_requests` |
| `preprocess.jl` | Preprocessing setup: clone repo, check size, write `_variables.yml`, write `runner_precheck.jl`, run locally or push to GitHub Actions |
| `gmailing.jl` | Email templates: file request, assignment, RnR, acceptance ("g2g"), invoice |
| `reporting.jl` | Reports: `ps()` status table, global stats, billing, workload, time-in-status |
| `dataverse.jl` | Dataverse: MD5 file verification |
| `db_backups.jl` | CSV backups: create, read, integrity check, repair |
| `snippets.jl` | Utilities: `case_id`, `get_dbox_loc`, `setup_dropbox_structure!`, type helpers |
| `zip.jl` | Zip handling: `read_and_unzip_directory`, `disk_size_gb`, `rm_git` |
| `db_filerequests.py` | Python: Dropbox file request and link creation |
| `gmail_client.py` | Python: Gmail API send/draft |

---

## Further documentation

(read only if needed)

documentation.md