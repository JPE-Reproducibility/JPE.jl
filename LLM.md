# JPE.jl - System Architecture for LLMs

## System Purpose
Database-backed workflow management for economics journal replication package verification. Coordinates: Google Forms → DuckDB → Dropbox → GitHub → PackageScanner.jl → Dataverse.

## Core Data Flow

```
Google Form Submission → form_arrivals table → papers + iterations tables
  ↓
Dropbox file request created → Author uploads package
  ↓
Preprocessing (local or remote GitHub Actions) → PackageScanner.jl analysis
  ↓
Assignment → Replicator downloads, works, submits report via Google Form
  ↓
Report → iterations table → DE decision (accept/revise)
  ↓
Accept → Dataverse publication | Revise → new iteration (increment round)
```

## Database Schema

### papers (current state)
- **PK**: `paper_id` (VARCHAR)
- **Status**: `status` (VARCHAR) - workflow state
- **Round**: `round` (INTEGER) - current iteration
- **Links**: `github_url`, `file_request_url_pkg`, `doi`
- **Metadata**: authors, title, journal, confidential flags
- **Dates**: `first_arrival_date`, `date_with_authors`, `date_published`

### iterations (historical record)
- **PK**: (`paper_id`, `round`)
- **Replicators**: `replicator1`, `replicator2` (emails)
- **Effort**: `hours1`, `hours2`, `runtime_code_hours`
- **Results**: `is_success`, `repl_comments`, `data_statement`, `software`
- **Dates**: `date_with_authors`, `date_arrived_from_authors`, `date_assigned_repl`, `date_completed_repl`, `date_decision_de`
- **Decision**: `decision_de` (accept|rnr)

### reports (staging)
- Temporary table for Google Form submissions
- Processed into iterations then cleared

### form_arrivals (staging)
- New papers from Google Forms
- `processed` flag indicates if moved to papers table

## Status Transitions

```
new_arrival → with_author → author_back_de → with_replicator → 
replicator_back_de → acceptable_package → published_package
                        ↓ (if revise)
                   with_author (round++)
```

## Module Responsibilities

| Module | Functions | Dependencies |
|--------|-----------|--------------|
| `db.jl` | DB ops, transactions, CRUD | DuckDB.jl |
| `google.jl` | Google Sheets/Forms I/O | RCall, googlesheets4 (R) |
| `dropbox.jl` | File requests, links, API | PyCall, Python dropbox lib |
| `github.jl` | Repo creation, branches | `gh` CLI |
| `actions.jl` | High-level workflows | All above |
| `preprocess.jl` | Package analysis setup | PackageScanner.jl |
| `gmailing.jl` | Email notifications | PyCall, Python gmail lib |
| `reporting.jl` | Status reports, billing | DataFrames.jl |
| `dataverse.jl` | Publication, MD5 check | HTTP.jl |

## Key Functions

### Workflow Entry Points
- `google_arrivals()` - Ingest new submissions
- `monitor_file_requests()` - Check for package uploads
- `dispatch()` - Preprocess + assign arrived packages
- `assign(paperID)` - Assign to replicator
- `collect_reports()` - Ingest replicator reports
- `de_make_decision(paperID, "accept"|"revise")` - DE decision
- `finalize_publication(paperID, DOI)` - Mark published

### Database Operations
- `db_filter_paper(id)` - Get paper by ID
- `db_filter_iteration(id, round)` - Get specific iteration
- `db_filter_status(status)` - Get papers by status
- `update_paper_status(f, paperID, from, to)` - Transactional status update
- `robust_db_operation(f)` - Transaction wrapper with rollback

### Preprocessing
- `preprocess2(paperID)` - Main preprocessing function
  - Checks package size via Dropbox API
  - Creates `_variables.yml` config
  - Generates `runner_precheck.jl` script
  - Runs locally OR commits to GitHub for remote execution
  - PackageScanner.jl extracts metadata, scans for PII

## Transaction Pattern

All state changes use transactions:
```julia
robust_db_operation() do con
    # Check current state
    # Perform operations
    # Update status
    # Auto-commit on success, rollback on error
end
```

## Environment Variables Required

- `JPE_DB` - DuckDB file location
- `JPE_GOOGLE_KEY` - Google API credentials JSON
- `JPE_DBOX_APPS` - Dropbox Apps folder path
- `JPE_DBOX_APP_SECRET` - Dropbox app secret
- `JPE_DBOX_APP_REFRESH` - Dropbox refresh token
- `JPE_DV` - Dataverse API token
- `JULIA_RUNNER_ENV` - Julia environment for local preprocessing

## Dropbox "Online Only" Problem

