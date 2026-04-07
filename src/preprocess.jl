
function preprocess2(paperID; which_round = nothing, max_pkg_size_gb = 10, max_file_size_gb = 2, run_checks = true)
        
    # get row from "iterations"
    p = db_filter_paper(paperID)
    round = if isnothing(which_round)
        p.round[1]
    else
        which_round
    end
    @info "preprocessing $paperID round $round"

    rt = db_filter_iteration(paperID, round)
    if nrow(rt) != 1
        error("can only get a single row here")
    end
    r = rt[1,:] # dataframerow

    # create a temp dir
    d = tempdir()
    repoloc = joinpath(d, string(paperID, "-", round))
    o = pwd()
    cd(d)

    # clone branch current "round"
    gh_clone_branch(r.gh_org_repo, "round$(round)", to = repoloc)

    # check size of replication packge on dropbox and decide what to do
    r.file_request_path_full = get_dbox_loc(r.journal, r.paper_slug, r.round, full = false)
    size_gb = dbox_get_folder_size(joinpath(r.file_request_path_full, "replication-package"))

    @info "package has $size_gb GB on dropbox."

    if size_gb > max_pkg_size_gb
        @info "Package exceeds max_pkg_size_gb ($max_pkg_size_gb GB)."
        println(">>> Want to show file listing? needs to sync dropbox first...")
        show_prompt = RadioMenu(["Yes","No"])
        if request(show_prompt) == 1
            pkg_path = joinpath(get_dbox_loc(r.journal, r.paper_slug, round, full = true), "replication-package")
            browse_package_contents(pkg_path)
        end
    end

    println("To disregard extracting very large files from zip, we have a safeguard:")
    println("max_file_size_gb is currently $(max_file_size_gb). Keep or change?")
    max_size_prompt = RadioMenu(["keep","change"])
    if request(max_size_prompt) == 2
        println("new value for max_file_size_gb:")
        max_file_size_gb = parse(Float64, readline())
    end

    println()
    println("any paths to exclude from data scanning?")
    scan_prompt = RadioMenu(["no - scan all","yes"])
    if request(scan_prompt) == 2
        println("give comma separated list of paths to exclude like")
        println("/path/one, /path/two, /path/three [no quotes]")
        no_data_scan = split(readline(), ",") .|> strip .|> String
        append!(no_data_scan, ["__MACOSX","renv"])
        @info "will no scan paths in $(no_data_scan)"
    else
        no_data_scan = ["__MACOSX","renv"]
    end


    
    # Create a public Dropbox shared link for the runner (and replicators) to
    # download the replication package via plain curl — no credentials needed.
    #
    # SECURITY UPGRADE PATH (dormant):
    #   To switch to password-protected links (two-factor security), replace
    #   dbox_link_at_path below with dbox_create_password_link, store the
    #   returned password in the DB (iterations.dropbox_password), add the
    #   dropbox_password_secret field to _variables.yml, and re-enable the 
    #   call to _show_dropbox_password_for_assignment in actions.jl.
    #   See PROPOSAL.md for the full spec.
    dropbox_path = "/" * joinpath(r.journal, r.paper_slug, string(r.round), "replication-package")
    @info "Creating public Dropbox link for $dropbox_path"
    link_url = dbox_link_at_path(dropbox_path, dbox_token, expiry = 10)

    # Create _variables.yml with all necessary info for the runner
    open(joinpath(repoloc, "_variables.yml"), "w") do io
        println(io, "title: \"$(r.title)\"")
        println(io, "author: \"$(r.surname_of_author)\"")
        println(io, "round: $(round)")
        println(io, "repo: \"$(r.github_url)\"")
        println(io, "paper_id: $(r.paper_id)")
        println(io, "journal: \"$(r.journal)\"")
        println(io, "paper_slug: \"$(r.paper_slug)\"")
        # Local fallback path (for local preprocessing)
        println(io, "dropbox_rel_path: \"$(get_case_id(r.journal, r.paper_slug, r.round))\"")
        println(io, "package_size_gb: $(size_gb)")
        println(io, "package_max_file_size_gb: $(max_file_size_gb)")
        println(io, "package_max_pkg_size_gb: $(max_pkg_size_gb)")
    end

    # add a run badge to the README and change title
    update_readme(joinpath(repoloc,"README.md"), r.gh_org_repo, "# $(get_case_id(r.journal, r.paper_slug, r.round))")

    # Create runner script
    write_runner_script(repoloc, no_data_scan)
    
    println("Where to preprocess this?")
    local_remote = RadioMenu(["local","gh-runner"])
    if request(local_remote) == 1 # local
        runner_env = ENV["JULIA_RUNNER_ENV"]
        runner_script = joinpath(repoloc,"runner_precheck.jl")

        if run_checks
            # in a new julia process
            cmd = Cmd([
                "julia",
                "--project=$runner_env", "$runner_script"
            ])
            withenv("SHELL" => "/opt/homebrew/bin/fish", 
                    "GITHUB_WORKSPACE" => "$repoloc",
                    "DROPBOX_DOWNLOAD_URL" => replace(link_url, "dl=0" => "dl=1")) do
                res = chomp(read(run(Cmd(cmd)),String))
            end
            @info "✓ Preprocess complete for paper $paperID round $round"
        else
            @info "run_checks=false — skipping local runner script"
        end

        # commit all except data
        branch = chomp(read(Cmd(`git rev-parse --abbrev-ref HEAD`,dir = repoloc), String))
        commit_msg = run_checks ? "🚀 prechecks round $(round)" : "📁 setup only (no checks) round $(round)"
        cmd = """
        git add .
        git commit -m '$commit_msg'
        git push origin $branch
        """
        @show gr = read(Cmd(`sh -c $cmd`, dir=repoloc),String)

    else
        # runner
        # set secret on the repo before pushing
        run(`gh secret set DROPBOX_DOWNLOAD_URL --body $(replace(link_url, "dl=0" => "dl=1")) --repo $(r.gh_org_repo)`)
    
        branch = "round$(round)"
        commit_msg = run_checks ? "[trigger remote] for round $(round) 🎯" : "📁 setup only (no remote trigger) round $(round)"
        cmd = """
        git add _variables.yml runner_precheck.jl README.md
        git commit -m '$commit_msg'
        git push origin $branch
        """
        run(Cmd(`sh -c $cmd`, dir=repoloc))

        if run_checks
            @info "Monitor workflow at: $(r.github_url)/actions"
        else
            @info "run_checks=false — files pushed, no remote workflow triggered"
        end
    end

    cd(o) # go back

    # * Delete local repo
    run(`chmod -R u+rwX $repoloc`)
    rm(repoloc, recursive=true, force=true)
