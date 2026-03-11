# Proposal: Password-Protected Dropbox Links for Remote Preprocessing

**Date**: 2026-11-03  
**Status**: Proposed  
**Priority**: High  
**Complexity**: Medium

---

## Executive Summary

Remote preprocessing of replication packages on GitHub Actions runners fails because macOS Dropbox "Files On-Demand" feature creates file stubs that don't materialize when accessed programmatically. This proposal recommends replacing filesystem-based Dropbox access with HTTP downloads via password-protected shared links.

**Current State**: Unreliable remote preprocessing, limited to local execution for large packages  
**Proposed State**: Reliable remote preprocessing for packages of any size (including 100GB+)  
**Breaking Changes**: None (backward compatible, local preprocessing unchanged)

---

## Problem Statement

### The Challenge: Dropbox "Online Only" Files

**Context**: See `LLM.md` section "Dropbox 'Online Only' Problem" and `DEVELOPERS.md` section "Proposed Enhancements #1"

#### What Happens
1. macOS Dropbox uses "Files On-Demand" (aka "Smart Sync")
2. Files appear in filesystem but aren't actually downloaded
3. These are "stubs" with `com.apple.fileprovider.stubbed` xattr
4. Opening files in GUI apps triggers download
5. **BUT**: Programmatic access (scripts, GitHub Actions) doesn't reliably trigger download

#### Current Workaround (src/preprocess.jl, runner_precheck.jl)
```julia
function force_download_directory(dirpath)
    for (root, dirs, files) in walkdir(dirpath)
        for file in files
            filepath = joinpath(root, file)
            # Try to force download by reading entire file
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

**Why This Fails**:
- Dropbox File Provider doesn't guarantee materialization on `open()`
- Race conditions between read and download
- No reliable completion detection
- Timeouts on large files
- Especially problematic on GitHub Actions runners

#### Impact
- Remote preprocessing unreliable
- Forces local preprocessing (ties up researcher's machine)
- Can't leverage GitHub Actions for large packages
- Manual intervention often required
- 100GB+ packages essentially impossible remotely

---

## Proposed Solution: Password-Protected Shared Links

### High-Level Approach

**Instead of**: Relying on Dropbox filesystem access  
**Use**: Direct HTTP download from Dropbox via password-protected shared links

**Key Insight**: Dropbox shared links work reliably via HTTP, regardless of "online only" status. Password protection adds security.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ LOCAL MACHINE (macOS, Dropbox sync works)                   │
│                                                              │
│  preprocess2(paperID)                                       │
│    ↓                                                         │
│  1. Generate secure random password                         │
│  2. Create password-protected Dropbox link (API call)       │
│  3. Store URL in _variables.yml                             │
│  4. Store password as GitHub secret (DROPBOX_PASSWORD)      │
│  5. Display password for Slack sharing with replicator      │
│  6. Commit & push to GitHub                                 │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ GitHub Actions triggered
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ GITHUB ACTIONS RUNNER (no Dropbox app)                      │
│                                                              │
│  runner_precheck.jl                                         │
│    ↓                                                         │
│  1. Read URL from _variables.yml                            │
│  2. Get password from ENV["DROPBOX_PASSWORD"]               │
│  3. Download: curl -L -o package.zip "$url" -u :$password  │
│  4. Unzip package                                           │
│  5. Run PackageScanner.precheck_package()                  │
│  6. Commit results                                          │
└─────────────────────────────────────────────────────────────┘
```

### Benefits

✅ **No size limits**: Works with 100GB+ packages (Dropbox handles it)  
✅ **No Dropbox app needed**: Runner only needs `curl`  
✅ **No token expiration**: Shared links don't expire like access tokens  
✅ **No JPE.jl dependency**: Runner is self-contained  
✅ **Secure**: Two-factor security (link + password via different channels)  
✅ **Reliable**: HTTP download is standard, well-tested  
✅ **Backward compatible**: Local preprocessing unchanged  
✅ **Simple runner**: Fewer dependencies, easier debugging

