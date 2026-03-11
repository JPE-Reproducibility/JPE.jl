# JPE.jl - Developer Documentation

## Project Structure

```
JPE.jl/
├── src/
│   ├── JPE.jl              # Main module, initialization, exports
│   ├── db.jl               # Database operations (DuckDB)
│   ├── google.jl           # Google Sheets/Forms integration (via R)
│   ├── dropbox.jl          # Dropbox API operations (via Python)
│   ├── actions.jl          # High-level workflow orchestration
│   ├── preprocess.jl       # Preprocessing setup and coordination
│   ├── github.jl           # GitHub operations (via gh CLI)
│   ├── gmailing.jl         # Email templates and sending
│   ├── reporting.jl        # Status reports, billing, dashboards
│   ├── dataverse.jl        # Dataverse publication
│   ├── snippets.jl         # Utility functions, helpers
│   ├── zip.jl              # Zip file operations
│   ├── db_backups.jl       # Database backup operations
│   ├── db_filerequests.py  # Python: Dropbox file requests
│   ├── gmail_client.py     # Python: Gmail API client
│   └── url_from_commit.yaml # Config for URL generation
├── python-token-getters/   # OAuth token generation scripts
│   ├── get_dbox_token.py   # Dropbox OAuth
│   └── get_gmail_tokens.py # Gmail OAuth
├── test/
│   ├── runtests.jl
│   ├── test_dropbox.jl
│   └── test_duck.jl
├── database.md             # Database schema documentation
├── README.md               # User-facing documentation
├── LLM.md                  # Terse architecture for LLMs
└── DEVELOPERS.md           # This file

```

## Module Architecture

### JPE.jl (Main Module)

**Location**: `src/JPE.jl`

**Purpose**: Entry point, initialization, module composition

**Key Components**:
```julia
# Global state
global dbox_token = ""  # Dropbox access token (refreshed periodically)

# Constants
const JPE_DB          # Database directory path
const DB_PATH         # Full path to jpe.duckdb
const DB_LOCK         # ReentrantLock for connection safety
const DB_CONNECTION   # Ref to persistent connection

# Initialization
function __init__()
    # Load Python modules
    @pyinclude(joinpath(@__DIR__,"db_filerequests.py"))
    @pyinclude(joinpath(@__DIR__,"gmail_client.py"))
    
    # Refresh Dropbox token
    dbox_set_token()
    
    # Show logo and status
    show_logo()
    ps()  # Print status table
end
```

**Exports**:
- `ps` - Print status table
- `db_df`, `db_filter_paper` - Database helpers

### db.jl (Database Layer)

**Purpose**: All database operations, connection management, transactions

**Connection Management**:
```julia
# Thread-safe connection handling
with_db(f::Function)
    # Locks DB_LOCK
    # Ensures connection is open
    # Executes f(connection)
    # Returns result

# Transaction wrapper with automatic rollback
robust_db_operation(f::Function)
    with_db() do con
        DBInterface.execute(con, "BEGIN TRANSACTION")
        try
            result = f(con)
            DBInterface.execute(con, "COMMIT")
            return result
        catch e
            DBInterface.execute(con, "ROLLBACK")
            rethrow(e)
        end
    end
```

**CRUD Operations**:
```julia
# Read
db_df(table::String) -> DataFrame
    # Returns entire table as DataFrame

db_filter_paper(id) -> DataFrame
    # Returns single paper by ID

db_filter_iteration(id, round=nothing) -> DataFrame
    # Returns iteration(s) for paper

db_filter_status(status1::String, status2::String=nothing) -> DataFrame
    # Returns papers with given status(es)

db_df_where(table::String, where_col::String, where_val) -> DataFrame
    # Generic WHERE query

# Update
db_update_status(paperID, status)
    # Simple status update

update_paper_status(f::Function, paperID, from_status, to_status; do_update=true)
    # Transactional status update with validation
    # f(con) executed within transaction
    # Validates current status matches from_status
    # Updates to to_status only if f succeeds

db_update_cell(table, whereclause, var, val)
    # Update single cell

# Delete
db_delete_where(table, where_col(s), where_val(s))
    # DELETE with WHERE clause

db_delete_paper(id) -> DataFrame
    # Safely delete paper with backups and validation
    # Returns operation log

db_delete_test() -> DataFrame
    # Delete all [TEST] entries
    # Returns operation log

# Create/Insert
db_append_new_df(table, row_hash_var, df) -> DataFrame|Nothing
    # Append only new rows (based on key column(s))
    # Creates table if doesn't exist
    # Returns new rows or nothing

db_append_new_row(table, key_column, row) -> DataFrameRow|Nothing
    # Append single row if key doesn't exist
    # Returns row if added, nothing if duplicate
```

