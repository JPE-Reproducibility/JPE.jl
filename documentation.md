# CLAUDE.md — JPE.jl Codebase Guide

This file provides concise, actionable context for AI assistants working on this codebase.

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

---

## Required Environment Variables

The module errors on load if `JPE_DB` is missing. All others are needed for their respective subsystems.

```bash
JPE_DB              # Directory where jpe.duckdb lives (e.g. /Users/you/dbs/jpe)
JPE_GOOGLE_KEY      # Path to Google OAuth2 credentials JSON
JPE_DBOX_APPS       # Local Dropbox Apps folder (e.g. /Users/you/Dropbox/Apps/JPE-packages)
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

## Paper Status Machine

Papers move through exactly these statuses (stored in `papers.status`):

```
new_arrival
    → with_author           (google_arrivals: file request sent to author)
    → author_back_de        (monitor_file_requests: package uploaded to Dropbox)
    → with_replicator       (assign: replicator assigned, email sent)
    → replicator_back_de    (collect_reports: report received from replicator)
    → acceptable_package    (de_make_decision "accept")
    → published_package     (finalize_publication: DOI recorded)

    replicator_back_de → with_author  (de_make_decision "revise": new round, round++)
```

**Key rule**: every status transition MUST go through `update_paper_status(f, paperID, from, to)` which:
1. Verifies `papers.status == from` inside a transaction
2. Executes `f(con)` (your side-effect code)
3. Updates `papers.status = to`
4. Auto-commits on success, auto-rollbacks on any error

---

## Database Schema (Key Tables)

### `papers` — one row per paper, current state
- PK: `paper_id` (VARCHAR, e.g. `"12345678"`)
- `status` — current workflow status
- `round` — current iteration number
- `paper_slug` — `"Surname-paperID"`, used in paths and repo names
- `gh_org_repo` — `"JPE-Reproducibility/JPE-Surname-12345678"`
- `file_request_id_pkg`, `file_request_id_paper` — active Dropbox file request IDs
- `is_confidential`, `share_confidential` — governs access controls

### `iterations` — one row per (paper, round), historical record
- PK: `(paper_id, round)`
- `replicator1`, `replicator2` — email addresses
- `hours1`, `hours2`, `runtime_code_hours`
- `is_success`, `decision_de` (`accept` | `rnr`)
- All dates: `date_with_authors`, `date_arrived_from_authors`, `date_assigned_repl`, `date_completed_repl`, `date_decision_de`
- `file_request_id_pkg`, `file_request_url_pkg`, `file_request_id_paper`, `file_request_url_paper`

### `reports` — staging table for Google Form submissions
- Processed into `iterations` by `collect_reports()`, then cleared

### `form_arrivals` — staging table for new submissions from Google Forms
- Processed into `papers`+`iterations` by `google_arrivals()`, then flagged `processed=true`

---

## Critical Code Patterns

### 1. All DB writes use the transaction wrapper
```julia
robust_db_operation() do con
    DBInterface.execute(con, "UPDATE ...")
    DBInterface.execute(con, "INSERT ...")
    # auto-commits; auto-rollbacks on exception
end
```

### 2. Status transitions use `update_paper_status`
```julia
update_paper_status(paperID, "author_back_de", "with_replicator") do con
    # side effects go here (email, DB updates, etc.)
    # the status flip happens automatically after this block
end
```

### 3. Dropbox token expires in ~30 minutes
- `dbox_set_token()` refreshes the global `dbox_token`
- All Dropbox functions have a `try/catch` that calls `dbox_set_token()` and retries once
- Never store `dbox_token` in a local variable across a long operation

### 4. Python modules loaded at startup
- `@pyinclude` in `__init__()` loads `db_filerequests.py` and `gmail_client.py`
- After editing Python files, you must restart Julia and re-`using JPE`
- PyCall must point to the pyenv virtualenv Python; fix with `ENV["PYTHON"] = "..."` + `Pkg.build("PyCall")`

### 5. R/googlesheets4 auth is cached
- Credentials cached in `~/.config/googlesheets4/`
- Re-auth: `gs4_auth()` (opens browser)
- Hardcoded Google Sheet IDs are in `google.jl` (`gs_arrivals_id()`, `gs_reports_id()`, etc.)

### 6. GitHub uses `gh` CLI, not HTTP.jl
- All repo/branch ops shell out via `run(``gh ...``)` or `gh_silent_run(cmd)`
- Must be authenticated: `gh auth login`; must have org access: `gh auth refresh -s admin:org`
- Repo names go through `sanitize_repo_name()` for international character transliteration

### 7. Schema migration is additive
- To add a column: add it to `db_get_table_schema(table)` in `db.jl`
- Then call `db_add_missing_columns(table)` — it NOPs on existing columns
- Never DROP or RENAME columns without a backup

---

## File System Conventions

### Dropbox structure (under `$JPE_DBOX_APPS`)
```
{journal}/{Surname-paperID}/{round}/
  ├── replication-package/   ← file request destination for author
  ├── paper-appendices/      ← file request destination for editorial office
  ├── preserve/              ← never deleted (e.g. documentation)
  ├── thirdparty/            ← never deleted (third-party data)
  └── repo/                  ← local clone of GitHub repo
```
Helper: `get_dbox_loc(journal, slug, round; full=false)` returns relative or absolute path.

### GitHub structure
```
JPE-Reproducibility/{Journal}-{Surname}-{PaperID}   ← repo name
  branches: round1, round2, ...
  ├── _variables.yml         ← preprocessing config (auto-generated)
  ├── runner_precheck.jl     ← preprocessing script (auto-generated)
  ├── TEMPLATE.qmd           ← report template
  └── {CaseID}.qmd / .pdf    ← completed report