### Security Model

**Important**: GitHub repos are **PUBLIC** (created with `--public` flag for pricing reasons), but GitHub Secrets remain completely secure.

**Two-Factor Security**:
1. **Link** (public in `_variables.yml` + shared via email with replicator)
2. **Password** (shared via Slack with replicator + stored as GitHub secret)

**Access Control**:
- Link alone: Shows "This link is password protected" - cannot download files
- Password alone: Useless without link URL
- Both together: Can download (intended for runner + replicator)

**GitHub Secrets in Public Repos** (Safe! ✅):
- Encrypted at rest on GitHub servers
- Never visible in repo files or commit history
- Not visible to repo visitors or even admins after creation
- Only accessible to GitHub Actions workflows as `ENV` variables
- Same security as private repos - no difference
- Automatically redacted from workflow logs

**Two Users of Password**:
1. **GitHub Actions Runner** (self-hosted):
   - Reads from `ENV["DROPBOX_PASSWORD_12345678_R1"]`
   - Secret injected by GitHub Actions
   - Downloads package for preprocessing

2. **Human Replicator**:
   - Receives password during assignment (after preprocessing succeeds)
   - Shared via Slack direct message (secure channel)
   - Uses to download from same Dropbox link
   - Can work on package locally

**Password Storage**:
- Database: `iterations.dropbox_password` column stores password
- GitHub Secret: Runner reads from repository secret
- Retrieved during assignment for sharing with replicator

**Per-Paper Password Security**:
- Each paper gets unique password: `DROPBOX_PASSWORD_{paperID}_R{round}`
- Compromising one password doesn't affect other papers
- Can revoke individual links without affecting others
- Natural security boundary per replication package

**Confidential Data Protection**:
- Password-protected links prevent unauthorized access
- Replicators sign confidentiality agreements
- Separate channels: Link via email/repo, password via Slack
- Links can be revoked after preprocessing/replication complete

**Link Properties**:
- Unguessable: Contains random tokens (e.g., `/sh/abc123xyz/789def`)
- HTTPS: Encrypted in transit
- Can be revoked: Via Dropbox API at any time
- Optional expiration: Can set time limit if desired (e.g., 30 days)

---

## Implementation Plan

### Phase 1: Add Password-Protected Link Creation

#### 1.1 Python Function (src/db_filerequests.py)

Add new function to create password-protected shared links:

```python
def create_password_protected_link(path, password, token):
    """
    Create a password-protected shared link for a Dropbox path.
    
    Args:
        path: Dropbox path (e.g., "/JPE/Surname-12345678/1/replication-package")
        password: Password to protect the link
        token: Dropbox access token
    
    Returns:
        dict: {
            'url': str,      # The shared link URL
            'id': str,       # Link ID (for revocation)
            'path': str      # Dropbox path
        }
    """
    import dropbox
    from dropbox.sharing import SharedLinkSettings, RequestedVisibility
    
    dbx = dropbox.Dropbox(token)
    
    settings = SharedLinkSettings(
        requested_visibility=RequestedVisibility.password,
        link_password=password
    )
    
    try:
        link = dbx.sharing_create_shared_link_with_settings(path, settings)
        return {
            'url': link.url,
            'id': link.id,
            'path': link.path_lower
        }
    except dropbox.exceptions.ApiError as e:
        # Handle case where link already exists
        if hasattr(e.error, 'shared_link_already_exists'):
            # Get existing link and update password
            existing_link = e.error.shared_link_already_exists.metadata
            # Note: Dropbox API doesn't allow updating password on existing link
            # Need to revoke old link and create new one
            dbx.sharing_revoke_shared_link(existing_link.url)
            # Retry creation
            link = dbx.sharing_create_shared_link_with_settings(path, settings)
            return {
                'url': link.url,
                'id': link.id,
                'path': link.path_lower
            }
        else:
            raise

def revoke_shared_link(url, token):
    """
    Revoke a shared link.
    
    Args:
        url: The shared link URL to revoke
        token: Dropbox access token
    """
    import dropbox
    dbx = dropbox.Dropbox(token)
    dbx.sharing_revoke_shared_link(url)
```