**Status Management**:
```julia
db_statuses() = [
    "new_arrival",
    "with_replicator",
    "replicator_back_de",
    "author_back_de",
    "with_author",
    "acceptable_package",
    "published_package"
]

validate_paper_status(paperID) -> (Bool, Vector{String})
    # Check if status consistent with iteration data
    # Returns (is_valid, list_of_issues)

set_status!(paperID; force_status=nothing, verbose=true)
    # Auto-repair status based on iteration dates
    # Or force to specific status
    # Returns (success, old_status, new_status, message)
```

**Schema Management**:
```julia
db_get_table_schema(table::String) -> Dict
    # Returns schema definition for table
    # Hardcoded schemas for: papers, iterations, reports, form_arrivals

db_ensure_table_exists(table; verbose=true) -> Bool
    # Create table if missing
    # Returns true if created, false if existed

db_add_missing_columns(table; verbose=true) -> Vector{String}
    # Add any columns from schema not in table
    # Returns list of added columns
```

**Backup Functions**:
```julia
db_write_backup(table, dataframe)
    # Write CSV backup to $JPE_DB/{table}.csv

db_read_backup(table) -> DataFrame
    # Read CSV backup

check_db_integrity() -> DataFrame
    # Check for missing tables, orphaned records, inconsistencies
    # Returns DataFrame of issues

repair_db_from_backups() -> DataFrame
    # Attempt to restore from CSV backups
    # Returns DataFrame of repair operations
```

### google.jl (Google Integration)

**Purpose**: Read/write Google Sheets and Forms via R's googlesheets4 package

**Authentication**:
```julia
gs4_auth()
    # Calls R googlesheets4::gs4_auth()
    # Uses cached credentials from ~/.config/googlesheets4/

# Sheet IDs (hardcoded)
gs_replicators_id() = "1QtmmBMEhq5BcoJqMy-FeVrbcsseI7rA_NEjXH94UtV0"
gs_arrivals_id() = "1tmOuid7s7fMhj7oAG_YNHAjRd7bmr7YDM5QKLF6LXys"
gs_DAS_id() = "1VE2t7Ia2UCWPpcIOAcqBqGH9Q8X1LHGFk7uUrcCqMbg"
gs_reports_id() = "1R74dGMJ2UAfSSVCmjSQLo-qflGRXvNnDGD9ZCEebtTw"
```

**Reading Forms**:
```julia
read_google_arrivals() -> DataFrame|Nothing
    # Read new arrivals from DAS sheet
    # Clean/normalize data
    # Append to form_arrivals table
    # Returns new rows or nothing

read_google_reports(; append=true) -> DataFrame|Nothing
    # Read replicator reports from form
    # Append to reports table if append=true
    # Returns new rows or nothing

read_replicators() -> DataFrame
    # Read confirmed replicators list
    # Returns DataFrame with name, email, OS, availability
```

**Writing Sheets**:
```julia
gs4_write_replicator_load(workload_df)
    # Update current_workload column in replicators sheet
    # Called by replicator_workload_report()

replicator_assignments(; update_gs=true)
    # Write current assignments to tracking sheet
    # Includes formula for days_with_repl calculation
```

**Data Processing**:
```julia
google_arrivals() -> DataFrame
    # Main arrival processing function
    # 1. Read from Google Form
    # 2. For each new arrival:
    #    - Setup Dropbox structure
    #    - Create GitHub repo
    #    - Send file request email
    #    - Add to database
    # Returns processed papers

prepare_arrivals_for_db(df) -> DataFrame
    # Transform Google Form data to database schema
    # Add default values for missing columns
    # Parse booleans, dates, clean strings
```

### dropbox.jl (Dropbox Integration)

**Purpose**: Dropbox API operations via Python

**Token Management**:
```julia
dbox_refresh_token() -> String
    # Call Python refresh_token()
    # Uses JPE_DBOX_APP_SECRET and JPE_DBOX_APP_REFRESH
    # Returns new access token (valid ~30 min)

dbox_set_token()
    # Refresh and set global dbox_token
    # Called in __init__() and on errors
```

**File Requests**:
```julia
dbox_create_file_request(dest, title, token) -> Dict
    # Python: create_file_request(token, title, dest)
    # Returns: {id, url, title, destination, ...}

dbox_fr_exists(token, dest) -> Bool
    # Check if file request exists at path

dbox_fr_arrived(token, id) -> Dict
    # Check submission status
    # Returns: {file_count, ...}

dbox_fr_submit_time(token, dest) -> DateTime|Nothing
    # Get submission timestamp
```