```

### Case ID format
`{Journal}-{Surname}-{PaperID}-R{round}` — generated by `case_id(journal, surname, paperID, round)`.

---

## Typical Daily Workflow (in order)

```julia
using JPE                            # loads module, shows ps() status table

google_arrivals()                    # 1. Ingest new Google Form submissions
monitor_file_requests()              # 2. Check Dropbox for author uploads
dispatch()                           # 3. Preprocess + assign arrived packages
collect_reports()                    # 4. Ingest replicator reports from Google Form
de_process_waiting_reports()         # 5. Interactive: review reports, accept/revise
replicator_workload_report(          # 6. Update tracking sheet
    update_gsheet=true)
db_bk_create()                       # 7. Create timestamped CSV backup
```

---

## Preprocessing: Local vs Remote

`preprocess2(paperID)` does setup then asks the user to choose:

| | Local (Mac with Dropbox sync) | Remote (GitHub Actions) |
|---|---|---|
| Reliability | ✅ Reliable | ❌ Unreliable (see below) |
| Size support | ✅ Any size | ⚠️ Up to ~50 GB practically |
| Machine impact | ❌ Ties up your Mac | ✅ Runs unattended |

**The "Dropbox Online Only" problem**: macOS Dropbox "Files On-Demand" creates file stubs. Programmatic access does NOT reliably trigger download. `filesize()` returns 0, `open()` may fail. The current `force_download_directory()` workaround in `runner_precheck.jl` is **unreliable**.

**Proposed fix** (not yet implemented — see `PROPOSAL.md`): Generate a password-protected Dropbox shared link during `preprocess2()`, store the URL in `_variables.yml`, store the password as a per-paper GitHub secret (`DROPBOX_PASSWORD_{paperID}_R{round}`), and have `runner_precheck.jl` download via `curl -u :$password`. See `PROPOSAL.md` for full implementation spec.

---

## Testing

```bash
julia --project=. test/runtests.jl
```

- Mark test DB entries with `"[TEST]"` in the `comments` field
- Test entries are excluded from `ps()` display
- Bulk delete test entries: `db_delete_test()`
- Test specific modules: `include("test/test_dropbox.jl")` etc.

---

## Debugging Helpers

```julia
ENV["JULIA_DEBUG"] = "JPE"   # enable @debug output
ps()                          # color-coded status table (all papers)
db_show()                     # list DB tables and row counts
db_filter_paper("12345678")   # get paper row
db_filter_iteration("12345678", 2)  # get specific iteration
validate_paper_status("12345678")   # check consistency
set_status!("12345678")             # auto-repair status from dates
db_connection_status()              # check if DuckDB connection is open
db_release_connection()             # close stale connection
db_reconnect()                      # reopen
```

---

## Common Gotchas

1. **`JPE_DB` not set** — module throws on load before `__init__` runs.
2. **PyCall wrong Python** — `ModuleNotFoundError` at startup. Fix: `ENV["PYTHON"] = pyenv_shims_path; Pkg.build("PyCall")` then restart Julia.
3. **Dropbox token stale** — `"Invalid access token"` error. Call `dbox_set_token()` manually or restart module.
4. **GitHub no org access** — `"Resource not accessible"`. Fix: `gh auth refresh -s admin:org`.
5. **GitHub repos are public** — created with `--public` for pricing. GitHub Secrets are still fully encrypted and safe in public repos.
6. **`robust_db_operation` inside another transaction** — DuckDB does not support nested transactions. Never nest `robust_db_operation` calls.
7. **Missing `replicator1`** — `collect_reports()` uses `reports_to_process()` which joins on `replicator1 IS NULL`. If the replicator email in the Google Form doesn't match exactly, the report won't be found.
8. **Report PDF must exist before `de_make_decision("revise")`** — `prepare_rnrs()` asserts `isfile(report_pdf_path(r))`. Compile the Quarto report first.
9. **Large packages** — `dbox_get_folder_size()` may time out for 100 GB+ folders. Use local preprocessing for very large packages.

---

## Pending / In-Progress Work

| Item | Status | Reference |
|---|---|---|
| Password-protected Dropbox links for remote preprocessing | Proposed, not implemented | `PROPOSAL.md` |
| `dropbox_password` column in `iterations` schema | Not yet added to `db_get_table_schema()` | `PROPOSAL.md` §Phase 4.1 |
| `dbox_create_password_link()` Julia wrapper | Stub comment in `dropbox.jl`, not implemented | `PROPOSAL.md` §Phase 1.2 |
| Automatic Slack DM for password sharing | Future enhancement | `PROPOSAL.md` §Enhancement 6 |
| Automated status monitoring (`monitor_overdue_papers`) | Proposed | `DEVELOPERS.md` §Proposed Enhancements |

---

## Key Conventions Summary

- **`snake_case`** for all functions and variables; **`SCREAMING_SNAKE_CASE`** for module-level constants
- **`@chain`** (`Chain.jl`) for DataFrame pipelines
- **`PrettyTables`** for terminal output; always support `save_csv=true` keyword in report functions
- **`RadioMenu` / `ask()`** (Term.jl) for interactive prompts; always default to the safe/no-op choice
- **Conventional commits**: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`
- **Always create a backup** (`db_bk_create()`) before any destructive operation
