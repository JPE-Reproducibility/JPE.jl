
function preprocess(paperID; which_round = nothing, max_pkg_size_gb = 10, max_file_size_gb = 2, run_checks = true,
                     run_claims_extraction::Union{Nothing,Bool} = nothing, run_crosscheck::Bool = true)
        
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

    # a previous run may have left a local repo here (e.g. it crashed after
    # fetching the package but before pushing) — offer to reuse it instead of
    # blindly wiping and re-cloning, which would force a full re-download.
    existing_repo = isdir(repoloc) && isdir(joinpath(repoloc, ".git"))
    existing_package = existing_repo &&
        isdir(joinpath(repoloc, "replication-package")) &&
        !isempty(readdir(joinpath(repoloc, "replication-package")))
    reuse_repo = false
    if existing_repo
        println(">>> found existing local repo at $repoloc" * (existing_package ? " (package already fetched)" : ""))
        reuse_menu = RadioMenu(["reuse existing (skip re-clone/re-fetch)", "start fresh (delete & redo)"])
        reuse_repo = request(reuse_menu) == 1
    end

    cd(d)

    # clone branch current "round" (skipped when reusing an existing local repo)
    if !reuse_repo
        gh_clone_branch(r.gh_org_repo, "round$(round)", to = repoloc)
    end
    # NOTE: a previous preprocessing round may have left replication-package/
    # content committed on this branch (whatever wasn't .gitignore'd). We
    # deliberately do NOT clear it here: for gh-runner mode nothing in this
    # local clone re-fetches the package before the trigger push, so wiping
    # it here would just push a commit that deletes the previously-committed
    # code. It's only cleared (below, in the `local` branch) right before a
    # genuine local re-fetch, where it would otherwise let
    # runner_precheck.jl's "already_have_package" check skip that fetch.

    # Stage C claims extraction (JPE-Reproducibility/JPE.jl#29, folded into
    # the runner script itself by JPE-Reproducibility/JPE.jl#34 -- it used to
    # run here, eagerly, straight off the local Dropbox paper-appendices/
    # paper-author dirs, which meant it only ever worked in `local` mode and
    # needed a manual return trip in `gh-runner` mode. Now it runs inside
    # write_runner_script's generated script, against paper-source/ (fetched
    # by that same script, see the Dropbox link block below), so one
    # preprocess() call does it in either mode. Only the decision of
    # *whether* to run it stays here: skip if claims.json is already in this
    # round's cloned repo, else default on for round 1, else ask. An explicit
    # run_claims_extraction=true/false always wins.
    claims_cached = isfile(joinpath(repoloc, "generated", "claims.json"))
    do_claims = if !isnothing(run_claims_extraction)
        run_claims_extraction
    elseif claims_cached
        false
    elseif round == 1
        true
    else
        println(">>> Run paper claims extraction (Stage C) for $paperID round $round?")
        request(RadioMenu(["Yes", "No"])) == 1
    end

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

    # Automated referee review (refine.ink). Deliberately decoupled from the
    # rest of preprocess(): it's a slow (5-20+ min) external call that's
    # checked back on later via check_referee_reviews(), not something the
    # local/gh-runner branches below wait on -- so a failure here is a
    # warning, not a reason to abort preprocessing.
    println()
    println(">>> Request automated referee review via refine.ink for $paperID round $round?")
    refine_prompt = RadioMenu(["Yes","No"])
    if request(refine_prompt) == 1
        try
            request_referee_review(paperID, round)
            @info "⏳ remember to run check_referee_reviews() later (e.g. once a day, alongside monitor_file_requests()) to pick up the result"
        catch e
            @warn "Could not request referee review from refine.ink" exception=e
        end
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
    link_url = dbox_link_at_path(dropbox_path, dbox_token, expiry = 15)
    isnothing(link_url) && error("dbox_link_at_path returned nothing for $dropbox_path — check Dropbox credentials and path")

    # Same mechanism, second link: the paper's LaTeX source, so the runner
    # (local or gh-runner) can fetch it too, not just the replication package.
    # Prefer paper-author/ (clean author upload, #30) if it has any .tex,
    # else fall back to paper-appendices/ (pre-#30 papers). See
    # JPE-Reproducibility/JPE.jl#34.
    author_subpath = "/" * joinpath(r.journal, r.paper_slug, string(r.round), "paper-author")
    appendices_subpath = "/" * joinpath(r.journal, r.paper_slug, string(r.round), "paper-appendices")
    author_dir_full = string(ENV["JPE_DBOX_APPS"], author_subpath)
    appendices_dir_full = string(ENV["JPE_DBOX_APPS"], appendices_subpath)
    chosen_paper_dir = find_paper_source_dir(author_dir_full, appendices_dir_full)
    paper_source_subfolder = chosen_paper_dir == author_dir_full ? "paper-author" : "paper-appendices"
    paper_dropbox_path = chosen_paper_dir == author_dir_full ? author_subpath : appendices_subpath
    @info "Creating public Dropbox link for $paper_dropbox_path"
    paper_link_url = dbox_link_at_path(paper_dropbox_path, dbox_token, expiry = 15)
    isnothing(paper_link_url) && error("dbox_link_at_path returned nothing for $paper_dropbox_path — check Dropbox credentials and path")

    # Permanent (no expiry) shared link to a per-round Dropbox folder that holds
    # full copies of any generated report file too large to embed in the repo
    # (e.g. a file listing capped by write_runner_script). Repos are private and
    # authors are never given repo/org access, so this Dropbox link is how they
    # actually see the full list -- the GitHub Actions artifact it used to point
    # to also expired after 90 days regardless of repo visibility.
    # `upload_text` on a not-yet-existing path creates the folder server-side,
    # so the link can be created immediately without waiting on Dropbox desktop
    # sync.
    large_reports_path = "/" * joinpath(r.journal, r.paper_slug, string(r.round), "large-reports")
    dbox_upload_text(joinpath(large_reports_path, ".keep"), "placeholder", dbox_token)
    large_reports_url = dbox_link_at_path(large_reports_path, dbox_token)
    isnothing(large_reports_url) && error("dbox_link_at_path returned nothing for $large_reports_path — check Dropbox credentials and path")

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
        println(io, "large_reports_url: \"$(large_reports_url)\"")
        println(io, "paper_source_subfolder: \"$(paper_source_subfolder)\"")
    end

    # add a run badge to the README and change title
    update_readme(joinpath(repoloc,"README.md"), r.gh_org_repo, "# $(get_case_id(r.journal, r.paper_slug, r.round))")

    # Keep this repo's report template & CI workflow current with JPEtemplate.
    # Paper repos are only templated once, at creation (`gh repo create
    # --template ...`), and every subsequent round branches off the
    # *previous* round's branch, never off JPEtemplate again -- so without
    # this, template fixes never reach an already-created paper.
    sync_template_files!(repoloc)

    # Create runner script
    write_runner_script(repoloc, no_data_scan, run_checks = run_checks, do_claims = do_claims,
                         do_crosscheck = run_crosscheck && round == 1)

    # git branches
    branch = gh_get_default_branch(r.gh_org_repo)

    println(">>> Update the Default branch from $branch to round$(r.round)?")
    updb = RadioMenu(["yes","no"])
    if request(updb) == 1 # yes
        gh_set_default_branch(r.gh_org_repo, "round$(r.round)")
    else
        println("default branch left at $branch")
    end
    
    println("Where to preprocess this?")
    local_remote = RadioMenu(["local","gh-runner"])
    choice = request(local_remote)
    preprocess_mode = choice == 1 ? "local" : "gh-runner"
    db_update_cell("iterations", "paper_id = '$paperID' AND round = $round", "preprocess_mode", preprocess_mode)
    if choice == 1 # local
        # A fresh clone (not a same-session crash-recovery reuse) may still
        # carry a stale, incomplete replication-package/ from a previous
        # round's commit. Clear it now, right before the genuine re-fetch
        # below, so "already_have_package" can't be satisfied by that stale
        # copy -- see the NOTE above the clone for why this isn't done earlier.
        if !reuse_repo
            stale_package = joinpath(repoloc, "replication-package")
            isdir(stale_package) && rm(stale_package, recursive=true, force=true)
        end

        runner_env = ENV["JULIA_RUNNER_ENV"]
        runner_script = joinpath(repoloc,"runner_precheck.jl")

        # always run the script to fetch/copy the replication package;
        # run_checks only controls whether PackageScanner.precheck_package runs (see write_runner_script)
        cmd = Cmd([
            "julia",
            "--project=$runner_env", "$runner_script"
        ])
        withenv("SHELL" => "/opt/homebrew/bin/fish",
                "GITHUB_WORKSPACE" => "$repoloc",
                "DROPBOX_DOWNLOAD_URL" => replace(link_url, "dl=0" => "dl=1"),
                "PAPER_DOWNLOAD_URL" => replace(paper_link_url, "dl=0" => "dl=1")) do
            res = chomp(read(run(Cmd(cmd)),String))
        end
        if run_checks
            @info "✓ Preprocess complete for paper $paperID round $round"
        else
            @info "✓ Package fetched for paper $paperID round $round — precheck skipped (run_checks=false)"
        end

        # commit all except data
        branch = chomp(read(Cmd(`git rev-parse --abbrev-ref HEAD`,dir = repoloc), String))
        commit_msg = run_checks ? "🚀 prechecks round $(round)" : "📁 setup only (no checks) round $(round)"
        cmd = """
        git add .
        [ -s generated/force-add-files.txt ] && while IFS= read -r f; do git add -f -- "\$f"; done < generated/force-add-files.txt
        git commit -m '$commit_msg'
        git push origin $branch
        """
        @show gr = read(Cmd(`sh -c $cmd`, dir=repoloc),String)

    else
        # runner
        # set secret on the repo before pushing
        run(`gh secret set DROPBOX_DOWNLOAD_URL --body $(replace(link_url, "dl=0" => "dl=1")) --repo $(r.gh_org_repo)`)
        run(`gh secret set PAPER_DOWNLOAD_URL --body $(replace(paper_link_url, "dl=0" => "dl=1")) --repo $(r.gh_org_repo)`)
    
        branch = chomp(read(Cmd(`git rev-parse --abbrev-ref HEAD`,dir = repoloc), String))
        # The remote workflow must always run so the runner fetches the
        # package and commits the code/docs subset back to the branch --
        # that's independent of whether checks run. run_checks only
        # controls whether runner_precheck.jl's PackageScanner step executes
        # (baked into the script by write_runner_script above); the commit
        # message here must keep the "[trigger remote]" marker in both
        # cases so precheck.yml's `if:` picks up the push. (It must NOT
        # appear in the runner's own result-commit message, or every push
        # would re-trigger the workflow in a loop.)
        commit_msg = run_checks ? "[trigger remote] for round $(round) 🎯" : "[trigger remote] (setup only, no checks) round $(round) 📁"
        cmd = """
        git add .
        git commit -m '$commit_msg'
        git push origin $branch
        """
        run(Cmd(`sh -c $cmd`, dir=repoloc))

        @info "Monitor workflow at: $(r.github_url)/actions"
        if !run_checks
            @info "run_checks=false — the runner will still fetch & commit the package, but PackageScanner precheck will be skipped"
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
    sync_template_files!(repoloc::String)