**Links**:
```julia
dbox_link_at_path(path, token) -> String
    # Create/get shared link for path
    # Retries with token refresh on failure
    # Returns download URL

# Future: password-protected links
dbox_create_password_link(path, password, token) -> Dict
    # NOT YET IMPLEMENTED
    # Would create password-protected shared link
```

**Folder Operations**:
```julia
dbox_get_folder_size(path) -> Float64
    # Use Dropbox API to recursively list folder
    # Sum file sizes
    # Returns size in GB
    # Handles pagination for large folders

dbox_check_fr_pkg(journal, paperid, author, round) -> Vector{String}
    # List contents of replication-package folder
    # Returns readdir() of Dropbox path
```

**File Download Helpers** (unreliable on macOS):
```julia
is_placeholder(filepath) -> Bool
    # Check for com.apple.fileprovider.stubbed xattr
    # macOS-specific

dbox_ensure_downloaded(filepath)
    # Attempt to force download by reading file
    # NOT RELIABLE - see Dropbox "Online Only" problem
```

### github.jl (GitHub Operations)

**Purpose**: GitHub repository and branch management via `gh` CLI

**Repository Management**:
```julia
gh_create_repo(gh_org_repo)
    # gh repo create {org}/{name} --public --template JPE-Reproducibility/JPEtemplate

gh_delete_repo(url)
    # gh repo delete {url} --yes

gh_repo_exists(repo::String) -> Bool
    # gh api repos/{repo} --jq .id
    # Returns true if exists, false if 404
```

**Branch Operations**:
```julia
gh_clone_branch(gh_url, branch; to=nothing)
    # git clone --branch {branch} --single-branch git@github.com:{gh_url} {to}
    # If to=nothing, clones to current dir

gh_create_branch_on_github_from(gh_url, from, to)
    # 1. Get SHA of 'from' branch
    # 2. Create 'to' branch pointing at that SHA
    # Uses: gh api -X POST repos/{gh_url}/git/refs

gh_rename_branch(gh_url, old, new)
    # gh api -X POST repos/{gh_url}/branches/{old}/rename -f new_name={new}

gh_delete_branch(owner_repo, branch)
    # gh api -X DELETE repos/{owner_repo}/git/refs/heads/{branch}

wait_for_branch(gh_url, branch; max_wait=10, interval=1) -> String
    # Poll until branch exists
    # Returns SHA when available
    # Errors on timeout
```

**Helper Functions**:
```julia
gh_silent_run(cmd::Cmd) -> Bool
    # Run command, suppress output
    # Returns true on success, false on error
    # Logs warnings on failure

force_git_clone(repo_url, local_path)
    # Remove existing dir if present
    # Clone fresh copy

gh_pull(paper_id; round=nothing) -> (NamedTuple, String)
    # Get paper from DB
    # Pull/clone GitHub repo to Dropbox location
    # Returns (paper_record, repo_path)
```

**Name Sanitization**:
```julia
sanitize_repo_name(name; interactive=true) -> String
    # Convert personal names to GitHub-safe ASCII
    # Extensive transliteration map for international characters
    # Falls back to interactive prompt for unknown chars
    # Returns: Titlecase-hyphen-separated string
```

### actions.jl (Workflow Orchestration)

**Purpose**: High-level workflow functions composing other modules

**Main Workflows**:

#### Dispatch
```julia
dispatch()
    # For each paper with status "author_back_de":
    #   1. Ask if should dispatch
    #   2. preprocess2(paper_id)
    #   3. assign(paper_id)
    # Update workload and assignments
    # Create backup
```

#### Assignment
```julia
assign(paperID) -> (primary, secondary)
    # 1. select_replicators(paperID) - interactive selection
    # 2. assign_replicators(paperID, selection) - DB + email
    # Returns tuple of assigned replicator emails

select_replicators(paperID) -> NamedTuple
    # Display available replicators (colored by OS and availability)
    # Prompt for primary replicator
    # Optional secondary replicator
    # Returns: (primary_email, primary_name, secondary_email, secondary_name, 
    #           current_round, current_iteration, is_subsequent_round)

assign_replicators(paperID, selection) -> (primary, secondary)
    # Within update_paper_status transaction:
    #   - Send assignment email
    #   - Update iterations.replicator1/2
    #   - Update iterations.date_assigned_repl
    #   - Get submit_time from Dropbox
    #   - Update iterations.date_arrived_from_authors
    #   - Change status to "with_replicator"
```