end


function update_readme(filepath::String, gh_org_repo::String, new_header::String)
    lines = readlines(filepath)
    
    badge_url = "https://github.com/$gh_org_repo/actions/workflows/precheck.yml"
    badge = "[![Run Precheck]($badge_url/badge.svg)]($badge_url)"
    
    # replace first line with new header
    lines[1] = new_header

    # insert the badge and blank lines only if it's not there already.
    if !(lines[3] == badge)
        insert!(lines, 2, "")
        insert!(lines, 3, badge)
    end
    
    # write out new readme.
    open(filepath, "w") do io
        join(io, lines, "\n")
    end

end



"""
Write the runner_precheck.jl script to the repository location.
This script will be executed by the chosen runner (local or GitHub Actions).

For remote execution the script downloads the replication package via a
plain curl call to a public Dropbox shared link stored in `_variables.yml`.
A local-copy fallback is retained for local preprocessing runs.

SECURITY UPGRADE PATH (dormant): to switch to password-protected download,
re-enable the password block in this function and in preprocess2(). See
PROPOSAL.md for the full spec.
"""
function write_runner_script(repoloc::String, no_data_scan::Vector{String})
    open(joinpath(repoloc, "runner_precheck.jl"), "w") do io
        write(io, """
        using YAML
        using PackageScanner

        # Read configuration
        vars = YAML.load_file(joinpath(ENV["GITHUB_WORKSPACE"], "_variables.yml"))
        @info "Configuration loaded" vars

        dest_path = joinpath(ENV["GITHUB_WORKSPACE"], "replication-package")

        # ── Remote path: download via public Dropbox link ─────────────────────
        url = get(ENV, "DROPBOX_DOWNLOAD_URL", nothing)

        downloaded_ok = if !isnothing(url)
            @info "Downloading package from secret Dropbox link..."
            t0 = time()
            try
                run(`curl -fsSL -o package.zip \$url`)
                @info "Download complete in \$(round(time()-t0, digits=1))s"
                true
            catch e
                @error "curl download failed, will try local fallback" exception=e
                false
            end
        else
            @info "No remote link configured — using local Dropbox path"
            false
        end

        # ── Local fallback: copy from Dropbox Apps folder ─────────────────────
        if !downloaded_ok
            source_path = joinpath(ENV["JPE_DBOX_APPS"], vars["dropbox_rel_path"], "replication-package")
            @info "Copying package from local Dropbox..." source_path
            if !isdir(source_path)
                error("Package not found at \$source_path")
            end
            isdir(dest_path) && rm(dest_path; recursive=true, force=true)
            PackageScanner.mycp(source_path, dest_path; recursive=true, force=true)
            @info "✓ Package copied from local Dropbox"
        end

        # ── Unzip downloaded archive (remote path only) ───────────────────────
        if downloaded_ok && isfile("package.zip")
            @info "Unzipping Dropbox folder archive..."
            tmp_dir = mktempdir()
            try
                run(`unzip -oq package.zip -d \$tmp_dir`)
            catch e
                @warn "unzip exited non-zero (may still be okay)" exception=e
            end
            rm("package.zip"; force=true)

            # Find all ZIPs inside the Dropbox folder
            candidates = filter(readdir(tmp_dir; join=true)) do f
                isfile(f) && endswith(lowercase(f), ".zip")
            end

            if isempty(candidates)
                error("No ZIP file found inside Dropbox folder archive")
            end

            @info "Found \$(length(candidates)) ZIP(s) to extract" candidates
            isdir(dest_path) && rm(dest_path; recursive=true, force=true)
            mkpath(dest_path)

            for pkg_zip in candidates
                @info "Unzipping \$pkg_zip..."
                try
                    run(`unzip -oq \$pkg_zip -d \$dest_path`)
                    if isdir(\$dest_path)
                        rm_git(\$dest_path)
                    end
                catch e
                    @warn "unzip of \$pkg_zip exited non-zero" exception=e
                end
            end

            rm(tmp_dir; recursive=true, force=true)
            @info "✓ Unzip complete"
        end

        if !isdir(dest_path)
            error("Package directory not found at \$dest_path after download/copy step")
        end

        # ── PackageScanner precheck ────────────────────────────────────────────
        pkg_size     = vars["package_size_gb"]
        max_pkg_size = vars["package_max_pkg_size_gb"]
        max_file_size = vars["package_max_file_size_gb"]

        if pkg_size > max_pkg_size
            @info "Package >\$(max_pkg_size) GB — using partial extraction mode"
            pkg_dir, manifest = PackageScanner.prepare_package_for_precheck(
                dest_path, size_threshold_gb=max_file_size, interactive=false)
            PackageScanner.precheck_package(pkg_dir, pre_manifest=manifest,
                                            no_data_scan=$(no_data_scan))
        else
            @info "Unzipping files in \$dest_path"
            try
                zips = PackageScanner.read_and_unzip_directory(dest_path)
                @info "Unzipped \$(length(zips)) file(s)"
            catch e
                @warn "Unzip had issues (may be okay)" exception=e
            end
            @info "Running precheck on \$dest_path"
            PackageScanner.precheck_package(dest_path, no_data_scan=$(no_data_scan))
            @info "✓ Precheck complete"
        end
        """)
    end
    @info "Created runner_precheck.jl at $repoloc"
