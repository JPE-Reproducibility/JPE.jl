# Proposal: Public Dropbox Links for Remote Preprocessing

**Date**: 2026-11-03 (revised 2026-03-12)
**Status**: Implemented
**Priority**: High
**Complexity**: Low

---

## Executive Summary

Remote preprocessing of replication packages on GitHub Actions runners fails because macOS Dropbox "Files On-Demand" feature creates file stubs that don't materialise when accessed programmatically. This proposal replaces filesystem-based Dropbox access with HTTP downloads via public shared links.

**Previous state**: Unreliable remote preprocessing, limited to local execution for large packages
**Current state**: Reliable remote preprocessing via plain `curl` download from a public Dropbox link
**Breaking changes**: None (local preprocessing unchanged)

---

## Problem Statement

### The Challenge: Dropbox "Online Only" Files

1. macOS Dropbox uses "Files On-Demand" (aka "Smart Sync")
2. Files appear in the filesystem but aren't actually downloaded
3. These are stubs with `com.apple.fileprovider.stubbed` xattr
4. Opening files in GUI apps triggers download
5. **Programmatic access (scripts, GitHub Actions) does not reliably trigger download**

#### Current Workaround (src/preprocess.jl, runner_precheck.jl)

```julia
function force_download_directory(dirpath)
    for (root, dirs, files) in walkdir(dirpath)
        for file in files
            filepath = joinpath(root, file)
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

**Why this fails**: Dropbox File Provider doesn't guarantee materialisation on `open()`. Race conditions, no reliable completion detection, timeouts on large files.

---

## Implemented Solution: Public Shared Links

### Approach

**Instead of**: Relying on Dropbox filesystem access
**Use**: Direct HTTP download from Dropbox via a public shared link

Dropbox shared links work reliably via HTTP regardless of "online only" status. The link URL is unguessable (contains a random token), transmitted over HTTPS, and can be revoked at any time.

### Architecture

```
LOCAL MACHINE (macOS, Dropbox sync works)

  preprocess2(paperID)
    ↓
  1. Create public Dropbox shared link  (dbox_link_at_path)
  2. Store URL in _variables.yml        (dropbox_download_url)
  3. Commit & push to GitHub
         │
         │ GitHub Actions triggered
         ↓
GITHUB ACTIONS RUNNER (no Dropbox app)

  runner_precheck.jl
    ↓
  1. Read URL from _variables.yml
  2. curl -fsSL -o package.zip "$url"
  3. Unzip package
  4. Run PackageScanner.precheck_package()
  5. Commit results
```

### Benefits

- **No size limits**: Works with 100 GB+ packages (Dropbox handles delivery)
- **No Dropbox app needed**: Runner only needs `curl`
- **No token expiration**: Shared links don't expire like access tokens
- **No JPE.jl dependency on runner**: Runner is self-contained
- **Reliable**: Standard HTTP download
- **Backward compatible**: Local preprocessing unchanged
- **Simple runner**: Fewer dependencies, easier debugging

### Security Model

The link URL contains a random token and is transmitted over HTTPS. It is:

- Stored in `_variables.yml` in the (public) GitHub repo — acceptable because the URL is unguessable
- Shared with the human replicator in the assignment email
- Revocable via `revoke_preprocessing_link(paperID, round)` after preprocessing completes

Replicators sign confidentiality agreements as part of the assignment process.

---

## Implementation

### Key files changed

| File | Change |
|---|---|
| `src/preprocess.jl` | `dbox_create_password_link` → `dbox_link_at_path`; removed GitHub-secret prompt; updated `_variables.yml` fields |
| `src/preprocess.jl` (`write_runner_script`) | `curl -fsSL -o package.zip $url` (no `-u :$password`) |
| `src/preprocess.jl` (`revoke_preprocessing_link`) | reads `dropbox_download_url` instead of `dropbox_link_id` |
| `src/actions.jl` | call to `_show_dropbox_password_for_assignment` commented out |

### `_variables.yml` fields (runner-relevant)

```yaml
dropbox_download_url: "https://www.dropbox.com/sh/.../...?dl=1"  # public link, ready for curl
dropbox_rel_path: "JPE-Surname-12345678-R1"                       # local fallback
```

### Runner download (runner_precheck.jl)

```julia
url = get(vars, "dropbox_download_url", nothing)
if !isnothing(url)
    run(`curl -fsSL -o package.zip $url`)
end
```

If `dropbox_download_url` is absent the runner falls back to copying from the local Dropbox Apps folder (`JPE_DBOX_APPS`).

---

## Future Enhancement: Password-Protected Links

All code for password-protected Dropbox links is implemented and dormant. It can be activated if security requirements tighten (e.g., highly confidential data, institutional policy change).

### What is already in place

| Component | Location | Status |
|---|---|---|
| `create_password_protected_link(path, password, token)` | `src/db_filerequests.py` | Dormant |
| `revoke_shared_link(url, token)` | `src/db_filerequests.py` | Dormant |
| `dbox_create_password_link(path, password, token)` | `src/dropbox.jl` | Dormant |
| `dbox_revoke_link(url, token)` | `src/dropbox.jl` | Dormant |
| `_show_dropbox_password_for_assignment(paperID, round, email)` | `src/actions.jl` | Dormant (commented out) |
| `get_dropbox_password(paperID, round)` | `src/actions.jl` | Dormant |
| `dropbox_password` column | `iterations` table schema | In place |

### What activation requires

1. **`preprocess.jl`**: Replace `dbox_link_at_path` with `dbox_create_password_link`. Store the password in `iterations.dropbox_password`. Add `dropbox_password_secret` to `_variables.yml`. Add GitHub-secret prompt for the DE.

2. **`actions.jl`**: Uncomment the call to `_show_dropbox_password_for_assignment`. The function displays the password at assignment time so the DE can share it with the replicator via Slack (separate channel from the link, which travels in the assignment email).

3. **Runner**: The runner cannot use `curl -u :$password` — Dropbox password-protected links use a web-form flow, not HTTP Basic Auth. Two options:
   - Use the three Dropbox app credentials (`JPE_DBOX_APP`, `JPE_DBOX_APP_SECRET`, `JPE_DBOX_APP_REFRESH`) as GitHub org secrets. The runner first fetches a fresh access token via `curl` POST to `https://api.dropbox.com/oauth2/token`, then downloads using `Authorization: Bearer $token`. No Python SDK required.
   - Or set the org secrets once and use the Python Dropbox SDK on the runner (`sharing_get_shared_link_file(url, link_password=password)`).

   The token-refresh approach (option 1) is recommended: two `curl` calls, no extra dependencies, and the three org-level secrets are already known.

4. **Security model with passwords**: Link travels in assignment email; password travels via Slack DM. Two-factor: neither alone allows download. See the commented-out code in `preprocess.jl` and `actions.jl` for the full flow. Each activation point is marked with a `# SECURITY UPGRADE PATH (dormant):` comment.