#### Report Collection
```julia
collect_reports(; verbose=false)
    # 1. read_google_reports(append=true)
    # 2. Backup iterations table
    # 3. For each new report:
    #    - Update iterations fields one by one
    #    - Update paper status to "replicator_back_de"
    #    - Update workload tracking
    # Returns processed reports DataFrame

reports_2_iterations() -> Vector{Tuple}
    # Maps report columns to iterations columns
    # Returns: [(iterations_col, report_col), ...]
```

#### Decision Making
```julia
de_process_waiting_reports()
    # Interactive workflow for papers in "replicator_back_de"
    # For each paper:
    #   1. Display latest iteration summary
    #   2. Pull/write report
    #   3. Prompt for decision (accept/revise)
    #   4. Execute decision
    # Update workload, assignments, create backup

de_make_decision(paperID, decision) -> NamedTuple
    # decision ∈ {"accept", "revise"}
    # 
    # If "accept":
    #   - Status: "replicator_back_de" → "acceptable_package"
    #   - Update iterations.date_decision_de, decision_de="accept"
    #   - Send g2g email (draft)
    #
    # If "revise":
    #   - Call prepare_rnrs(paperID)

prepare_rnrs(paperID)
    # 1. Verify report PDF exists
    # 2. Within update_paper_status transaction:
    #    a. Get current iteration
    #    b. Create new iteration (round + 1)
    #    c. Create new GitHub branch
    #    d. Setup new Dropbox structure
    #    e. Insert new iteration row
    #    f. Update papers table (round, status="with_author")
    #    g. Update old iteration (decision_de="rnr")
    #    h. Send RnR email with report PDF
```

#### Report Writing
```julia
write_report(paperID) -> String
    # 1. gh_pull(paperID) - clone/pull repo
    # 2. Rename TEMPLATE.qmd to {CaseID}.qmd
    # 3. Optionally open in VSCode
    # 4. Return path to expected PDF
    # User must compile report manually

report_latest_iteration(paperID; round=nothing)
    # Display summary of iteration in formatted table
    # Shows: repl_comments, is_success, software, hours, etc.
```

#### Publication
```julia
finalize_publication(paperID, doi)
    # 1. insert_package_doi!(paperID, doi)
    # 2. dv_get_file_report(paperID) - verify MD5 checksums
    # 3. Prompt for confirmation
    # 4. update_paper_status: "acceptable_package" → "published_package"
    # 5. Update papers.date_published

delete_dropbox_paper(paperID; round=nothing, dryrun=true)
    # Delete Dropbox materials for paper
    # Preserves "preserve" and "thirdparty" directories
    # If round=nothing, deletes all rounds
    # dryrun=true: only prints what would be deleted
```

#### Monitoring
```julia
monitor_file_requests() -> Dict
    # Check all papers with status "with_author" or "new_arrival"
    # For each, check if file request has submissions
    # Returns: {
    #   :arrived => DataFrame (packages that arrived),
    #   :waiting => DataFrame (still waiting),
    #   :remindJO => DataFrame (need paper from JO)
    # }
    # For arrived packages:
    #   - Update status to "author_back_de"
    #   - Update date_arrived_from_authors
```

#### Helper Functions
```julia
display_replicators()
    # Formatted display of replicators grouped by OS
    # Color codes: green=available, red=at capacity
    # Shows current workload

reports_to_process() -> DataFrame
    # Find reports in reports table not yet in iterations
    # Compares on (paper_id, round, email)

paper_submitted_manually(id, round)
    # Manually mark package as arrived
    # Used when file request bypassed
```

### preprocess.jl (Preprocessing Coordination)

**Purpose**: Set up and coordinate package preprocessing with PackageScanner.jl

**Main Function**:
```julia
preprocess2(paperID; which_round=nothing, max_pkg_size_gb=10, max_file_size_gb=2)
    # 1. Get paper and iteration from DB
    # 2. Create temp directory
    # 3. Clone GitHub repo (current round branch)
    # 4. Check package size via Dropbox API
    # 5. Prompt for size thresholds (interactive)
    # 6. Prompt for paths to exclude from data scanning
    # 7. Create _variables.yml config file
    # 8. update_readme() - add run badge
    # 9. write_runner_script() - generate runner_precheck.jl
    # 10. Prompt: local or remote?
    #     LOCAL:
    #       - Run runner_precheck.jl in new Julia process
    #       - Commit results to GitHub
    #     REMOTE:
    #       - Commit _variables.yml and runner_precheck.jl
    #       - Push to GitHub (triggers Actions)
    # 11. Delete temp directory

# Parameters:
#   which_round: override current round
#   max_pkg_size_gb: threshold for partial extraction mode
#   max_file_size_gb: max size to extract from zips
```

