# JPE.jl - Journal of Political Economy Replication Package Management System

[![Build Status](https://github.com/floswald/JPE.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/floswald/JPE.jl/actions/workflows/CI.yml?query=branch%3Amain)

JPE.jl is a comprehensive database backend and workflow management system for the JPE Data Editor. It orchestrates the entire lifecycle of replication package verification, from initial submission through publication.

---

## Table of Contents

- [Overview](#overview)
- [System Architecture](#system-architecture)
- [Complete Workflow](#complete-workflow)
- [Database System](#database-system)
- [Key Operations](#key-operations)
- [Preprocessing Deep Dive](#preprocessing-deep-dive)
- [Security Model](#security-model)
- [Setup & Configuration](#setup--configuration)
- [API Reference](#api-reference)
- [Troubleshooting](#troubleshooting)

---

## Overview

### What JPE.jl Does

JPE.jl manages replication packages for economics research papers by:

1. **Tracking submissions** via integration with Google Forms and Sheets
2. **Managing package storage** via Dropbox file requests and local storage
3. **Preprocessing packages** using [PackageScanner.jl](https://github.com/JPE-Reproducibility/PackageScanner.jl)
4. **Coordinating replicators** through assignment, tracking, and report collection
5. **Maintaining workflow state** in a DuckDB database with robust transaction handling
6. **Facilitating decisions** on package acceptability
7. **Publishing packages** to Dataverse upon acceptance

### Key Features

- **Database-driven workflow**: DuckDB-backed tracking of papers through all stages
- **Automated notifications**: Email integration with Gmail API for author/replicator communication
- **GitHub integration**: Each package gets a private repository for collaboration
- **Dropbox integration**: File request system for package submission
- **Flexible preprocessing**: Can run locally or on remote GitHub Actions runners
- **Comprehensive reporting**: Workload tracking, status reports, billing for replicators
- **Data security**: Handles confidential data with appropriate access controls

---

## System Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         JPE.jl System                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐     │
│  │   Google     │───▶│   DuckDB     │◀──▶│   Dropbox    │     │
│  │   Forms      │    │   Database   │    │   Storage    │     │
│  └──────────────┘    └──────────────┘    └──────────────┘     │
│         │                    │                    │             │
│         │                    │                    │             │
│         ▼                    ▼                    ▼             │
│  ┌──────────────────────────────────────────────────────┐      │
│  │              JPE.jl Core Workflow                     │      │
│  │  (actions.jl, google.jl, dropbox.jl, db.jl, etc.)   │      │
│  └──────────────────────────────────────────────────────┘      │
│         │                    │                    │             │
│         ▼                    ▼                    ▼             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐     │
│  │    Gmail     │    │    GitHub    │    │ PackageScanner│     │
│  │     API      │    │  Repos/Orgs  │    │      .jl      │     │
│  └──────────────┘    └──────────────┘    └──────────────┘     │
│                              │                                  │
│                              ▼                                  │
│                      ┌──────────────┐                          │
│                      │  Dataverse   │                          │
│                      │  (Final Pub) │                          │
│                      └──────────────┘                          │
└─────────────────────────────────────────────────────────────────┘
```

### Module Organization

JPE.jl is organized into functional modules:

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `JPE.jl` | Main entry point | Initialization, logo, module loading |
| `db.jl` | Database operations | Connection management, CRUD, transactions |
| `google.jl` | Google Sheets/Forms | Reading arrivals/reports, authentication |
| `dropbox.jl` | Dropbox integration | File requests, link generation, folder ops |
| `actions.jl` | High-level workflows | `dispatch()`, `assign()`, `collect_reports()` |
| `preprocess.jl` | Package preprocessing | `preprocess2()`, runner script generation |
| `github.jl` | GitHub operations | Repo creation, branch management |
| `gmailing.jl` | Email communications | Templates for authors/replicators |
| `reporting.jl` | Status reports | Workload, billing, status summaries |
| `dataverse.jl` | Publication | Dataverse deposit and verification |

---

## Complete Workflow

### Paper Lifecycle

A paper progresses through these stages:

```
┌─────────────────┐
│  new_arrival    │  ─── Author submits via Google Form
└────────┬────────┘      File request sent
         │
         ▼
┌─────────────────┐
│  with_author    │  ─── Author uploads package via Dropbox
└────────┬────────┘      Preprocessing happens
         │
         ▼
┌─────────────────┐
│ author_back_de  │  ─── DE reviews, assigns to replicator
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ with_replicator │  ─── Replicator works on package
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│replicator_back_de│ ─── DE reviews report
└────────┬────────┘
         │
         ├──────────────┐
         │              │
         ▼              ▼
┌─────────────────┐  ┌─────────────────┐
│acceptable_package│  │  with_author   │  (if revisions needed)
└────────┬────────┘  └────────┬────────┘
         │                    │
         │                    └─────► (cycle repeats)
         ▼
┌─────────────────┐
│published_package│  ─── Published to Dataverse
└─────────────────┘
```

### Detailed Workflow Steps

#### 1. Initial Submission (`new_arrival` → `with_author`)

**What happens:**
1. Author or editorial office fills Google Form
2. Data appears in Google Sheet
3. DE runs `google_arrivals()` which:
   - Reads new entries from sheet
   - Creates record in `papers` and `iterations` tables
   - Creates Dropbox folder structure
   - Generates file request links for package and paper
   - Creates private GitHub repository from template
   - Sends email to author with file request link
   - Updates status to `with_author`

**Command:**
```julia
using JPE
google_arrivals()
```

**What gets created:**
- Database entries in `papers` and `iterations` tables
- Dropbox structure: `/JPE/{surname}-{paperID}/{round}/`
- GitHub repo: `JPE-Reproducibility/JPE-{Surname}-{paperID}`
- File requests for package and paper appendices

---

#### 2. Package Arrival & Preprocessing (`with_author` → `author_back_de`)

**What happens:**
1. Author uploads package via Dropbox file request
2. DE monitors arrivals with `monitor_file_requests()`
3. When package detected, DE runs `dispatch()` which calls `preprocess2(paperID)`
4. Preprocessing either runs locally or remotely (user chooses)

**Commands:**
```julia
# Check for arrivals
monitor_file_requests()

# Dispatch packages that have arrived
dispatch()

# Or manually preprocess specific paper
preprocess2("12345678")
```

**Preprocessing workflow:**
See [Preprocessing Deep Dive](#preprocessing-deep-dive) for details.

---

#### 3. Replicator Assignment (`author_back_de` → `with_replicator`)

**What happens:**
1. DE runs `assign(paperID)` which:
   - Shows available replicators (color-coded by OS and availability)
   - Prompts for primary and optional secondary replicator
   - Generates Dropbox download link
   - Sends assignment email with link to package
   - Updates database with replicator info and assignment date
   - Changes status to `with_replicator`

**Command:**
```julia
assign("12345678")
```

**Replicator selection:**
- Displays replicators grouped by OS (Windows, macOS, Linux)
- Green = available, Red = at capacity
- Shows current workload count
- Can assign 1 or 2 replicators
- Remembers previous round's replicators as defaults

---

#### 4. Report Collection (`with_replicator` → `replicator_back_de`)

**What happens:**
1. Replicator submits report via Google Form
2. DE runs `collect_reports()` which:
   - Reads new reports from Google Sheet
   - Validates report data
   - Updates `iterations` table with report details
   - Changes paper status to `replicator_back_de`
   - Updates replicator workload tracking

**Command:**
```julia
collect_reports()
```

**What gets updated:**
- Replicator hours, comments, data statement
- Software requirements, HPC/remote flags
- Success/failure status
- Completion date

---

#### 5. Decision Making (`replicator_back_de` → `acceptable_package` or `with_author`)

**What happens:**
1. DE reviews reports with `de_process_waiting_reports()` or manually
2. DE prepares report PDF in GitHub repo
3. DE makes decision:
   - **Accept**: `de_make_decision(paperID, "accept")`
   - **Revise**: `de_make_decision(paperID, "revise")`

**Accept workflow:**
- Status → `acceptable_package`
- Sends "good to go" email to author
- Ready for Dataverse publication

**Revise workflow:**
- Creates new iteration (increments round)
- Creates new GitHub branch for round
- Creates new Dropbox file request
- Sends revision request email with report PDF
- Status → `with_author`
- Cycle repeats at step 2

**Commands:**
```julia
# Interactive processing
de_process_waiting_reports()

# Or manual decision
de_make_decision("12345678", "accept")
de_make_decision("12345678", "revise")
```

---

#### 6. Publication (`acceptable_package` → `published_package`)

**What happens:**
1. Package deposited to Dataverse (external process)
2. DE receives DOI from Dataverse
3. DE runs `finalize_publication(paperID, DOI)`
4. System verifies package integrity via MD5 checksums
5. Updates database with DOI and publication date
6. Optionally deletes archive material from Dropbox

**Command:**
```julia
finalize_publication("12345678", "doi:10.7910/DVN/XXXXX")
```

---

## Database System

### Database Technology

JPE.jl uses **DuckDB**, an embedded analytical database that provides:
- ACID transactions
- SQL query interface
- Fast analytical queries
- File-based storage (no server needed)
- Excellent Julia integration via DuckDB.jl

### Database Location

Set via environment variable `JPE_DB`:
```bash
export JPE_DB="/path/to/your/duckdb/location"
```

The database file is created at `$JPE_DB/jpe.duckdb`.

### Tables

#### `papers` Table

Main table tracking each paper's current state:

| Column | Type | Description |
|--------|------|-------------|
| `timestamp` | TIMESTAMP | Initial creation time |
| `journal` | VARCHAR | Journal name (JPE, JoPE, etc.) |
| `paper_id` | VARCHAR | Unique paper identifier (e.g., "12345678") |
| `title` | VARCHAR | Paper title |
| `firstname_of_author` | VARCHAR | First author's first name |
| `surname_of_author` | VARCHAR | First author's surname |
| `email_of_author` | VARCHAR | First author's email |
| `email_of_second_author` | VARCHAR | Optional second author email |
| `handling_editor` | VARCHAR | Editor handling this paper |
| `is_confidential` | BOOLEAN | Contains confidential data? |
| `share_confidential` | BOOLEAN | Confidential data shared with DE? |
| `comments` | VARCHAR | Special notes (e.g., "[TEST]" for test cases) |
| `paper_slug` | VARCHAR | URL-safe identifier (surname-paperid) |
| `first_arrival_date` | DATE | When paper first arrived |
| `status` | VARCHAR | Current workflow status (see statuses below) |
| `round` | INTEGER | Current iteration round number |
| `file_request_id_pkg` | VARCHAR | Current Dropbox file request ID for package |
| `file_request_id_paper` | VARCHAR | Current Dropbox file request ID for paper |
| `file_request_url_pkg` | VARCHAR | URL for package file request |
| `file_request_url_paper` | VARCHAR | URL for paper file request |
| `date_with_authors` | DATE | When current round sent to authors |
| `date_published` | DATE | When package published to Dataverse |
| `is_remote` | BOOLEAN | Requires remote replication? |
| `is_HPC` | BOOLEAN | Requires HPC resources? |
| `data_statement` | VARCHAR | Data availability statement |
| `software` | VARCHAR | Software used in package |
| `github_url` | VARCHAR | URL to GitHub repository |
| `gh_org_repo` | VARCHAR | GitHub org/repo identifier |
| `doi` | VARCHAR | Dataverse DOI of published package |
| `doi_paper` | VARCHAR | DOI of published paper |

#### `iterations` Table

Tracks each revision round of a paper:

| Column | Type | Description |
|--------|------|-------------|
| `paper_id` | VARCHAR | Links to papers table |
| `round` | INTEGER | Iteration number (1, 2, 3, ...) |
| `replicator1` | VARCHAR | Primary replicator email |
| `replicator2` | VARCHAR | Optional secondary replicator email |
| `hours1` | NUMERIC | Hours spent by replicator1 |
| `hours2` | NUMERIC | Hours spent by replicator2 |
| `is_success` | BOOLEAN | Replication successful? |
| `software` | VARCHAR | Software requirements |
| `is_confidential` | BOOLEAN | Contains confidential data? |
| `is_confidential_shared` | BOOLEAN | Confidential data was shared? |
| `is_remote` | BOOLEAN | Remote replication performed? |
| `is_HPC` | BOOLEAN | HPC required? |
| `runtime_code_hours` | NUMERIC | Total runtime in hours |
| `data_statement` | VARCHAR | Data availability statement |
| `repl_comments` | VARCHAR | Replicator's comments |
| `date_with_authors` | DATE | When sent to authors |
| `date_arrived_from_authors` | DATE | When package received |
| `date_assigned_repl` | DATE | When assigned to replicator |
| `date_completed_repl` | DATE | When replicator finished |
| `date_decision_de` | DATE | When DE made decision |
| `decision_de` | VARCHAR | DE's decision (accept/rnr) |
| `file_request_id_pkg` | VARCHAR | File request ID for this round |
| `file_request_id_paper` | VARCHAR | Paper file request ID |
| `file_request_url_pkg` | VARCHAR | Package file request URL |
| `file_request_url_paper` | VARCHAR | Paper file request URL |
| `github_url` | VARCHAR | GitHub repo URL |
| `gh_org_repo` | VARCHAR | GitHub org/repo |

**Primary Key**: (`paper_id`, `round`)

#### `reports` Table

Temporary staging table for reports from Google Forms:

| Column | Type | Description |
|--------|------|-------------|
| `paper_id` | VARCHAR | Paper identifier |
| `round` | INTEGER | Round number |
| `timestamp` | TIMESTAMP | Report submission time |
| `email_of_replicator_1` | VARCHAR | Primary replicator email |
| `email_of_replicator_2` | VARCHAR | Secondary replicator email |
| `hours_replicator_1` | NUMERIC | Hours worked |
| `hours_replicator_2` | NUMERIC | Hours worked |
| `is_success` | BOOLEAN | Success status |
| `software_used_in_package` | VARCHAR | Software list |
| `is_confidential` | BOOLEAN | Confidential data present |
| `shared_confidential` | BOOLEAN | Was it shared |
| `is_remote` | BOOLEAN | Remote replication |
| `is_HPC` | BOOLEAN | HPC used |
| `running_time_of_code` | NUMERIC | Runtime hours |
| `data_statement` | VARCHAR | Data statement |
| `comments` | VARCHAR | Replicator comments |

**Primary Key**: (`paper_id`, `round`)

Reports are processed into `iterations` table and then typically removed from `reports`.

#### `form_arrivals` Table

Staging table for new arrivals from Google Forms:

| Column | Type | Description |
|--------|------|-------------|
| `timestamp` | TIMESTAMP | Form submission time |
| `journal` | VARCHAR | Journal name |
| `paper_id` | VARCHAR | Paper ID |
| `title` | VARCHAR | Paper title |
| `firstname_of_author` | VARCHAR | Author first name |
| `surname_of_author` | VARCHAR | Author surname |
| `email_of_author` | VARCHAR | Author email |
| `email_of_second_author` | VARCHAR | Second author email |
| `handling_editor` | VARCHAR | Editor name |
| `is_confidential` | BOOLEAN | Confidential data flag |
| `share_confidential` | BOOLEAN | Willing to share |
| `comments` | VARCHAR | Additional comments |
| `paper_slug` | VARCHAR | URL-safe slug |
| `processed` | BOOLEAN | Has been processed? |

### Paper Statuses

Papers move through these statuses:

| Status | Description | Who Has Action |
|--------|-------------|----------------|
| `new_arrival` | Just submitted, file request sent | Author |
| `with_author` | Awaiting package submission from author | Author |
| `author_back_de` | Package received, awaiting preprocessing/assignment | Data Editor |
| `with_replicator` | Assigned to replicator, replication in progress | Replicator |
| `replicator_back_de` | Report received, awaiting DE decision | Data Editor |
| `acceptable_package` | Accepted, ready for publication | Journal Office |
| `published_package` | Published to Dataverse | None (complete) |

### Transaction Safety

All database operations use transactions to ensure data integrity:

```julia
# Robust transaction wrapper
robust_db_operation() do con
    # Multiple operations within transaction
    DBInterface.execute(con, "UPDATE ...")
    DBInterface.execute(con, "INSERT ...")
    # Automatically commits on success, rolls back on error
end
```

Key safety features:
- Automatic rollback on errors
- Connection pooling with locks
- Backup functions before critical operations
- Status validation before transitions

---

## Key Operations

### Daily Operations

#### Check Status of All Papers
```julia
using JPE

# Display all papers with color-coded status
ps()
```

This shows a table with:
- Paper slug
- Current round
- Status
- Days in current status (color-coded: green < 3 days, yellow 3-10 days, red > 10 days)

#### Process New Arrivals
```julia
# Read Google Form and create database entries
google_arrivals()
```

#### Check for Package Arrivals
```julia
# Monitor Dropbox file requests
results = monitor_file_requests()

# Shows:
# - results[:arrived]: packages that have arrived
# - results[:waiting]: still waiting
# - results[:remindJO]: need paper from JO
```

#### Dispatch Arrived Packages
```julia
# Process all packages that have arrived
dispatch()

# This will:
# 1. Run preprocessing for each package
# 2. Assign to replicator
# 3. Update status
```

#### Collect Replicator Reports
```julia
# Read reports from Google Form
collect_reports()
```

#### Process Reports and Make Decisions
```julia
# Interactive workflow
de_process_waiting_reports()

# For each waiting report:
# 1. Displays summary
# 2. Prompts for decision (accept/revise)
# 3. Executes decision workflow
```

### Paper-Specific Operations

#### View Paper Details
```julia
# Get paper information
paper = db_filter_paper("12345678")

# Get all iterations
iterations = db_filter_iteration("12345678")

# Get specific iteration
iter = db_filter_iteration("12345678", 2)  # round 2

# Generate detailed report
paper_report("12345678")
```

#### Manual Status Updates
```julia
# Update status (use with caution)
db_update_status("12345678", "with_replicator")

# Validate status is consistent with data
valid, issues = validate_paper_status("12345678")

# Repair status if needed
success, old, new, msg = set_status!("12345678")
```

#### Preprocess a Package
```julia
# Preprocess specific paper (current round)
preprocess2("12345678")

# Preprocess specific round
preprocess2("12345678", which_round=1)
```

#### Assign to Replicator
```julia
# Interactive assignment
assign("12345678")
```

#### Make Decision
```julia
# Accept package
de_make_decision("12345678", "accept")

# Request revisions
de_make_decision("12345678", "revise")
```

### Reporting Operations

#### Replicator Workload
```julia
# Display current workload
replicator_workload_report()

# Update Google Sheet with workloads
replicator_workload_report(update_gsheet=true)

# Save to CSV
replicator_workload_report(save_csv=true, csv_path="workload.csv")
```

#### Global Statistics
```julia
# Overall statistics
global_report()

# Save to CSV
global_report(save_csv=true)
```

#### Time in Status
```julia
# Average time papers spend in each status
time_in_status_report()
```

#### Replicator Billing
```julia
# Generate billing report for replicators
hours, summary = replicator_billing(
    test_max_hours = 1.5,  # Cap test cases at 1.5 hours
    rate = 25.0,           # EUR per hour
    email = true,          # Send invoices
    write_gs = true,       # Update Google Sheet
    EUR2USD = 1.18        # Exchange rate
)
```

### Administrative Operations

#### Database Backups
```julia
# Create timestamped backup
db_bk_create()

# Read backup
backup_data = db_read_backup("papers")

# Write manual backup
db_write_backup("papers", dataframe)
```

#### Delete Test Entries
```julia
# Delete all entries marked [TEST]
results = db_delete_test()

# Delete specific paper
results = db_delete_paper("12345678")
```

#### Check Database Integrity
```julia
# Check for corruption or inconsistencies
issues = check_db_integrity()

# Attempt repair from backups
repairs = repair_db_from_backups()
```

---

## Preprocessing Deep Dive

Preprocessing is the step where a submitted replication package is analyzed by **PackageScanner.jl** to extract metadata about:
- Directory structure
- Data files and their sizes
- Code files and programming languages
- Documentation files
- Potential PII (personally identifiable information)
- README quality

### Preprocessing Locations

Preprocessing can run in two locations:

1. **Local** (on your Mac where Dropbox sync works)
2. **Remote** (on GitHub Actions runner, typically macOS)

### The Dropbox "Online Only" Challenge

**Problem**: On macOS with Dropbox "Files On-Demand" feature, files appear in the filesystem but aren't actually downloaded locally. They're "stubs" that trigger downloads when accessed. However, **programmatic access doesn't reliably trigger downloads**, especially in:
- Automated scripts
- Batch operations
- GitHub Actions runners

**Symptoms**:
- `filesize()` returns 0 for undownloaded files
- `open()` may fail or hang
- `readdir()` shows files that can't be read

### Current Workaround (Imperfect)

The current `runner_precheck.jl` attempts to force downloads:

```julia
function force_download_directory(dirpath)
    for (root, dirs, files) in walkdir(dirpath)
        for file in files
            filepath = joinpath(root, file)
            # Try to trigger download by reading file
            try
                open(filepath, "r") do io
                    while !eof(io)
                        read(io, min(1024*1024, bytesavailable(io)))
                    end
                end
            catch e
                @warn "Could not read file" filepath exception=e
            end
        end
    end
end
```

**This doesn't work reliably** because:
- Dropbox File Provider may not materialize stubs on programmatic read
- Race conditions between read and download
- No reliable way to detect download completion
- Batch operations may timeout

### Preprocessing Workflow Details

When you run `preprocess2(paperID)`:

1. **Setup Phase** (local machine):
   ```julia
   # Get paper and iteration info
   p = db_filter_paper(paperID)
   rt = db_filter_iteration(paperID, round)
   
   # Create temp directory
   repoloc = joinpath(tempdir(), "$(paperID)-$(round)")
   
   # Clone GitHub repo for this round
   gh_clone_branch(r.gh_org_repo, "round$(round)", to=repoloc)
   ```

2. **Check Package Size**:
   ```julia
   # Query Dropbox API for folder size
   size_gb = dbox_get_folder_size(dropbox_path)
   
   # Prompt for size thresholds
   # max_file_size_gb: ignore files larger than this in zips
   # max_pkg_size_gb: if package > this, use partial extraction
   ```

3. **Create Configuration** (`_variables.yml`):
   ```yaml
   title: "Paper Title"
   author: "Surname"
   round: 1
   repo: "https://github.com/JPE-Reproducibility/JPE-Surname-12345678"
   paper_id: 12345678
   journal: "JPE"
   paper_slug: "Surname-12345678"
   dropbox_rel_path: "JPE/Surname-12345678/1"
   package_size_gb: 45.2
   package_max_file_size_gb: 2.0
   package_max_pkg_size_gb: 10.0
   ```

4. **Create Runner Script** (`runner_precheck.jl`):
   - Constructs full Dropbox path from relative path
   - Attempts to force download all files
   - Copies package to workspace
   - Unzips files (respecting size limits)
   - Runs PackageScanner.precheck_package()
   - Commits results to GitHub

5. **Choose Execution Location**:
   - **Local**: Runs immediately in new Julia process
   - **Remote**: Commits `_variables.yml` and `runner_precheck.jl`, GitHub Actions triggers

6. **Cleanup**:
   - Deletes local temp directory
   - Results remain in GitHub repo

### Package Size Considerations

JPE.jl handles packages of various sizes:

**Small packages** (< 10 GB):
- Full extraction of all zips
- Complete scanning of all files
- Works well locally and remotely

**Large packages** (10-100+ GB):
- Partial extraction mode
- Only unzip files < threshold size
- Catalog large zip contents without extraction
- Generate manifest of files
- **Challenge**: Getting 100GB from Dropbox to remote runner

### Local vs. Remote Preprocessing

**Local Preprocessing** (on your Mac):

✅ **Advantages:**
- Dropbox sync works reliably
- Full access to all files
- Can handle any package size
- Immediate execution
- Easy to debug

❌ **Disadvantages:**
- Ties up your machine
- Limited to your Mac's resources
- Can't run overnight if you're away

**Remote Preprocessing** (GitHub Actions):

✅ **Advantages:**
- Doesn't tie up your machine
- Dedicated compute resources
- Can run while you sleep
- Scalable (multiple papers in parallel)
- Reproducible environment

❌ **Disadvantages:**
- **Dropbox access is unreliable** (the core problem)
- Package size limits (100GB packages problematic)
- Slower startup time
- More complex debugging

### Proposed Solutions for Remote Preprocessing

#### Solution 1: Password-Protected Dropbox Links (Recommended)

**Status**: Ready for implementation (see `PROPOSAL.md` for full details)

**Concept**: Instead of relying on Dropbox sync, download directly via HTTP using password-protected shared links.

**Key Features**:
- Each paper gets unique password: `DROPBOX_PASSWORD_{paperID}_R{round}`
- Password used by both runner (via GitHub secret) and replicator (via Slack)
- Safe for public repos (GitHub Secrets are encrypted even in public repos)
- Works with any package size (100GB+)

**Workflow**:

1. **During `preprocess2()` setup** (local Mac):
   ```julia
   # Generate unique password for this paper and round
   password = randstring(['a':'z'; 'A':'Z'; '0':'9'; '!'; '@'; '#'; '%'], 16)
   
   # Create password-protected Dropbox link via API
   link = dbox_create_password_link(dropbox_path, password, dbox_token)
   
   # Create unique secret name
   secret_name = "DROPBOX_PASSWORD_$(paperID)_R$(round)"
   
   # Store in _variables.yml (PUBLIC in repo)
   dropbox_download_url: "https://www.dropbox.com/sh/xxx?dl=1"
   dropbox_password_secret: "DROPBOX_PASSWORD_12345678_R1"
   
   # Display instructions
   println("Password: $password")
   println("1. Share with REPLICATOR via Slack")
   println("2. Add as GitHub secret:")
   println("   gh secret set $secret_name --body \"$password\" --repo $org_repo")
   ```

2. **For GitHub Actions runner** (self-hosted):
   ```julia
   # runner_precheck.jl reads dynamic secret name
   url = vars["dropbox_download_url"]
   secret_name = vars["dropbox_password_secret"]  # e.g., "DROPBOX_PASSWORD_12345678_R1"
   password = ENV[secret_name]  # Injected by GitHub Actions
   
   # Simple authenticated download - no Dropbox app needed!
   run(`curl -L -o package.zip "$url" -u :$password`)
   run(`unzip -q package.zip -d replication-package/`)
   ```

3. **For human replicator**:
   - Receives same password via Slack (secure channel)
   - Downloads from same Dropbox link
   - Can work on package locally

**Security Model**:

Even though repos are **public** (`--public` flag for pricing reasons):

✅ **GitHub Secrets are safe**:
- Encrypted at rest on GitHub servers
- Never visible in repo files or commit history
- Not visible to repo visitors or even admins
- Only accessible to GitHub Actions workflows as environment variables
- Same security as private repos

✅ **Two-factor security**:
- Link URL (public in repo + email to replicator)
- Password (GitHub secret for runner + Slack for replicator)
- Both required to download files

✅ **Per-paper isolation**:
- Each paper has unique password
- Compromising one doesn't affect others
- Can revoke individual links

**Benefits**:
- ✅ No size limits (Dropbox handles 100GB+ files)
- ✅ No Dropbox app needed on runner
- ✅ No token expiration issues
- ✅ Secure for public repos and confidential data
- ✅ Two users: runner (automated) + replicator (manual)
- ✅ Different communication channels (repo/email for link, Slack for password)
- ✅ No JPE.jl dependency on runner
- ✅ Works with self-hosted runners

**Implementation Status**:
- Complete implementation plan in `PROPOSAL.md`
- Python functions: Ready to implement
- Julia wrappers: Ready to implement
- Modified `preprocess2()`: Ready to implement
- Simplified `runner_precheck.jl`: Ready to implement

See `PROPOSAL.md` for complete implementation details, testing plan, and rollout strategy.

#### Solution 2: Hybrid Local/Remote

**For large or confidential packages**: Run locally
**For small non-confidential packages**: Run remotely with current approach

This is already partially implemented via the interactive prompt in `preprocess2()`.

---

## Security Model

### Confidential Data Handling

JPE.jl handles packages containing confidential data (e.g., administrative records, tax data, health records) with appropriate security controls.

#### Confidentiality Tracking

Papers are marked as confidential via:
```julia
# In database
paper.is_confidential = true          # Contains confidential data
paper.share_confidential = true       # Author agreed to share with DE
```

This information comes from the initial Google Form submission.

#### Access Control Layers

1. **GitHub Repository Access**
   - All repos are **private** by default
   - Only JPE-Reproducibility organization members can access
   - Replicators added as collaborators on assignment

2. **Dropbox File Requests**
   - Separate file requests per paper per round
   - Links are unguessable (random tokens)
   - Can be revoked after download

3. **Email Security**
   - Gmail API with OAuth2 authentication
   - TLS encryption in transit
   - Links sent via email, passwords via Slack (two channels)

4. **Replicator Agreements**
   - All replicators sign confidentiality agreements
   - Tracked in replicators Google Sheet
   - Can lose access if agreement expires

#### Confidential Data Best Practices

**For confidential packages**:
1. Mark package as confidential in Google Form
2. Consider password-protected Dropbox links (future implementation)
3. Delete Dropbox copy after publication
4. Verify replicator has current confidentiality agreement
5. Use separate secure channel for sensitive communications (Slack)

**After publication**:
```julia
# Delete Dropbox materials for published paper
delete_dropbox_paper("12345678", dryrun=false)

# Preserve certain directories
# - "preserve" directories kept
# - "thirdparty" directories kept
# - Everything else deleted
```

### Data Protection

#### Personal Information in Code

PackageScanner.jl scans for potential PII:
- Email addresses
- Phone numbers
- Names in comments
- Location data (lat/long coordinates)

These are flagged in the pre-check report for replicator review.

#### Backup Strategy

Regular backups protect against:
- Database corruption
- Accidental deletions
- Data integrity issues

```julia
# Automated backup before critical operations
db_write_backup("papers", db_df("papers"))

# Manual backup
db_bk_create()  # Creates timestamped backup

# Restore from backup
backup = db_read_backup("papers")
```

Backups are CSV files stored in `$JPE_DB/` directory.

---

## Setup & Configuration

### Environment Variables

Required environment variables:

```bash
# Database location
export JPE_DB="/path/to/duckdb/directory"

# Tools package location  
export JPE_TOOLS_JL="/path/to/JPEtools.jl"

# Google API credentials
export JPE_GOOGLE_KEY="/path/to/google-credentials.json"

# Dropbox Apps folder
export JPE_DBOX_APPS="/Users/you/Dropbox/Apps/JPE-packages"

# Dropbox app credentials
export JPE_DBOX_APP_SECRET="your-app-secret"
export JPE_DBOX_APP_REFRESH="your-refresh-token"

# Dataverse token (for publication)
export JPE_DV="your-dataverse-token"

# Julia runner environment (for local preprocessing)
export JULIA_RUNNER_ENV="/path/to/runner/environment"
```

### Python Installation

JPE.jl uses Python for Dropbox and Gmail APIs.

**Using pyenv** (recommended):

```bash
# Install pyenv
brew install pyenv
brew install pyenv-virtualenv

# Set up shell (add to ~/.config/fish/config.fish or ~/.zshrc)
# See: https://github.com/pyenv/pyenv#set-up-your-shell-environment-for-pyenv

# Install Python with framework support (needed for PyCall)
env PYTHON_CONFIGURE_OPTS="--enable-framework" pyenv install 3.13.5

# Create virtual environment in JPE.jl directory
cd /path/to/JPE.jl
pyenv virtualenv 3.13.5 jpe-env

# Activate and install dependencies
pyenv activate jpe-env
pip install -r requirements.txt
```

### Julia Installation

**PyCall Configuration**:

PyCall.jl must use the pyenv Python:

```julia
# In Julia REPL, before using JPE
ENV["PYTHON"] = "/Users/yourname/.pyenv/shims/python"

# Then rebuild PyCall
using Pkg
Pkg.build("PyCall")
```

**Install JPE.jl**:

```julia
using Pkg

# Development mode (for active development)
Pkg.develop(path="/path/to/JPE.jl")

# Or add normally
Pkg.add(url="https://github.com/JPE-Reproducibility/JPE.jl")
```

### Google API Setup

1. Create Google Cloud Project
2. Enable Google Sheets API and Gmail API
3. Create OAuth 2.0 credentials
4. Download credentials JSON
5. Set `JPE_GOOGLE_KEY` to JSON file path

**First-time authentication**:
```julia
using JPE
gs4_auth()  # Opens browser for OAuth flow
```

Credentials cached in `~/.config/googlesheets4/`.

### Dropbox API Setup

1. Create Dropbox App at https://www.dropbox.com/developers/apps
2. Get App key and App secret
3. Generate refresh token using `python-token-getters/get_dbox_token.py`
4. Set environment variables

**Generate refresh token**:
```bash
cd python-token-getters
python get_dbox_token.py
```

Follow OAuth flow and save the refresh token.

### GitHub CLI Setup

JPE.jl uses GitHub CLI (`gh`) extensively:

```bash
# Install
brew install gh

# Authenticate
gh auth login

# Verify access to JPE-Reproducibility org
gh repo list JPE-Reproducibility
```

### First-Time Setup Checklist

- [ ] Install Python with pyenv
- [ ] Create virtual environment
- [ ] Install Python requirements
- [ ] Configure Julia PyCall to use correct Python
- [ ] Set all environment variables
- [ ] Authenticate Google APIs
- [ ] Generate Dropbox tokens
- [ ] Authenticate GitHub CLI
- [ ] Initialize DuckDB database
- [ ] Test with a test case

**Initialize database**:
```julia
using JPE

# Database will be created automatically on first use
# Check it exists:
db_show()  # Should show: papers, iterations, reports, form_arrivals
```

---

## API Reference

### Database Functions (`db.jl`)

#### Connection Management
```julia
with_db(f::Function)           # Execute function with DB connection
robust_db_operation(f::Function)  # Execute in transaction with rollback
db_release_connection()        # Close connection
db_reconnect()                 # Reopen connection
```

#### Querying
```julia
db_df(table::String)           # Get entire table as DataFrame
db_filter_paper(id)            # Get paper by ID
db_filter_iteration(id, round) # Get specific iteration
db_filter_status(status)       # Get all papers with status
```

#### Updating
```julia
db_update_status(paperID, status)                # Update paper status
update_paper_status(f, paperID, from, to)        # Status update with transaction
db_update_cell(table, where, var, val)           # Update single cell
```

#### Integrity
```julia
validate_paper_status(paperID)                   # Check status consistency
set_status!(paperID; force_status=nothing)       # Fix status
check_db_integrity()                             # Full integrity check
```

### Google Integration (`google.jl`)

```julia
gs4_auth()                                       # Authenticate
google_arrivals()                                # Process new arrivals
read_google_reports()                            # Read replicator reports
read_replicators()                               # Get replicator list
```

### Dropbox Operations (`dropbox.jl`)

```julia
dbox_set_token()                                 # Refresh access token
dbox_link_at_path(path, token)                  # Get public link
dbox_create_file_request(dest, title, token)    # Create file request
dbox_fr_arrived(token, id)                      # Check if files uploaded
dbox_get_folder_size(path)                      # Get size in GB
```

### GitHub Operations (`github.jl`)

```julia
gh_create_repo(org_repo)                        # Create from template
gh_clone_branch(url, branch; to=nothing)        # Clone specific branch
gh_create_branch_on_github_from(url, from, to)  # Create new branch
gh_delete_repo(url)                             # Delete repository
gh_pull(paper_id)                               # Pull repo for editing
```

### Workflow Actions (`actions.jl`)

```julia
dispatch()                                       # Process arrived packages
assign(paperID)                                  # Assign to replicator
collect_reports()                                # Ingest replicator reports
de_process_waiting_reports()                    # Interactive decision workflow
de_make_decision(paperID, decision)             # Accept or revise
finalize_publication(paperID, DOI)              # Publish to Dataverse
monitor_file_requests()                         # Check Dropbox arrivals
```

### Preprocessing (`preprocess.jl`)

```julia
preprocess2(paperID; which_round=nothing,       # Main preprocessing function
            max_pkg_size_gb=10, 
            max_file_size_gb=2)
```

### Reporting (`reporting.jl`)

```julia
ps()                                            # Status table (all papers)
global_report()                                 # Global statistics
paper_report(paperID)                           # Detailed paper report
replicator_workload_report()                    # Current workloads
time_in_status_report()                         # Average times per status
replicator_billing(; rate=25.0, email=false)   # Generate billing
replicator_history(; email=nothing)             # Replicator's past work
```

---

## Troubleshooting

### Common Issues

#### Database Connection Errors

**Symptom**: "Database connection not open" or "connection already closed"

**Solution**:
```julia
# Release stale connection
db_release_connection()

# Reconnect
db_reconnect()

# Check status
db_connection_status()
```

#### Google Authentication Fails

**Symptom**: OAuth redirect fails or token expired

**Solution**:
```bash
# Delete cached credentials
rm -rf ~/.config/googlesheets4/

# Re-authenticate
```
```julia
using JPE
gs4_auth()  # Will open browser
```

#### Dropbox Token Expired

**Symptom**: "Invalid access token" errors

**Solution**:
```julia
# Refresh token (happens automatically)
dbox_set_token()

# Or manually check
dbox_get_user(dbox_token)  # Should return user info
```

If refresh fails, regenerate refresh token:
```bash
cd python-token-getters
python get_dbox_token.py
```

#### Python Import Errors

**Symptom**: "PyError" or "ModuleNotFoundError"

**Solution**:
```bash
# Verify pyenv environment
pyenv which python

# Verify packages installed
pip list | grep dropbox
pip list | grep google-auth
```

In Julia:
```julia
# Check Python location
ENV["PYTHON"]

# Rebuild PyCall
using Pkg
Pkg.build("PyCall")
```

#### GitHub Permission Denied

**Symptom**: Can't create/delete repos

**Solution**:
```bash
# Check authentication
gh auth status

# Verify org access
gh auth refresh -s admin:org

# Check permissions
gh api /user/memberships/orgs/JPE-Reproducibility
```

#### Dropbox Files Not Downloading (macOS)

**Symptom**: Files show 0 bytes, `open()` fails

**Solutions**:

1. **Manual sync** before running preprocessing:
   ```bash
   # In Finder, right-click folder → "Make Available Offline"
   ```

2. **Use Dropbox API download** (future implementation):
   - See [Preprocessing Deep Dive](#preprocessing-deep-dive)

3. **Disable Files On-Demand**:
   ```
   Dropbox Preferences → Sync → 
   Uncheck "Save hard drive space automatically"
   ```
   (Warning: Downloads ALL Dropbox files!)

#### Package Size Too Large

**Symptom**: GitHub times out, preprocessing fails

**Solutions**:

1. **Increase size thresholds**:
   ```julia
   preprocess2(paperID, max_file_size_gb=5, max_pkg_size_gb=20)
   ```

2. **Run locally instead of remote**:
   - Choose "local" when prompted during `preprocess2()`

3. **Use partial extraction mode**:
   - Automatically triggered for packages > `max_pkg_size_gb`

### Debug Mode

Enable verbose output:

```julia
# In JPE.jl code, use @debug statements
# Run Julia with debug level:
ENV["JULIA_DEBUG"] = "JPE"
```

### Getting Help

1. **Check logs**: Look at terminal output carefully
2. **Verify environment variables**: `println(ENV["JPE_DB"])`, etc.
3. **Check database state**: `ps()`, `db_show()`
4. **Validate specific paper**: `validate_paper_status(paperID)`
5. **Create issue**: https://github.com/JPE-Reproducibility/JPE.jl/issues

### Recovery Procedures

#### Restore from Backup

```julia
# List available backups
readdir(JPE_DB)  # Look for CSV files

# Restore papers table
backup = CSV.read(joinpath(JPE_DB, "papers.csv"), DataFrame)

# Verify before writing
nrow(backup)
names(backup)

# Write back to database (CAREFUL!)
robust_db_operation() do con
    DuckDB.register_data_frame(con, backup, "backup")
    DBInterface.execute(con, "DELETE FROM papers")
    DBInterface.execute(con, "INSERT INTO papers SELECT * FROM backup")
end
```

#### Fix Corrupted Status

```julia
# Check status
valid, issues = validate_paper_status("12345678")

# Auto-fix
success, old_status, new_status, msg = set_status!("12345678")

# Or force specific status
set_status!("12345678", force_status="with_author")
```

#### Manually Update Paper

```julia
# Direct database update (use with caution)
with_db() do con
    DBInterface.execute(con, """
        UPDATE papers 
        SET status = 'author_back_de',
            date_with_authors = '2024-01-15'
        WHERE paper_id = '12345678'
    """)
end
```