Overwrite `TEMPLATE.qmd` and `.github/workflows/precheck.yml` in `repoloc`
with the current versions from `JPE-Reproducibility/JPEtemplate` main, via
the GitHub API (so it works the same whether run locally or on the
self-hosted runner, no local JPEtemplate clone required).

Best-effort: a fetch failure (e.g. transient network issue) is warned and
skipped per-file rather than aborting preprocessing, since the fallback is
simply the status quo (whatever version the repo already has).
"""
function sync_template_files!(repoloc::String)
    for relpath in ("TEMPLATE.qmd", joinpath(".github", "workflows", "precheck.yml"))
        try
            content = read(`gh api -H "Accept: application/vnd.github.raw" repos/JPE-Reproducibility/JPEtemplate/contents/$relpath`, String)
            destpath = joinpath(repoloc, relpath)
            mkpath(dirname(destpath))
            write(destpath, content)
            @info "✓ Synced $relpath from JPEtemplate main"
        catch e
            @warn "Could not sync $relpath from JPEtemplate main — leaving existing version in place" exception=e
        end
    end
    sync_gitignore!(repoloc)
end

"""
    sync_gitignore!(repoloc::String)

Merge any `.gitignore` rules from `JPE-Reproducibility/JPEtemplate` main that
this repo's `.gitignore` doesn't already have, appending the missing lines
rather than overwriting the file outright (a paper repo could in principle
have its own legitimate additions). This is what back-fills new exclusion
rules -- e.g. `paper-source/**`, added after some paper repos were already
created from an older template -- into already-existing repos, which
`sync_template_files!`'s other two files don't need (they're always fully
regenerated, never hand-edited per-repo).