**Configuration File** (`_variables.yml`):
```yaml
title: "Paper Title"
author: "Surname"
round: 1
repo: "https://github.com/JPE-Reproducibility/..."
paper_id: 12345678
journal: "JPE"
paper_slug: "Surname-12345678"
dropbox_rel_path: "JPE/Surname-12345678/1"  # Relative to JPE_DBOX_APPS
package_size_gb: 45.2
package_max_file_size_gb: 2.0
package_max_pkg_size_gb: 10.0
```

**Runner Script** (`runner_precheck.jl`):
```julia
# Generated script that runs on local or remote machine
# 1. Load YAML configuration
# 2. Construct Dropbox paths (using ENV["JPE_DBOX_APPS"] + relative path)
# 3. CURRENT APPROACH (unreliable):
#    - force_download_directory() - attempt to trigger Dropbox download
#    - Copy package to workspace
# 4. Unzip files (respecting size limits)
# 5. Run PackageScanner.precheck_package()
#    - Full mode if package < max_pkg_size_gb
#    - Partial mode if package > max_pkg_size_gb
# 6. Results committed to GitHub (automatic in Actions)

# PROPOSED APPROACH (not yet implemented):
# 3. Download via password-protected Dropbox link:
#    run(`curl -L -o package.zip "$url" -u :$password`)
```

**Helper Functions**:
```julia
update_readme(filepath, gh_org_repo, new_header)
    # Replace first line with new header
    # Insert GitHub Actions badge

write_runner_script(repoloc, no_data_scan::Vector{String})
    # Generate runner_precheck.jl
    # Includes force_download_directory function
    # Configures PackageScanner call with exclusions
```

### reporting.jl (Reports and Dashboards)

**Purpose**: Status reports, workload tracking, billing

**Status Reports**:
```julia
ps()
    # Print status table for all papers (except [TEST])
    # Color coded by days_in_status:
    #   - Green: ≤ 3 days
    #   - Light green: 3-5 days
    #   - Yellow: 5-10 days
    #   - Red: > 10 days
    #   - White: acceptable_package, published_package

global_report(; save_csv=false, csv_path=nothing) -> NamedTuple
    # Summary statistics:
    #   - Unique papers count
    #   - Total iterations
    #   - Papers by status (with percentages)
    # Returns: (summary=DataFrame, status=DataFrame)

paper_report(paperID; save_csv=false, csv_path=nothing) -> NamedTuple
    # Detailed paper report:
    #   - Paper details
    #   - Current status and responsible actor
    #   - Days in current status
    #   - Timeline of events (all iterations)
    # Returns: (details=DataFrame, timeline=DataFrame)

time_in_status_report(; save_csv=false, csv_path=nothing) -> DataFrame
    # Average/min/max time in each status
    # Across all papers
```

**Workload Tracking**:
```julia
replicator_workload_report(; save_csv=false, csv_path=nothing, update_gsheet=false) -> DataFrame
    # Current workload for each replicator
    # Counts papers with status "with_replicator"
    # Includes list of paper IDs and rounds
    # Optionally updates Google Sheet

replicator_assignments(; update_gs=true) -> DataFrame
    # List of current assignments
    # Shows: paper_slug, round, replicator1, replicator2, date_assigned, days_with_repl
    # Updates Google Sheet with formula for days calculation

replicator_history(; email=nothing) -> DataFrame
    # All papers a replicator has worked on
    # Filters by email if provided
    # Shows as_first and as_second assignments
```

**Billing**:
```julia
replicator_billing(; test_max_hours=1.5, rate=25.0, EUR2USD=1.1765, 
                    email=false, write_gs=false, email_repl_subset=nothing)
    -> (DataFrame, DataFrame)
    # 1. replicator_hours_worked() - get hours from iterations
    # 2. Cap test cases at test_max_hours
    # 3. Group by replicator and quarter
    # 4. Calculate pay in EUR and USD
    # 5. Optionally email invoices to replicators
    # 6. Optionally write to Google Sheet
    # Returns: (hours_detail, summary_by_quarter)

replicator_hours_worked() -> DataFrame
    # Extract from iterations table
    # Handle both replicator1 and replicator2
    # Add case_id and days_taken columns
    # Returns: date_completed, days_taken, replicator, hours, case_id

replicator_next_invoice(df, email) -> (Int, Int, Int)
    # Find next invoice number for replicator
    # Returns: (sheet_row, col_idx, next_invoice_num)

replicator_write_invoice(sheet_row, col_idx, next_invoice)
    # Update invoice number in Google Sheet
```

**Helper Functions**:
```julia
calculate_days_in_status(paper) -> Int|Missing
    # Determine when paper entered current status
    # Calculate days since then
    # Returns missing if date not available

determine_actor(status) -> String
    # Map status to responsible actor
    # e.g., "with_author" → "Author"

create_timeline(iterations_df) -> DataFrame
    # Build timeline from iteration dates
    # Returns: (Date, Event, Details)

calculate_replicator_workload(iterations_df, replicators_df) -> DataFrame
    # Count current assignments per replicator
```

