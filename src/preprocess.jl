
function preprocess2(paperID; which_round = nothing, max_pkg_size_gb = 10, max_file_size_gb = 2)
        
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

    @info "package has $size_gb GB."

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


    
    # Create _variables.yml with all necessary info for the runner
    open(joinpath(repoloc, "_variables.yml"), "w") do io
        println(io, "title: \"$(r.title)\"")
        println(io, "author: \"$(r.surname_of_author)\"")
        println(io, "round: $(round)")
        println(io, "repo: \"$(r.github_url)\"")
        println(io, "paper_id: $(r.paper_id)")
        println(io, "journal: \"$(r.journal)\"")
        println(io, "paper_slug: \"$(r.paper_slug)\"")
        # Store relative path that runner will use to construct full Dropbox path
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

        
        # in a new julia process
        cmd = Cmd([
            "julia", 
            "--project=$runner_env", "$runner_script"
        ])
        withenv("SHELL" => "/opt/homebrew/bin/fish", "GITHUB_WORKSPACE" => "$repoloc") do
            res = chomp(read(run(Cmd(cmd)),String))
        end
        @info "✓ Preprocess complete for paper $paperID round $round"
        # * commit all except data
        branch = chomp(read(Cmd(`git rev-parse --abbrev-ref HEAD`,dir = repoloc), String))

        cmd = """
        git add .
        git commit -m '🚀 prechecks round $(round)'
        git push origin $branch
        """
        @show gr = read(Cmd(`sh -c $cmd`, dir=repoloc),String)

    else
        # runner
        # Commit both files
        branch = "round$(round)"
        cmd = """
        git add _variables.yml runner_precheck.jl README.md
        git commit -m '[trigger remote] for round $(round) 🎯 '
        git push origin $branch
        """
        run(Cmd(`sh -c $cmd`, dir=repoloc))
        
        @info "Monitor workflow at: $(r.github_url)/actions"
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
    
    # replace first line with new header, add blank line and badge
    lines[1] = new_header
    insert!(lines, 2, "")
    insert!(lines, 3, badge)
    
    open(filepath, "w") do io
        join(io, lines, "\n")
    end
end



"""
Write the runner_precheck.jl script to the repository location.
This script will be executed by the chosen runner.
"""
function write_runner_script(repoloc::String,no_data_scan::Vector{String})
    open(joinpath(repoloc, "runner_precheck.jl"), "w") do io
        write(io, """
        using YAML
        using PackageScanner

        # Dropbox Files On-Demand helper - force download entire directory
        function force_download_directory(dirpath)
            @info "Forcing download of all files in directory (this triggers Dropbox sync)..." dirpath
            
            file_count = 0
            download_count = 0
            
            for (root, dirs, files) in walkdir(dirpath)
                for file in files
                    filepath = joinpath(root, file)
                    file_count += 1
                    
                    # Check if file is a stub (appears as 0 bytes)
                    initial_size = filesize(filepath)
                    
                    # Force download by reading the entire file
                    try
                        # Reading the file will trigger Dropbox to download it
                        open(filepath, "r") do io
                            # Read in chunks to avoid memory issues with large files
                            while !eof(io)
                                read(io, min(1024*1024, bytesavailable(io)))
                            end
                        end
                        
                        # Check size after reading
                        final_size = filesize(filepath)
                        
                        if initial_size == 0 && final_size > 0
                            download_count += 1
                            if download_count % 10 == 0
                                @info "Downloaded \$download_count files so far..."
                            end
                        end
                    catch e
                        @warn "Could not read file" filepath exception=e
                    end
                end
            end
            
            @info "Processed \$file_count files (\$download_count were downloaded from Dropbox)"
            
            # Verify directory now has content
            size_output = chomp(read(`du -sh \$dirpath`, String))
            @info "Final directory size: \$size_output"
        end

        # Read configuration
        vars = YAML.load_file(joinpath(ENV["GITHUB_WORKSPACE"], "_variables.yml"))
        
        @info "Configuration loaded" vars
        
        # Construct paths
        
        source_path = joinpath(ENV["JPE_DBOX_APPS"], vars["dropbox_rel_path"], "replication-package")
        dest_path = joinpath(ENV["GITHUB_WORKSPACE"], "replication-package")
        
        @info "Paths configured" GITHUB_WORKSPACE=ENV["GITHUB_WORKSPACE"] source_path dest_path
        
        # Check if source exists
        @info "Checking source path exists..."
        if !isdir(source_path)
            error("✗ Package not found at \$source_path")
        end
        @info "✓ Source path exists"
        
        # Check initial size
        initial_size = chomp(read(`du -sh \$source_path`, String))
        @info "Initial package size (may be 0B if files are placeholders): \$initial_size"
        
        # Force download all files from Dropbox
        @info "Ensuring all files are downloaded from Dropbox (this may take several minutes)..."
        try
            force_download_directory(source_path)
        catch e
            @error "Failed to download files" exception=e
            rethrow(e)
        end
        
        # Copy package
        @info "Copying package to workspace..."
        start_time = time()
        
        try
            # Remove destination if it exists
            if isdir(dest_path)
                rm(dest_path; recursive=true, force=true)
            end
            @warn "using PackageScanner.mycp as workaround here"
            PackageScanner.mycp(source_path, dest_path; recursive = true, force=true)
            
            elapsed = time() - start_time
            @info "✓ Package copied successfully in \$(round(elapsed, digits=2)) seconds"
        catch e
            @error "Failed to copy package" exception=e
            rethrow(e)
        end
        
        # Unzip files depending on size
        pkg_size = vars["package_size_gb"]
        max_pkg_size = vars["package_max_pkg_size_gb"]
        max_file_size = vars["package_max_file_size_gb"]
        if pkg_size > max_pkg_size
            @info "package is larger than \$(max_pkg_size) GB. Go into partial extraction mode"
            pkg_dir, manifest = PackageScanner.prepare_package_for_precheck(dest_path, size_threshold_gb = max_file_size, interactive = false)
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