#### 1.2 Julia Wrapper (src/dropbox.jl)

Add Julia functions to call Python:

```julia
function dbox_create_password_link(path, password, token)
    """
    Create password-protected Dropbox shared link.
    
    # Arguments
    - `path::String`: Dropbox path (relative, will be prefixed with /)
    - `password::String`: Password for link protection
    - `token::String`: Dropbox access token
    
    # Returns
    - `Dict`: {url, id, path}
    
    # Example
    ```julia
    link = dbox_create_password_link(
        "/JPE/Surname-12345678/1/replication-package",
        "SecurePass123!",
        dbox_token
    )
    # link["url"] => "https://www.dropbox.com/..."
    ```
    """
    try
        py"create_password_protected_link"(path, password, token)
    catch e1
        try
            @error "$e1"
            @info "refreshing dropbox token"
            dbox_set_token()
            py"create_password_protected_link"(path, password, token)
        catch e2
            throw(e2)
        end
    end
end

function dbox_revoke_link(url, token)
    """
    Revoke a Dropbox shared link.
    
    # Arguments
    - `url::String`: The shared link URL to revoke
    - `token::String`: Dropbox access token
    """
    try
        py"revoke_shared_link"(url, token)
    catch e1
        try
            @error "$e1"
            @info "refreshing dropbox token"
            dbox_set_token()
            py"revoke_shared_link"(url, token)
        catch e2
            throw(e2)
        end
    end
end
```

### Phase 2: Modify Preprocessing Setup

#### 2.1 Update preprocess2() (src/preprocess.jl)

Modify the preprocessing setup to create password-protected links with per-paper secrets:

```julia
function preprocess2(paperID; which_round = nothing, max_pkg_size_gb = 10, max_file_size_gb = 2)
    
    # ... existing code to get paper info, clone repo, check size ...
    
    # Generate unique password for this specific paper and round
    password = randstring(['a':'z'; 'A':'Z'; '0':'9'; '!'; '@'; '#'; '%'], 16)
    
    # Create password-protected Dropbox link
    dropbox_path = joinpath(get_dbox_loc(r.journal, r.paper_slug, r.round, full=false), 
                            "replication-package")
    link_info = dbox_create_password_link(dropbox_path, password, dbox_token)
    
    # Create unique secret name for this paper + round
    secret_name = "DROPBOX_PASSWORD_$(paperID)_R$(round)"
    
    # Create _variables.yml with all necessary info
    open(joinpath(repoloc, "_variables.yml"), "w") do io
        println(io, "title: \"$(r.title)\"")
        println(io, "author: \"$(r.surname_of_author)\"")
        println(io, "round: $(round)")
        println(io, "repo: \"$(r.github_url)\"")
        println(io, "paper_id: $(r.paper_id)")
        println(io, "journal: \"$(r.journal)\"")
        println(io, "paper_slug: \"$(r.paper_slug)\"")
        
        # NEW: Password-protected link configuration
        println(io, "# Remote preprocessing via password-protected link:")
        println(io, "dropbox_download_url: \"$(link_info["url"])?dl=1\"")
        println(io, "dropbox_link_id: \"$(link_info["id"])\"")
        println(io, "dropbox_password_secret: \"$secret_name\"")
        
        # KEEP: Store relative path for local preprocessing fallback
        println(io, "# Local preprocessing fallback:")
        println(io, "dropbox_rel_path: \"$(get_case_id(r.journal, r.paper_slug, r.round))\"")
        
        println(io, "package_size_gb: $(size_gb)")
        println(io, "package_max_file_size_gb: $(max_file_size_gb)")
        println(io, "package_max_pkg_size_gb: $(max_pkg_size_gb)")
    end
    
    # Store password in database for later retrieval during assignment
    robust_db_operation() do con
        DBInterface.execute(con, """
            UPDATE iterations 
            SET dropbox_password = ?
            WHERE paper_id = ? AND round = ?
        """, [password, paperID, round])
    end
    
    # Display GitHub secret setup (runner needs this now)
    println()
    println("="^70)
    println("🔐 PASSWORD-PROTECTED LINK CREATED FOR $(get_case_id(r.journal, r.paper_slug, r.round))")
    println("="^70)
    println()
    println("Password: $password")
    println("Secret Name: $secret_name")
    println()
    println("ACTION REQUIRED FOR RUNNER:")
    println("Add as GitHub secret:")
    println("  gh secret set $secret_name --body \"$password\" --repo $(r.gh_org_repo)")
    println()
    println("Press Enter when done...")
    println()
    println("NOTE:")
    println("  - Password stored in database (iterations.dropbox_password)")
    println("  - Will be shared with replicator during assignment (after preprocessing)")
    println("  - Runner downloads now, replicator downloads later")
    println("="^70)
    readline()
    
    # ... rest of existing code ...
end
```