Best-effort, same reasoning as `sync_template_files!`: a fetch failure is
warned and skipped rather than aborting preprocessing.
"""
function sync_gitignore!(repoloc::String)
    try
        upstream = read(`gh api -H "Accept: application/vnd.github.raw" repos/JPE-Reproducibility/JPEtemplate/contents/.gitignore`, String)
        destpath = joinpath(repoloc, ".gitignore")
        existing_lines = isfile(destpath) ? Set(readlines(destpath)) : Set{String}()
        missing = [line for line in split(upstream, '\n') if !isempty(strip(line)) && !(line in existing_lines)]
        if !isempty(missing)
            open(destpath, "a") do io
                println(io, "")
                println(io, "# synced from JPEtemplate main (sync_gitignore!)")
                for line in missing
                    println(io, line)
                end
            end
            @info "✓ Appended $(length(missing)) missing .gitignore rule(s) from JPEtemplate main"

            # A new ignore rule only stops *future* untracked files from being
            # added -- it does nothing for paths some earlier round already
            # committed before this rule existed (exactly what happened to
            # paper-source/ on repos created before JPE-Reproducibility/JPE.jl#34
            # added that rule upstream). Untrack any newly-ignored directory
            # pattern that's already tracked, so the next commit actually
            # drops it instead of silently keeping it staged forever.
            for line in missing
                dirname_match = match(r"^([^#!*][^/]*)/\*{0,2}$", line)
                isnothing(dirname_match) && continue
                dir = dirname_match.captures[1]
                try
                    run(Cmd(`git rm -r --cached --ignore-unmatch -q $dir`, dir = repoloc))
                catch e
                    @warn "Could not untrack $dir after gitignore sync" exception=e
                end
            end
        end
    catch e
        @warn "Could not sync .gitignore from JPEtemplate main — leaving existing version in place" exception=e
    end
end

"""
Write the runner_precheck.jl script to the repository location.
This script will be executed by the chosen runner (local or GitHub Actions).