### Issue
macOS Dropbox Files On-Demand creates file "stubs" that aren't actually downloaded. Programmatic access (especially in GitHub Actions) doesn't reliably trigger download.

### Current Workaround (Unreliable)
```julia
# Attempt to force download by reading entire file
open(filepath, "r") do io
    while !eof(io)
        read(io, min(1024*1024, bytesavailable(io)))
    end
end
```
**Doesn't work reliably** - Dropbox File Provider doesn't materialize stubs predictably.

### Proposed Solution
Password-protected Dropbox shared links:
1. Create password-protected link via Dropbox API (during preprocessing setup)
2. Store URL in `_variables.yml`, password as GitHub secret
3. Runner downloads via `curl -u :password` (no Dropbox app needed)
4. Benefits: No size limits, no token expiration, works for 100GB+ packages

## File Locations

### Dropbox Structure
```
$JPE_DBOX_APPS/{journal}/{surname-paperID}/{round}/
  ├── replication-package/     (file request destination)
  ├── paper-appendices/         (file request destination)
  ├── preserve/                 (kept after deletion)
  ├── thirdparty/               (kept after deletion)
  └── repo/                     (local GitHub clone)
```

### GitHub Structure
```
JPE-Reproducibility/{Journal}-{Surname}-{PaperID}
  ├── branch: round1, round2, ...
  ├── _variables.yml            (preprocessing config)
  ├── runner_precheck.jl        (preprocessing script)
  ├── TEMPLATE.qmd              (report template)
  ├── {CaseID}.qmd              (completed report)
  └── replication-package/      (copied during preprocessing)
```

## Security Considerations

- All GitHub repos are **private**
- Replicators sign confidentiality agreements
- `is_confidential` flag tracks sensitive data
- Email uses OAuth2 + TLS
- Dropbox links use unguessable tokens
- Password-protected links add two-factor security (link + password via different channels)

## Preprocessing: Local vs Remote

### Local (on Mac with Dropbox sync)
✅ Reliable file access, any size, immediate execution
❌ Ties up machine, limited resources

### Remote (GitHub Actions)
✅ Dedicated resources, parallel execution, doesn't block user
❌ Dropbox access unreliable (the core problem), package size limits

### Package Size Handling
- Small (< 10GB): Full extraction, complete scan
- Large (10-100GB): Partial extraction, size thresholds, manifest generation
- Very large (> 100GB): Local only, or requires Dropbox download link solution

## Error Recovery

### Backups
- CSV backups before critical operations
- `db_write_backup(table, df)` / `db_read_backup(table)`
- `db_bk_create()` for timestamped backups

### Status Validation
- `validate_paper_status(paperID)` - Check consistency
- `set_status!(paperID)` - Auto-repair based on iteration data

### Transaction Rollback
All `robust_db_operation()` calls auto-rollback on exceptions.

## Typical Daily Workflow

1. `using JPE` - loads module, shows status table
2. `google_arrivals()` - process new submissions
3. `monitor_file_requests()` - check for uploads
4. `dispatch()` - preprocess + assign new arrivals
5. `collect_reports()` - ingest replicator reports
6. `de_process_waiting_reports()` - make decisions
7. `replicator_workload_report(update_gsheet=true)` - update tracking

## Critical Paths

### New Paper Path
`Google Form` → `google_arrivals()` → `papers` table (status: new_arrival) → File request created → Email sent → Status: with_author

### Preprocessing Path
`monitor_file_requests()` detects arrival → `dispatch()` → `preprocess2()` → Clone GitHub → Create config → Run PackageScanner (local or remote) → Commit results → `assign()` → Email replicator → Status: with_replicator

### Report Path
Replicator submits Google Form → `collect_reports()` → `reports` table → Validate → Update `iterations` → Clear `reports` → Status: replicator_back_de

### Decision Path
`de_make_decision()` → Accept: status = acceptable_package | Revise: create new iteration, increment round, new branch, new file request, status = with_author

## Data Types

### Key Types
- Paper IDs: String (e.g., "12345678")
- Rounds: Integer (1, 2, 3, ...)
- Statuses: String (see status transitions)
- Dates: Julia `Date` type
- Booleans: `true`/`false`/`missing`
- Emails: String (lowercase)

### Missing Values
Database uses SQL `NULL`, Julia represents as `missing`. Many fields allow missing (especially before data is available).

## External Dependencies

### Julia Packages
DuckDB, DataFrames, HTTP, JSON, PyCall, RCall, CSV, Chain, Term

### Python Packages  
dropbox, google-auth, google-api-python-client

### R Packages
googlesheets4

### CLI Tools
gh (GitHub CLI), git, curl, unzip, tar

### External Services
Google Forms/Sheets, Gmail API, Dropbox API, GitHub, Dataverse