#### 2.2 Add Helper Function

Add function to revoke link after preprocessing:

```julia
function revoke_preprocessing_link(paperID, round)
    """
    Revoke Dropbox shared link after preprocessing completes.
    
    Call this after remote preprocessing finishes to clean up.
    """
    rt = db_filter_iteration(paperID, round)
    r = rt[1, :]
    
    # Read _variables.yml from GitHub to get link ID
    repo_path = # ... get from GitHub or local cache
    vars = YAML.load_file(joinpath(repo_path, "_variables.yml"))
    
    if haskey(vars, "dropbox_link_id")
        println("Revoking Dropbox shared link...")
        dbox_revoke_link(vars["dropbox_link_id"], dbox_token)
        println("✓ Link revoked")
    else
        @warn "No dropbox_link_id found in _variables.yml"
    end
end
```

### Phase 3: Simplify Runner Script

#### 3.1 Update write_runner_script() (src/preprocess.jl)

Replace complex force-download logic with simple HTTP download using per-paper secret:

```julia
function write_runner_script(repoloc::String, no_data_scan::Vector{String})
    open(joinpath(repoloc, "runner_precheck.jl"), "w") do io
        write(io, """
        using YAML
        using PackageScanner

        # Read configuration
        vars = YAML.load_file(joinpath(ENV["GITHUB_WORKSPACE"], "_variables.yml"))
        
        @info "Configuration loaded" vars
        
        # Construct paths
        dest_path = joinpath(ENV["GITHUB_WORKSPACE"], "replication-package")
        
        @info "Paths configured" GITHUB_WORKSPACE=ENV["GITHUB_WORKSPACE"] dest_path
        
        # Download package from Dropbox via password-protected link
        @info "Downloading package from password-protected Dropbox link..."
        
        url = vars["dropbox_download_url"]
        
        # Get password from environment using dynamic secret name
        # Each paper has unique secret: DROPBOX_PASSWORD_{paperID}_R{round}
        secret_name = vars["dropbox_password_secret"]
        password = ENV[secret_name]
        
        if isnothing(password) || isempty(password)
            error("\$secret_name environment variable not set!")
        end
        
        # Download using curl with password authentication
        # -L: follow redirects
        # -o: output file
        # -u :password: password authentication (username is empty)
        download_start = time()
        try
            run(`curl -L -o package.zip "\$url" -u :\$password`)
            download_time = time() - download_start
            @info "✓ Package downloaded successfully in \$(round(download_time, digits=2)) seconds"
        catch e
            @error "Failed to download package" exception=e
            
            # FALLBACK: Try local Dropbox path (for local preprocessing)
            @warn "Attempting fallback to local Dropbox path..."
            source_path = joinpath(ENV["JPE_DBOX_APPS"], vars["dropbox_rel_path"], "replication-package")
            
            if !isdir(source_path)
                error("✗ Fallback failed: Package not found at \$source_path")
            end
            
            @info "Copying from local Dropbox..."
            cp(source_path, dest_path; recursive=true, force=true)
            @info "✓ Package copied from local Dropbox"
        end
        
        # Unzip if we downloaded a zip
        if isfile("package.zip")
            @info "Unzipping package..."
            try
                run(`unzip -oq package.zip -d replication-package/`)
                @info "✓ Package unzipped"
                rm("package.zip")
            catch e
                @error "Failed to unzip" exception=e
                rethrow(e)
            end
        end
        
        # Verify package exists
        if !isdir(dest_path)
            error("✗ Package directory not found at \$dest_path")
        end
        
        @info "Package ready at \$dest_path"
        
        # Unzip files depending on size (existing logic)
        pkg_size = vars["package_size_gb"]
        max_pkg_size = vars["package_max_pkg_size_gb"]
        max_file_size = vars["package_max_file_size_gb"]
        
        if pkg_size > max_pkg_size
            @info "Package is larger than \$(max_pkg_size) GB. Using partial extraction mode"
            pkg_dir, manifest = PackageScanner.prepare_package_for_precheck(
                dest_path, 
                size_threshold_gb = max_file_size, 
                interactive = false
            )
            @info "Running precheck on \$pkg_dir"
            PackageScanner.precheck_package(pkg_dir, pre_manifest=manifest, no_data_scan = $(no_data_scan))
        else
            @info "Unzipping files in \$dest_path"
            try
                zips = PackageScanner.read_and_unzip_directory(dest_path)
                @info "Unzipped \$(length(zips)) file(s)"
            catch e
                @warn "Unzip had issues (may be okay)" exception=e
            end

            # Run precheck
            @info "Running precheck on \$dest_path"
            try
                PackageScanner.precheck_package(dest_path, no_data_scan = $(no_data_scan))
                @info "✓ Precheck complete"
            catch e
                @error "Precheck failed" exception=e
                rethrow(e)
            end
        end
        """)
    end
    @info "Created runner_precheck.jl at $repoloc"
end
```