For remote execution the script downloads the replication package via a
plain curl call to a public Dropbox shared link stored in `_variables.yml`.
A local-copy fallback is retained for local preprocessing runs.

If `do_claims` is true, the script also runs Stage C claims extraction
(JPE-Reproducibility/JPE.jl#34) against whatever landed in `paper-source/`
right above: `claims.json` already present means "skip" (no force-rerun from
here -- use `extract_paper_claims(...; force=true)` manually for that), an
ambiguous or missing `.tex` source means "skip and write
generated/report-claims-extraction.md explaining why" (no interactive
disambiguation is possible in an unattended script -- same reasoning as the
rest of this unattended run).

If `do_crosscheck` is true, the script also runs Stage D crosscheck
(JPE-Reproducibility/JPE.jl#38) right after Stage A/C, matching claims.json
against Stage A/B's findings. Folded into this same script (rather than a
separate DE-triggered call) so it lands on disk before either runner commits
its results -- `git add .` (here for local mode, or precheck.yml's "Commit
and push results" step for gh-runner mode) picks it up automatically,
matching how Stage C's claims.json already gets committed. Requires
claims.json to exist (i.e. `do_claims` must also be true and have succeeded);
silently does nothing otherwise.

SECURITY UPGRADE PATH (dormant): to switch to password-protected download,
re-enable the password block in this function and in preprocess(). See
PROPOSAL.md for the full spec.
"""
function write_runner_script(repoloc::String, no_data_scan::Vector{String}; run_checks::Bool = true, do_claims::Bool = false,
                              do_crosscheck::Bool = false)
    claims_helpers_src = read(joinpath(@__DIR__, "claims_runner_helpers.jl"), String)
    crosscheck_helpers_src = read(joinpath(@__DIR__, "crosscheck_runner_helpers.jl"), String)
    open(joinpath(repoloc, "runner_precheck.jl"), "w") do io
        write(io, """
        using YAML
        using PackageScanner
        using JSON
        using Dates

        function rm_git(extract_dir)
            for (root, dirs, files) in walkdir(extract_dir)
                if ".git" in dirs
                    git_path = joinpath(root, ".git")
                    @info "Removing git repository: \$git_path"
                    rm(git_path, recursive=true, force=true)
                    filter!(d -> d != ".git", dirs)
                    return 0
                end
            end
        end

        # Read configuration
        vars = YAML.load_file(joinpath(ENV["GITHUB_WORKSPACE"], "_variables.yml"))
        @info "Configuration loaded" vars

        dest_path = joinpath(ENV["GITHUB_WORKSPACE"], "replication-package")

        # ── Skip fetch entirely if package is already present locally ─────────
        already_have_package = isdir(dest_path) && !isempty(readdir(dest_path))

        # ── Remote path: download via public Dropbox link ─────────────────────
        url = let u = get(ENV, "DROPBOX_DOWNLOAD_URL", nothing)
            (isnothing(u) || isempty(u)) ? nothing : u
        end

        downloaded_ok = if already_have_package
            @info "Package already present at \$dest_path — skipping download/copy"
            true
        elseif !isnothing(url)
            @info "Downloading package from secret Dropbox link..."
            t0 = time()
            try
                run(`curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 -C - -o package.zip \$url`)
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

            isdir(dest_path) && rm(dest_path; recursive=true, force=true)
            mkpath(dest_path)

            if isempty(candidates)
                # No nested ZIP — the author's Dropbox folder contained the
                # replication package's files/subfolders directly (not a .zip),
                # so the extracted tmp_dir already *is* the package.
                @info "No nested ZIP found — using extracted folder contents directly as the package"
                for f in readdir(tmp_dir; join=true)
                    cp(f, joinpath(dest_path, basename(f)); force=true)
                end
                rm_git(dest_path)
            else
                @info "Found \$(length(candidates)) ZIP(s) to extract" candidates

                for pkg_zip in candidates
                    @info "Unzipping \$pkg_zip..."
                    try
                        run(`unzip -oq \$pkg_zip -d \$dest_path`)
                        if isdir(dest_path)
                            rm_git(dest_path)
                        end
                    catch e
                        @warn "unzip of \$pkg_zip exited non-zero" exception=e
                    end
                end
            end

            rm(tmp_dir; recursive=true, force=true)
            @info "✓ Unzip complete"
        end

        if !isdir(dest_path)
            error("Package directory not found at \$dest_path after download/copy step")
        end

        # ── Fetch the paper source (mirrors the replication-package fetch above) ──
        # See JPE-Reproducibility/JPE.jl#34. Fetches whichever folder preprocess()
        # chose (paper_source_subfolder in _variables.yml: paper-author/ if the
        # author uploaded one, #30, else the legacy paper-appendices/) into
        # paper-source/ in the workspace. Best-effort: failures here must not
        # abort the package precheck, which is the primary purpose of this run --
        # Stage C/D consumers just see no paper-source/ and skip accordingly.
        paper_dest_path = joinpath(ENV["GITHUB_WORKSPACE"], "paper-source")
        already_have_paper = isdir(paper_dest_path) && !isempty(readdir(paper_dest_path))

        paper_url = let u = get(ENV, "PAPER_DOWNLOAD_URL", nothing)
            (isnothing(u) || isempty(u)) ? nothing : u
        end

        paper_downloaded_ok = if already_have_paper
            @info "Paper source already present at \$paper_dest_path — skipping download/copy"
            true
        elseif !isnothing(paper_url)
            @info "Downloading paper source from secret Dropbox link..."
            try
                run(`curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 -C - -o paper.zip \$paper_url`)
                true
            catch e
                @warn "paper source curl download failed, will try local fallback" exception=e
                false
            end
        else
            @info "No remote paper link configured — using local Dropbox path"
            false
        end

        if !paper_downloaded_ok
            try
                paper_source_path = joinpath(ENV["JPE_DBOX_APPS"], vars["dropbox_rel_path"], vars["paper_source_subfolder"])
                if isdir(paper_source_path)
                    isdir(paper_dest_path) && rm(paper_dest_path; recursive=true, force=true)
                    PackageScanner.mycp(paper_source_path, paper_dest_path; recursive=true, force=true)
                    @info "✓ Paper source copied from local Dropbox"
                else
                    @warn "Paper source not found at \$paper_source_path — skipping (no paper available for Stage C)"
                end
            catch e
                @warn "Could not fetch paper source — skipping (no paper available for Stage C)" exception=e
            end
        elseif isfile("paper.zip")
            @info "Unzipping paper source archive..."
            tmp_dir = mktempdir()
            try
                run(`unzip -oq paper.zip -d \$tmp_dir`)
            catch e
                @warn "unzip of paper source exited non-zero (may still be okay)" exception=e
            end
            rm("paper.zip"; force=true)

            isdir(paper_dest_path) && rm(paper_dest_path; recursive=true, force=true)
            mkpath(paper_dest_path)
            for f in readdir(tmp_dir; join=true)
                cp(f, joinpath(paper_dest_path, basename(f)); force=true)
            end
            rm_git(paper_dest_path)
            rm(tmp_dir; recursive=true, force=true)
            @info "✓ Paper source unzip complete"
        end

        # ── Stage C: LLM claims extraction (JPE-Reproducibility/JPE.jl#34) ────
        # Shared helpers (claude CLI invocation, prompt, JSON schema) are
        # spliced in verbatim from claims_runner_helpers.jl -- see JPE.jl's
        # write_runner_script for the single source of truth.
        $(claims_helpers_src)

        # ── Stage D: claims-vs-package crosscheck (JPE-Reproducibility/JPE.jl#38) ──
        # Shared helpers spliced in verbatim from crosscheck_runner_helpers.jl,
        # same reasoning as Stage C above. Only the prompt/schema/cmd/scoring
        # functions are defined here -- the actual Stage D run happens below,
        # after Stage A has produced report-data-dependencies.md.
        $(crosscheck_helpers_src)

        if $(do_claims)
            claims_dir = joinpath(ENV["GITHUB_WORKSPACE"], "generated")
            mkpath(claims_dir)
            claims_json_path = joinpath(claims_dir, "claims.json")
            claims_report_path = joinpath(claims_dir, "report-claims-extraction.md")

            if isfile(claims_json_path)
                @info "claims.json already exists — skipping Stage C re-extraction"
            elseif !isdir(paper_dest_path) || isempty(readdir(paper_dest_path))
                @warn "no paper source available — skipping Stage C claims extraction"
                open(claims_report_path, "w") do rio
                    println(rio, "# Stage C: Claims Extraction")
                    println(rio, "")
                    println(rio, "**Skipped**: no paper source was available (`paper-source/` empty or missing).")
                end
            else
                tex_result = PackageScanner.extract_latex_text(paper_dest_path)
                if tex_result.ambiguous
                    @warn "ambiguous paper source — multiple candidate main .tex files, skipping Stage C"
                    open(claims_report_path, "w") do rio
                        println(rio, "# Stage C: Claims Extraction")
                        println(rio, "")
                        println(rio, "**Skipped**: ambiguous paper source — multiple candidate main `.tex` files were found, and this unattended run cannot pick one:")
                        println(rio, "")
                        for root in tex_result.roots
                            println(rio, "- `\$root`")
                        end
                        println(rio, "")
                        println(rio, "Resolve manually from a JPE.jl session with `extract_paper_claims(paperID; main_files=[...])`, then re-run preprocess.")
                    end
                elseif isempty(tex_result.roots)
                    @warn "no .tex source found under paper-source/ — skipping Stage C claims extraction"
                    open(claims_report_path, "w") do rio
                        println(rio, "# Stage C: Claims Extraction")
                        println(rio, "")
                        println(rio, "**Skipped**: no `.tex` source found under `paper-source/`. PDF fallback is not implemented.")
                    end
                else
                    flattened_path = joinpath(paper_dest_path, "_flattened.tex")
                    write(flattened_path, tex_result.text)
                    try
                        extraction = run_claude_claims_extraction(flattened_path)
                        open(claims_json_path, "w") do jio
                            JSON.print(jio, extraction.claims, 2)
                        end
                        open(claims_report_path, "w") do rio
                            println(rio, "# Stage C: Claims Extraction")
                            println(rio, "")
                            println(rio, "**Done** (\$(Dates.now())). Extraction cost: \\\$\$(extraction.cost_usd)")
                        end
                        @info "✓ Stage C claims extraction complete, cost \\\$\$(extraction.cost_usd)"
                    catch e
                        @warn "Stage C claims extraction failed" exception=e
                        open(claims_report_path, "w") do rio
                            println(rio, "# Stage C: Claims Extraction")
                            println(rio, "")
                            println(rio, "**Failed**: \$e")
                        end
                    finally
                        rm(flattened_path, force=true)
                    end
                end
            end
        end

        # ── PackageScanner precheck ────────────────────────────────────────────
        if $(run_checks)
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

            # ── Force-track classified code files even under `data/` dirs ─────
            # JPEtemplate's .gitignore excludes **/data/*, which can hide
            # genuine author code (already flagged as code by classify_files)
            # from git. List those paths, relative to the repo root, so a
            # later `git add -f` step can force-track them.
            program_files_txt = joinpath(ENV["GITHUB_WORKSPACE"], "generated", "program-files.txt")
            if isfile(program_files_txt)
                force_add_exclude = vcat($(no_data_scan), ["__pycache__"])
                rels = String[]
                for line in eachline(program_files_txt)
                    isempty(strip(line)) && continue
                    if !any(occursin(pat, line) for pat in force_add_exclude)
                        # These files have never been committed before (that's
                        # the whole reason they need force-adding), so their
                        # content has never passed through a secret check.
                        # Redact in place before it's staged -- same
                        # SECRET_PATTERNS the secrets report already scanned
                        # this content with, so a redaction here always agrees
                        # with what report-secrets.md flagged.
                        try
                            original = read(line, String)
                            redacted = PackageScanner.redact_secrets(original)
                            if redacted != original
                                write(line, redacted)
                                @warn "Redacted possible secret(s) in \$line before force-adding to git"
                            end
                        catch e
                            @warn "Could not check \$line for secrets before force-add — leaving as-is" exception=e
                        end
                        push!(rels, relpath(line, ENV["GITHUB_WORKSPACE"]))
                    end
                end
                open(joinpath(ENV["GITHUB_WORKSPACE"], "generated", "force-add-files.txt"), "w") do fio
                    for rel in rels
                        println(fio, rel)
                    end
                end
                @info "✓ Wrote \$(length(rels)) path(s) to generated/force-add-files.txt"
            end

            # ── Stage D: claims-vs-package crosscheck (JPE-Reproducibility/JPE.jl#38) ──
            # Must run here, before the "cap oversized reports" step below --
            # that step replaces a large report-data-dependencies.md with a
            # short placeholder + Dropbox link, which would starve this of
            # its main evidence source. Requires claims.json (Stage C, above)
            # to already exist -- silently skipped otherwise (e.g. Stage C
            # was disabled, or found no usable paper source).
            if $(do_crosscheck)
                gen_dir = joinpath(ENV["GITHUB_WORKSPACE"], "generated")
                crosscheck_claims_path = joinpath(gen_dir, "claims.json")
                crosscheck_json_path = joinpath(gen_dir, "crosscheck.json")
                crosscheck_report_path = joinpath(gen_dir, "report-crosscheck.md")

                if !isfile(crosscheck_claims_path)
                    @info "no claims.json — skipping Stage D crosscheck"
                elseif isfile(crosscheck_json_path)
                    @info "crosscheck.json already exists — skipping Stage D re-run"
                else
                    bundle_dir = mktempdir()
                    try
                        cp(crosscheck_claims_path, joinpath(bundle_dir, "claims.json"))
                        write(joinpath(bundle_dir, "data_dependencies.md"),
                              read_or_placeholder(joinpath(gen_dir, "report-data-dependencies.md"), "(not available)"))
                        write(joinpath(bundle_dir, "readme_structure.md"),
                              read_or_placeholder(joinpath(gen_dir, "report-readme-structure.md"), "(not available)"))
                        write(joinpath(bundle_dir, "code_manifest.txt"),
                              read_or_placeholder(joinpath(gen_dir, "program-files-manifest.csv"),
                                                   read_or_placeholder(joinpath(gen_dir, "program-files.txt"), "(not available)")))
                        write(joinpath(bundle_dir, "data_manifest.txt"),
                              read_or_placeholder(joinpath(gen_dir, "data-files-manifest.csv"), "(not available)"))

                        extraction = run_claude_crosscheck(bundle_dir)
                        verdicts = extraction.result["verdicts"]
                        orphan_code_files = extraction.result["orphan_code_files"]
                        coverage = compute_coverage(verdicts)

                        open(crosscheck_json_path, "w") do jio
                            JSON.print(jio, Dict("verdicts" => verdicts, "coverage" => coverage,
                                                  "orphan_code_files" => orphan_code_files), 2)
                        end
                        write(crosscheck_report_path, render_crosscheck_report(verdicts, coverage, orphan_code_files))
                        @info "✓ Stage D crosscheck complete, cost \\\$\$(extraction.cost_usd), overall coverage \$(coverage["overall"])%"
                    catch e
                        @warn "Stage D crosscheck failed" exception=e
                        open(crosscheck_report_path, "w") do rio
                            println(rio, "### Paper vs. Code/Data Crosscheck")
                            println(rio, "")
                            println(rio, "**Failed**: \$e")
                        end
                    finally
                        rm(bundle_dir, recursive=true, force=true)
                    end
                end
            end

            # ── Cap oversized generated report files ───────────────────────────
            # A full copy goes to a permanent Dropbox link (see large_reports_url
            # in _variables.yml) instead of a GitHub Actions artifact: paper repos
            # are private and authors never get repo access, so an artifact link
            # would be unreachable to them -- and artifacts expire after 90 days
            # regardless. The Dropbox folder link does not expire.
            let max_bytes = 5 * 1024 * 1024
                gen_dir = joinpath(ENV["GITHUB_WORKSPACE"], "generated")
                reports_url = get(vars, "large_reports_url", nothing)
                if isdir(gen_dir) && !isnothing(reports_url) && haskey(ENV, "JPE_DBOX_APPS")
                    reports_dest = joinpath(ENV["JPE_DBOX_APPS"], vars["dropbox_rel_path"], "large-reports")
                    for f in readdir(gen_dir; join=true)
                        (isfile(f) && endswith(f, ".md")) || continue
                        sz = filesize(f)
                        sz > max_bytes || continue
                        fname = basename(f)
                        lines = countlines(f)
                        size_mb = round(sz / 1024^2, digits=1)
                        mkpath(reports_dest)
                        cp(f, joinpath(reports_dest, fname); force=true)
                        open(f, "w") do fio
                            println(fio, "> **Note**: This list contains \$lines entries (\$size_mb MB) — too large to embed in the report.")
                            println(fio, "> The full list is available here: <\$reports_url>")
                        end
                        @info "Capped \$fname (\$size_mb MB, \$lines lines) — full copy sent to Dropbox"
                    end
                end
            end
        else
            @info "run_checks=false — package fetched, skipping PackageScanner precheck"
        end
        """)
    end
    @info "Created runner_precheck.jl at $repoloc"
end


"""
    revoke_preprocessing_link(paperID, round)

Revoke the public Dropbox shared link that was created during `preprocess()`.
Call this after remote preprocessing finishes successfully to close the link.
"""
function revoke_preprocessing_link(paperID, round)
    rt = db_filter_iteration(paperID, round)
    if nrow(rt) != 1
        error("No iteration found for $paperID round $round")
    end
    r = rt[1, :]

    # Retrieve link id from the cloned repo's _variables.yml
    # (we re-use the local temp clone path convention from preprocess)
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