
"to be deprecated"
function preprocess(paperID; which_round = nothing, copy_package = true)
    
    # get row from "iterations"
    p = db_filter_paper(paperID)
    round = if isnothing(which_round)
        p.round[1]
    else
        which_round
    end
    @info "preprocessing $paperID round $round"

    rt = db_filter_iteration(paperID,round)
    if nrow(rt) != 1
        error("can only get a single row here")
    end
    r = rt[1,:] # dataframerow

    # create a temp dir
    d = tempdir()
    @show repoloc = joinpath(d,string(paperID,"-",round))
    o = pwd()
    cd(d)

    # clone branch current "round"
    gh_clone_branch(r.gh_org_repo,"round$(round)", to = repoloc)
    
    # * copy round version from Dropbox to local repo into temp location
       
    # recompute file request full path for local machine
    r.file_request_path_full = get_dbox_loc(r.journal, r.paper_slug, r.round, full = true)  
    if copy_package
        @info "copying package to temp loc"
        mycp(joinpath(r.file_request_path_full,"replication-package"),joinpath(repoloc,"replication-package"), recursive = true, force = true)
    else
        @info "manual copy of large package"
        println("done copying?")
        println("copy from")
        println(joinpath(r.file_request_path_full,"replication-package"))
        println("to")
        println(joinpath(repoloc,"replication-package"))

        yes_no_menu = RadioMenu(["Yes","No"])  # Default is first option 
        if request(yes_no_menu) == 1
            println("continuing")
        else
            println("not continuing")
            return 0
        end

    end

    zips = read_and_unzip_directory(joinpath(repoloc,"replication-package"))

    @debug readdir(repoloc)

    # in a new julia process
    cmd = Cmd([
        "julia", 
        "--project=.", "-e",
        "using PackageScanner; PackageScanner.precheck_package(\"$(joinpath(repoloc,"replication-package"))\")"
    ])

    PackageScanner.precheck_package(joinpath(repoloc,"replication-package"))

    # res = chomp(read(run(Cmd(cmd; dir = ENV["JPE_TOOLS_JL"])),String))
    # res = chomp(read(run(Cmd(cmd)),String))

    # * write the _variables.yml file for the report template
    open(joinpath(repoloc,"_variables.yml"), "w") do io
        println(io, "title: \"$(r.title)\"" )
        println(io, "author: \"$(r.surname_of_author)\"" )
        println(io, "round: $(round)" )
        println(io, "repo: \"$(r.github_url)\"" )
        println(io, "paper_id: $(r.paper_id)" )
    end
    @debug readlines(joinpath(repoloc,"_variables.yml"))

    # * commit all except data
    branch = chomp(read(Cmd(`git rev-parse --abbrev-ref HEAD`,dir = repoloc), String))

    cmd = """
    git add .
    git commit -m '🚀 prechecks round $(round)'
    git push origin $branch
    """
    @show gr = read(Cmd(`sh -c $cmd`, dir=repoloc),String)
    
    cd(o) # go back

    # * Push back
    # * Delete local repo
    rm(repoloc, recursive = true, force = true)
end



function preprocess2(paperID; which_round = nothing)
        
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
        println(io, "dropbox_rel_path: \"$(get_dbox_loc(r.journal, r.paper_slug, r.round, full = false))\"")
    end
    
    # Create runner script
    write_runner_script(repoloc)
    
    # Commit both files
    branch = "round$(round)"
    cmd = """
    git add _variables.yml runner_precheck.jl
    git commit -m '🎯 Trigger precheck for round $(round)'
    git push origin $branch
    """
    run(Cmd(`sh -c $cmd`, dir=repoloc))
    
    cd(o) # go back

    # * Delete local repo
    rm(repoloc, recursive = true, force = true)
    @info "✓ Preprocess complete for paper $paperID round $round"
    @info "Monitor workflow at: $(r.github_url)/actions"
end




"""
Write the runner_precheck.jl script to the repository location.
This script will be executed by the GitHub Actions runner.
"""
function write_runner_script(repoloc::String)
    """
    Write the runner_precheck.jl script to the repository location.
    This script will be executed by the GitHub Actions runner.
    """
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
        dropbox_base = get(ENV, "DROPBOX_BASE", joinpath(ENV["HOME"], "Dropbox"))
        source_path = joinpath(dropbox_base, vars["dropbox_rel_path"], "replication-package")
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
            
            cp(source_path, dest_path; force=true)
            
            elapsed = time() - start_time
            @info "✓ Package copied successfully in \$(round(elapsed, digits=2)) seconds"
        catch e
            @error "Failed to copy package" exception=e
            rethrow(e)
        end
        
        # Unzip files
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
            PackageScanner.precheck_package(dest_path)
            @info "✓ Precheck complete"
        catch e
            @error "Precheck failed" exception=e
            rethrow(e)
        end
        """)
    end
    @info "Created runner_precheck.jl at $repoloc"
end