### Phase 4: Add Assignment-Time Password Sharing

#### 4.1 Update Database Schema (src/db.jl)

Add `dropbox_password` column to iterations table schema:

```julia
function db_get_table_schema(table::String)
    if table == "iterations"
        return Dict(
            # ... existing columns ...
            "dropbox_password" => "VARCHAR",  # NEW: Password for Dropbox link
            # ... rest of columns ...
        )
    end
    # ... other tables ...
end
```

#### 4.2 Update assign() Function (src/actions.jl)

Modify assignment to retrieve and display password for manual sharing:

```julia
function assign_replicators(paperID, selection)
    # ... existing assignment logic ...
    
    within update_paper_status transaction:
        # Send assignment email
        gmail_assign(...)
        
        # Update iterations table
        # ...
        
        # Retrieve password from database
        iteration = db_filter_iteration(paperID, selection.current_round)
        password = iteration.dropbox_password[1]
        
        # Display password for manual sharing via Slack
        if !ismissing(password) && !isnothing(password)
            println()
            println("="^70)
            println("🔐 DROPBOX PASSWORD FOR REPLICATOR")
            println("="^70)
            println()
            println("Password: $password")
            println()
            println("⚠️  ACTION REQUIRED:")
            println("Send this password to $(selection.primary_email) via Slack DM")
            println()
            println("Suggested Slack message:")
            println("────────────────────────────────────────")
            println("Hi! Password for $(r.paper_slug) R$(selection.current_round): $password")
            println("Use this to download from the Dropbox link in your email.")
            println("────────────────────────────────────────")
            println()
            println("Press Enter when sent...")
            println("="^70)
            readline()
        else
            @warn "No password found in database for $(paperID) R$(selection.current_round)"
        end
        
        # Change status to "with_replicator"
end
```