### gmailing.jl (Email Communications)

**Purpose**: Email templates and sending via Gmail API (Python)

**Email Templates**:
```julia
gmail_file_request(firstname, paperid, title, url, email; email2=nothing, JO=false)
    # Initial file request email to author or JO
    # Includes: paperid, title, file request URL
    # JO version slightly different wording

gmail_assign(firstname, email, caseID, download_url, repo_url; 
             first2=nothing, email2=nothing, back=false)
    # Assignment email to replicator(s)
    # back=true: subsequent round, different wording
    # Includes: download link, GitHub repo, instructions

gmail_rnr(firstname, paperid, title, file_request_url, email, attachfile;
          email2=nothing)
    # Revision request email to author
    # Attaches report PDF
    # Includes new file request URL

gmail_g2g(firstname, paperid, title, email, paper_slug, data_statement;
          email2=nothing, draft=true)
    # "Good to go" acceptance email
    # Includes data statement guidance
    # draft=true: save as draft, don't send

gmail_send_invoice(name, email, work_df, test_max_hours, rate, EUR2USD, 
                   invoice_num; send=false)
    # Invoice email to replicator
    # Includes: work table, hours, pay calculation
    # send=false: draft only
```

**Sending**:
All functions call Python `send_email()` or `create_draft()` via PyCall.

### dataverse.jl (Publication)

**Purpose**: Verify package integrity and publish to Dataverse

**Functions**:
```julia
dv_get_file_report(paperID)
    # 1. Get DOI from database
    # 2. Query Dataverse API for file list + MD5 hashes
    # 3. Compare to local Dropbox package
    # 4. Report differences
    # Used to verify package integrity before marking published
```

### zip.jl (File Operations)

**Purpose**: Zip file handling and size calculations

**Functions**:
```julia
disk_size_gb(path) -> Float64
    # Calculate size of file or directory in GB
    # Recursively sums file sizes

read_and_unzip_directory(dir_path; rm_zip=true) -> Vector{String}
    # Find all .zip files in directory
    # Unzip each using system `unzip` command
    # Remove .git directories from extracted content
    # Optionally delete zip files after extraction
    # Returns: list of files in directory

rm_git(extract_dir)
    # Find and remove .git directories
    # Prevents nested git repos
```

### snippets.jl (Utilities)

**Purpose**: Helper functions and utilities

**Functions**:
```julia
case_id(journal, surname, paperid, round) -> String
    # Format: "{journal}-{surname}-{paperid}-R{round}"

get_case_id(journal, slug, round; fpath=true) -> String
    # If fpath: "{journal}/{slug}/{round}"
    # Else: "{journal}-{slug}-R{round}"

get_dbox_loc(journal, slug, round; full=false) -> String
    # If full: "$JPE_DBOX_APPS/{journal}/{slug}/{round}"
    # Else: "/{journal}/{slug}/{round}"

setup_dropbox_structure!(r::DataFrameRow, dbox_token)
    # Create Dropbox folders
    # Create file requests
    # Update row with paths and URLs

JO_email() -> String
author_email(email) -> String
    # Email address helpers

clean_journalname(j) -> String
get_paper_slug(last, id) -> String
    # Data cleaning helpers

missnothing(x) -> Any|Nothing
missna(x) -> Any|String
yesno_bool(x) -> Bool
    # Type conversion helpers

create_example_package(; name, id, journal)
create_example_DAS(; name, id, journal)
    # Generate test packages for development
```

## Development Workflow

### Setting Up Development Environment

1. **Clone repository**:
   ```bash
   git clone git@github-jpe:JPE-Reproducibility/JPE.jl.git
   cd JPE.jl
   ```

2. **Set up Python environment**:
   ```bash
   pyenv install 3.13.5
   pyenv virtualenv 3.13.5 jpe-env
   pyenv local jpe-env
   pip install -r requirements.txt
   ```

3. **Configure Julia**:
   ```julia
   ENV["PYTHON"] = "/Users/you/.pyenv/shims/python"
   using Pkg
   Pkg.build("PyCall")
   Pkg.develop(path=".")
   ```

4. **Set environment variables** (in `~/.zshrc` or `~/.config/fish/config.fish`):
   ```bash
   export JPE_DB="/path/to/db"
   export JPE_GOOGLE_KEY="/path/to/google-key.json"
   export JPE_DBOX_APPS="/Users/you/Dropbox/Apps/JPE-packages"
   export JPE_DBOX_APP_SECRET="..."
   export JPE_DBOX_APP_REFRESH="..."
   export JPE_DV="..."
   export JULIA_RUNNER_ENV="/path/to/runner/env"
   ```