end


"""
    revoke_preprocessing_link(paperID, round)

Revoke the public Dropbox shared link that was created during `preprocess2()`.
Call this after remote preprocessing finishes successfully to close the link.
"""
function revoke_preprocessing_link(paperID, round)
    rt = db_filter_iteration(paperID, round)
    if nrow(rt) != 1
        error("No iteration found for $paperID round $round")
    end
    r = rt[1, :]

    # Retrieve link id from the cloned repo's _variables.yml
    # (we re-use the local temp clone path convention from preprocess2)
    d = tempdir()
    repoloc = joinpath(d, string(paperID, "-", round))

    vars_path = joinpath(repoloc, "_variables.yml")
    if !isfile(vars_path)
        # Try to clone it fresh
        gh_clone_branch(r.gh_org_repo, "round$(round)", to=repoloc)
        vars_path = joinpath(repoloc, "_variables.yml")
    end

    if !isfile(vars_path)
        @warn "Could not find _variables.yml — cannot revoke link automatically"
        return
    end

    # Parse the download URL from _variables.yml (strip ?dl=1 for revocation)
    link_url = nothing
    for line in eachline(vars_path)
        m = match(r"^dropbox_download_url:\s*\"?(.+?)\"?\s*$", line)
        if !isnothing(m)
            link_url = replace(m.captures[1], r"\?dl=\d$" => "")
            break
        end
    end

    if isnothing(link_url) || isempty(link_url)
        @warn "No dropbox_download_url in _variables.yml for $paperID R$round"
        return
    end

    @info "Revoking Dropbox shared link for $paperID R$round..."
    dbox_revoke_link(link_url, dbox_token)
    @info "✓ Link revoked"
end