#### 4.3 Add Helper Function

Add password retrieval helper:

```julia
function get_dropbox_password(paperID, round)
    """
    Retrieve Dropbox password for a paper and round.
    
    Useful if replicator loses password or it wasn't shared initially.
    """
    iteration = db_filter_iteration(paperID, round)
    
    if nrow(iteration) == 0
        error("No iteration found for $(paperID) R$(round)")
    end
    
    password = iteration.dropbox_password[1]
    
    if ismissing(password) || isnothing(password)
        error("No password stored for $(paperID) R$(round)")
    end
    
    println("Password for $(paperID) R$(round): $password")
    println()
    println("Suggested Slack message:")
    println("────────────────────────────────────────")
    println("Password for this paper: $password")
    println("Use with the Dropbox link from your email.")
    println("────────────────────────────────────────")
    
    return password
end
```

### Phase 5: Update Documentation

#### 5.1 Update README.md

Add section explaining password-protected link workflow.

#### 5.2 Update LLM.md

Update "Dropbox 'Online Only' Problem" section with "Implemented Solution".

#### 5.3 Update DEVELOPERS.md

Move "Proposed Solution" to "Implemented Features".

---

## Testing Plan

### Test Cases

1. **Small Package (< 1 GB)**
   - Local preprocessing: Should work as before
   - Remote preprocessing: Should download via link

2. **Medium Package (10 GB)**
   - Remote preprocessing: Verify download time acceptable
   - Verify partial extraction mode if needed

3. **Large Package (50 GB)**
   - Remote preprocessing: Verify download succeeds
   - Monitor GitHub Actions timeout (6 hours max)

4. **Very Large Package (100 GB+)**
   - Remote preprocessing: May hit GitHub Actions limits
   - Document threshold for local-only

5. **Confidential Package**
   - Verify password protection works
   - Verify link without password fails
   - Verify access control (private repo)

6. **Error Cases**
   - Missing password env var: Should fail gracefully with clear error
   - Invalid password: Should fail download
   - Expired/revoked link: Should fail with clear error
   - Fallback to local: Should work if `JPE_DBOX_APPS` available

### Test Procedure

```julia
# 1. Create test case
using JPE
# Mark as [TEST] in comments

# 2. Run preprocessing locally first (baseline)
preprocess2("TEST-ID", which_round=1)
# Choose "local" - should work as before

# 3. Run preprocessing remotely with new system
preprocess2("TEST-ID", which_round=2)
# Choose "remote"
# Copy displayed password
# Add as GitHub secret
# Monitor GitHub Actions
# Verify success

# 4. Verify results match local preprocessing

# 5. Test revocation
revoke_preprocessing_link("TEST-ID", 2)
# Verify download fails after revocation

# 6. Cleanup
db_delete_test()
```

---

## Rollout Plan

### Phase 1: Development & Testing (Week 1)
- [ ] Implement Python functions
- [ ] Implement Julia wrappers
- [ ] Update preprocess2()
- [ ] Update runner script
- [ ] Test with small packages

### Phase 2: Beta Testing (Week 2)
- [ ] Test with medium packages (10-50 GB)
- [ ] Test with confidential data
- [ ] Gather feedback from replicators
- [ ] Refine error handling

### Phase 3: Documentation (Week 3)
- [ ] Update all documentation
- [ ] Create user guide
- [ ] Document troubleshooting
- [ ] Update security guidelines

### Phase 4: Production Rollout (Week 4)
- [ ] Deploy to production
- [ ] Monitor first 5 real packages
- [ ] Collect metrics (download times, success rates)
- [ ] Iterate based on feedback