5. **Authenticate services**:
   ```julia
   using JPE
   gs4_auth()  # Google
   # GitHub: gh auth login (in terminal)
   ```

### Testing

**Run tests**:
```bash
julia --project=. test/runtests.jl
```

**Test specific modules**:
```julia
using JPE
include("test/test_dropbox.jl")
include("test/test_duck.jl")
```

**Create test cases**:
```julia
# Mark with "[TEST]" in comments field
# Will be excluded from ps() display
# Can be bulk deleted with db_delete_test()
```

### Adding New Features

1. **Database changes**:
   - Update schema in `db_get_table_schema()`
   - Use `db_add_missing_columns()` to migrate existing databases
   - Create backup before testing: `db_bk_create()`

2. **New workflow steps**:
   - Add high-level function to `actions.jl`
   - Use `update_paper_status()` for state transitions
   - Add email template to `gmailing.jl` if needed

3. **New reports**:
   - Add function to `reporting.jl`
   - Use `PrettyTables` for terminal output
   - Support CSV export with `save_csv` parameter

### Code Style

**Julia conventions**:
- Use `snake_case` for functions and variables
- Use `SCREAMING_SNAKE_CASE` for constants
- Type annotations for clarity, not enforcement
- Document functions with docstrings
- Use `@chain` for data pipelines

**Transaction safety**:
- Always use `robust_db_operation()` for database writes
- Validate state before transitions
- Create backups before destructive operations

**Error handling**:
- Use `try-catch` for expected failures (API calls)
- Let unexpected errors bubble up
- Use `@warn` for recoverable issues
- Use `@error` for serious problems

**Interactive prompts**:
- Use `RadioMenu` for choices
- Use `ask()` for confirmations
- Provide defaults for common cases
- Allow interactive override of computed values

### Debugging

**Enable debug output**:
```julia
ENV["JULIA_DEBUG"] = "JPE"
using JPE
# Now @debug statements will print
```

**Check database state**:
```julia
db_show()  # List tables and sizes
ps()  # Current paper status
db_filter_paper("12345678")  # Specific paper
```

**Validate paper status**:
```julia
valid, issues = validate_paper_status("12345678")
if !valid
    println(issues)
    set_status!("12345678")  # Auto-repair
end
```

**Check connection**:
```julia
db_connection_status()
db_release_connection()
db_reconnect()
```

### Common Pitfalls

1. **Forgetting to refresh Dropbox token**:
   - Tokens expire after ~30 min
   - `dbox_set_token()` refreshes
   - Most Dropbox functions auto-retry with refresh

2. **Missing transaction wrapper**:
   - Always use `robust_db_operation()` for writes
   - Don't use raw `DBInterface.execute()` for state changes

3. **Inconsistent status**:
   - Status should match iteration dates
   - Use `validate_paper_status()` to check
   - Use `set_status!()` to repair

4. **Python path issues**:
   - PyCall must use correct Python (with packages installed)
   - `ENV["PYTHON"]` must be set before `Pkg.build("PyCall")`

5. **GitHub authentication**:
   - Must have org access for JPE-Reproducibility
   - Use `gh auth refresh -s admin:org` if permission denied

6. **Large package timeouts**:
   - Dropbox API calls may timeout for 100GB+ folders
   - Use local preprocessing for very large packages
   - Consider implementing download link approach

## Proposed Enhancements

### 1. Password-Protected Dropbox Links

**Problem**: Remote preprocessing fails because Dropbox "online only" files don't materialize.

**Solution**: Download via password-protected shared links instead of filesystem access.

**Implementation**:

1. **Add Python function** (`src/db_filerequests.py`):
   ```python
   def create_password_protected_link(path, password, token):
       dbx = dropbox.Dropbox(token)
       settings = dropbox.sharing.SharedLinkSettings(
           requested_visibility=dropbox.sharing.RequestedVisibility.password,
           link_password=password
       )
       link = dbx.sharing_create_shared_link_with_settings(path, settings)
       return {
           'url': link.url,
           'id': link.id,
           'path': link.path_lower
       }
   ```

2. **Add Julia wrapper** (`src/dropbox.jl`):
   ```julia
   function dbox_create_password_link(path, password, token)
       py"create_password_protected_link"(path, password, token)
   end
   ```