---

## Risks & Mitigation

### Risk 1: Dropbox API Rate Limits
**Likelihood**: Low  
**Impact**: Medium  
**Mitigation**: Downloads via shared links don't count against API limits (according to Dropbox docs)

### Risk 2: GitHub Actions Timeout (6 hours)
**Likelihood**: Medium (for 100GB+ packages)  
**Impact**: High  
**Mitigation**: 
- Document size limits clearly
- Add size check and warning in preprocess2()
- Recommend local preprocessing for very large packages

### Risk 3: Password Leakage
**Likelihood**: Low  
**Impact**: High  
**Mitigation**:
- Passwords only valid for specific link
- Links can be revoked
- GitHub secrets encrypted at rest
- Encourage password change per round

### Risk 4: Download Failures
**Likelihood**: Medium  
**Impact**: Medium  
**Mitigation**:
- Implement retry logic in curl command
- Fallback to local path if available
- Clear error messages
- Logging for debugging

### Risk 5: Backward Compatibility
**Likelihood**: Low  
**Impact**: Low  
**Mitigation**:
- Keep local preprocessing unchanged
- Fallback path in runner script
- Gradual migration (both methods work)

---

## Success Metrics

### Primary Metrics
- **Remote preprocessing success rate**: Target >95% (currently ~50%)
- **Large package support**: Consistently handle 50GB+ packages
- **Download speed**: Acceptable for replicators (<1 hour for 50GB)

### Secondary Metrics
- **Time savings**: Reduce researcher involvement in preprocessing
- **Error reduction**: Fewer failed GitHub Actions runs
- **Replicator satisfaction**: Easier access to packages

### Monitoring
- Track success/failure of remote preprocessing runs
- Log download times by package size
- Collect feedback from replicators and DE

---

## Alternatives Considered

### Alternative 1: Force Dropbox Sync More Aggressively
**Tried**: Current implementation attempts this
**Rejected**: Unreliable, no guarantee of success, race conditions

### Alternative 2: GitHub Releases (Upload packages)
**Pros**: Reliable downloads, version controlled
**Rejected**: 2GB file limit, 10GB release limit, doesn't work for 100GB packages

### Alternative 3: Cloud Storage Bridge (S3/GCS)
**Pros**: Scalable, reliable
**Rejected**: Additional cost, extra infrastructure, unnecessary complexity

### Alternative 4: Dropbox API Download (with token)
**Pros**: Official method, reliable
**Rejected**: 
- Token expires after 30 minutes
- Requires token refresh on runner
- More complex than password-protected links
- Requires Python/JPE.jl on runner

### Alternative 5: Public Dropbox Links (no password)
**Security Concerns**: Too risky for confidential data
**Rejected**: Doesn't meet security requirements

---

## Future Enhancements

### Enhancement 1: Automatic Link Revocation
After successful preprocessing, automatically revoke the shared link to minimize exposure window.

### Enhancement 2: Progress Monitoring
Stream download progress to GitHub Actions log for large packages.

### Enhancement 3: Link Expiration
Set automatic expiration (e.g., 7 days) on shared links as additional security.

### Enhancement 4: Parallel Downloads
For very large packages, split into chunks and download in parallel.

### Enhancement 5: Resume Support
If download fails, resume from last checkpoint rather than restart.

### Enhancement 6: Automatic Slack Password Sharing

**Status**: Future enhancement (manual copy/paste is MVP)

**Motivation**: Automate password delivery to replicators via Slack direct message during assignment, eliminating manual step.

**Implementation Overview**:

1. **Add Slack API Integration** (`src/slack_client.py`):
   ```python
   from slack_sdk import WebClient
   from slack_sdk.errors import SlackApiError

   def send_dm(token, user_email, message):
       """
       Send direct message to Slack user by email.
       
       Args:
           token: Slack bot token
           user_email: User's email (for lookup)
           message: Message text
       """
       client = WebClient(token=token)
       
       # Look up user by email
       response = client.users_lookupByEmail(email=user_email)
       user_id = response["user"]["id"]
       
       # Send DM
       result = client.chat_postMessage(
           channel=user_id,  # DM to user
           text=message
       )
       return result
   ```