3. **Modify `preprocess2()`** (`src/preprocess.jl`):
   ```julia
   # Generate secure password
   password = randstring(['a':'z'; 'A':'Z'; '0':'9'], 16)
   
   # Create protected link
   link = dbox_create_password_link(dropbox_path, password, dbox_token)
   
   # Store in _variables.yml
   println(io, "dropbox_download_url: \"$(link["url"])?dl=1\"")
   
   # Display for Slack sharing
   @info """
   Password for replicator (share via Slack): $password
   Add as GitHub secret: DROPBOX_PASSWORD=$password
   """
   ```

4. **Simplify `runner_precheck.jl`**:
   ```julia
   # Remove force_download_directory complexity
   # Replace with simple authenticated download
   url = vars["dropbox_download_url"]
   password = ENV["DROPBOX_PASSWORD"]
   
   run(`curl -L -o package.zip "$url" -u :$password`)
   run(`unzip -q package.zip -d replication-package/`)
   ```

**Benefits**:
- ✅ Works with any package size (100GB+)
- ✅ No Dropbox app needed on runner
- ✅ No token expiration issues
- ✅ Secure (password + link via different channels)
- ✅ No JPE.jl dependency on runner

### 2. Automated Status Monitoring

**Add periodic status checks**:
```julia
function monitor_overdue_papers(threshold_days=7)
    # Find papers sitting in status > threshold days
    # Send alerts to DE
    # Update status tracking sheet
end
```

### 3. Enhanced Testing

**Add more test coverage**:
- Unit tests for each module
- Integration tests for workflows
- Mock services for external APIs (Google, Dropbox, GitHub)
- CI/CD pipeline improvements

### 4. Performance Optimization

**Database query optimization**:
- Add indexes on frequently queried columns (paper_id, status, round)
- Use materialized views for complex reports
- Cache replicator list (currently fetches from Google Sheets repeatedly)

### 5. Error Recovery Dashboard

**Web interface for status monitoring**:
- Real-time dashboard showing all papers
- Automatic status validation
- One-click repair buttons
- Audit log of all state transitions

## Architecture Decisions

### Why DuckDB?

**Chosen over**: SQLite, PostgreSQL, MySQL

**Reasons**:
1. **Embedded** - no server needed
2. **Analytical** - fast aggregations for reports
3. **Julia integration** - excellent DuckDB.jl package
4. **ACID transactions** - data integrity
5. **File-based** - easy backups

### Why Python for Dropbox/Gmail?

**Chosen over**: Pure Julia HTTP.jl implementation

**Reasons**:
1. **Official libraries** - google-api-python-client, dropbox
2. **OAuth complexity** - Python libraries handle refresh tokens better
3. **Maintenance** - Official libs updated by Google/Dropbox
4. **Time constraint** - Faster to integrate existing solutions

**Trade-off**: Added Python dependency, but manageable with pyenv

### Why R for Google Sheets?

**Chosen over**: Python gspread, Pure Julia

**Reasons**:
1. **googlesheets4** is excellent - most reliable Google Sheets library
2. **RCall integration** works well
3. **Already using RCall** for other purposes

**Future**: Could migrate to pure Julia if reliable library emerges

### Why GitHub CLI (`gh`)?

**Chosen over**: Julia GitHub API libraries

**Reasons**:
1. **Authentication** - `gh` handles auth seamlessly
2. **Full-featured** - All operations needed are available
3. **Reliable** - Official GitHub tool
4. **Simpler** - Less code than HTTP.jl + authentication

### Transaction Model

**Pattern**: Optimistic locking with validation

**Approach**:
1. Check current state (e.g., status must be X)
2. Perform operations
3. Update state
4. Commit or rollback

**Rationale**: Prevents race conditions, ensures consistency

### Status-Driven Workflow

**Instead of**: Event-driven, separate workflow engine

**Rationale**:
1. Simple to reason about
2. Easy to debug (just check status)
3. Easy to repair (just set status)
4. Audit trail through iterations table

## Contributing

### Pull Request Process

1. Create feature branch from `main`
2. Make changes with tests
3. Update documentation (README, LLM.md, DEVELOPERS.md)
4. Test thoroughly
5. Submit PR with description

### Commit Messages

Follow conventional commits:
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation
- `refactor:` - Code refactoring
- `test:` - Test additions/changes
- `chore:` - Maintenance

Example: `feat: add password-protected Dropbox links for remote preprocessing`

### Review Checklist

- [ ] Code follows style guidelines
- [ ] Tests pass
- [ ] Documentation updated
- [ ] No hardcoded credentials
- [ ] Transaction safety for DB operations
- [ ] Error handling appropriate
- [ ] Backward compatible (or migration provided)

## License

See LICENSE file in repository.

## Contact

Issues: https://github.com/JPE-Reproducibility/JPE.jl/issues