2. **Julia Wrapper** (`src/slack.jl` - new file):
   ```julia
   function slack_send_dm(email, message)
       """
       Send Slack DM to replicator with password.
       
       Requires ENV["SLACK_BOT_TOKEN"].
       """
       token = ENV["SLACK_BOT_TOKEN"]
       try
           py"send_dm"(token, email, message)
           @info "✓ Slack DM sent to $email"
           return true
       catch e
           @error "Failed to send Slack DM" exception=e
           return false
       end
   end
   ```

3. **Modify `assign_replicators()`** (`src/actions.jl`):
   ```julia
   # After sending assignment email...
   
   # Retrieve password
   password = iteration.dropbox_password[1]
   
   if !ismissing(password)
       # Construct Slack message
       slack_message = """
   🔐 Password for $(r.paper_slug) Round $(selection.current_round)
   
   Password: $password
   
   Download link: $(dropbox_url)
   
   This password is required to access the replication package from the Dropbox link in your assignment email.
   """
       
       # Try automatic Slack delivery
       success = slack_send_dm(selection.primary_email, slack_message)
       
       if !success
           # Fallback to manual (current MVP approach)
           println()
           println("="^70)
           println("⚠️  Slack delivery failed - MANUAL ACTION REQUIRED")
           println("="^70)
           println("Send password to $(selection.primary_email) via Slack:")
           println("Password: $password")
           println("Press Enter when sent...")
           readline()
       else
           println("✓ Password automatically sent to replicator via Slack")
       end
   end
   ```

4. **Setup Requirements**:
   - Create Slack App in workspace
   - Add bot with scopes: `users:read.email`, `chat:write`
   - Install app to workspace
   - Get bot token → `ENV["SLACK_BOT_TOKEN"]`
   - Map replicator emails to Slack workspace
   - Add to `requirements.txt`: `slack-sdk>=3.0.0`

5. **Email-to-Slack Mapping**:
   - Replicators must use same email for Google Forms and Slack
   - Or maintain mapping table in database/Google Sheet
   - Slack API can look up users by email (requires email scope)

**Benefits**:
- ✅ Zero-click password delivery
- ✅ Consistent, never forgotten
- ✅ Timestamped audit trail in Slack
- ✅ Professional automated workflow
- ✅ Graceful fallback to manual if Slack fails

**Effort Estimate**: 4-6 hours
- Slack app setup: 1 hour
- Python/Julia integration: 2 hours
- Testing and error handling: 1-2 hours
- Documentation: 1 hour

**When to Implement**:
- After MVP proves password-protected links work
- If manual copy/paste becomes burdensome (>5 assignments/week)
- When Slack workspace is fully adopted by all replicators

---

## References

- **LLM.md**: Section "Dropbox 'Online Only' Problem"
- **DEVELOPERS.md**: Section "Proposed Enhancements #1"
- **src/preprocess.jl**: Current preprocessing implementation
- **Dropbox API**: https://www.dropbox.com/developers/documentation/http/documentation#sharing-create_shared_link_with_settings
- **GitHub Actions**: https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-11-03 | Use password-protected links | Best balance of security, reliability, simplicity |
| 2026-11-03 | Keep local preprocessing unchanged | Backward compatibility, fallback option |
| 2026-11-03 | Password via Slack, link via email | Two-factor security, separate channels |
| 2026-11-03 | Store password as GitHub secret | Secure, accessible to Actions, standard practice |

---

## Approval

**Proposed by**: AI Assistant  
**Status**: Awaiting approval  
**Next steps**: Review, test small implementation, iterate based on feedback
