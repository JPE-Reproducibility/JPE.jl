

"""
send packages to replicators
this happens after authors submitted their packages via file request link
"""
function dispatch()
    rows = db_df_where("papers","status","author_back_de")

    # p = papers
    for r in eachrow(rows)
        preprocess(r.paper_id)
        assign(r.paper_id)  # needs to prompt for which replicator
    end
end


function preprocess(paperID; which_round = nothing)
    # get row from "papers"
    rt = db_df_where("papers","paper_id",paperID)
    if nrow(rt) != 1
        error("can only get a single row here")
    end
    r = NamedTuple(rt[1,:])

    round = if isnothing(which_round)
        r.round[1]
    else
        which_round
    end

    # create a temp dir
    d = tempdir()
    @show repoloc = joinpath(d,string(paperID,"-",round))
    o = pwd()
    cd(d)

    # clone branch current "round"
    gh_clone_branch(r.gh_org_repo,"round$(r.round)", to = repoloc)

    # * copy round version from Dropbox to local repo into temp location
    cp(joinpath(r.file_request_path_full,"paper-appendices"),joinpath(repoloc,"paper-appendices"), force = true)
    cp(joinpath(r.file_request_path_full,"replication-package"),joinpath(repoloc,"replication-package"), force = true)

    zips = read_and_unzip_directory(joinpath(repoloc,"replication-package"))

    @debug readdir(repoloc)

    # in a new julia process
    cmd = Cmd([
        "julia", 
        "--project=.", "-e",
        "using JPEtools; JPEtools.precheck_package(\"$(joinpath(repoloc,"replication-package"))\")"
    ])

    res = chomp(read(run(Cmd(cmd; dir = "/Users/floswald/git/JPEtools")),String))

    # * write the _variables.yml file for the report template
    open(joinpath(repoloc,"_variables.yml"), "w") do io
        println(io, "title: $(r.title)" )
        println(io, "author: $(r.surname_of_author)" )
        println(io, "round: $(r.round)" )
        println(io, "repo: $(r.github_url)" )
        println(io, "paper_id: $(r.paper_id)" )
    end
    check = readlines(joinpath(repoloc,"_variables.yml"))

    # * commit all except data
    branch = chomp(read(run(Cmd(`git rev-parse --abbrev-ref HEAD`,dir = repoloc)), String))

    cmd = """
    git add .
    git commit -m '🚀 prechecks round $(r.round)'
    git tag -a round$(r.round) -m 'round$(r.round)'
    git push origin $branch
    """
    gr = read(run(Cmd(`sh -c $cmd`, dir=repoloc)),String)
    

    # * Push back
    # * Delete local repo
end


"""
Interactively select replicators for a paper
"""
function select_replicators(paperID)
    # Get relevant row from iterations table
    # By default, get the highest round number
    i = @chain db_df("iterations") begin
        @subset(:paper_id .== paperID)
    end
    
    # Initialize variables for previous replicators
    prev_replicator1 = nothing
    prev_replicator2 = nothing
    
    # Check if this is a subsequent round
    if maximum(i.round) > 1
        last_round_data = @chain i begin
            @subset(:round .== maximum(:round))
            first()  # Get the first (and should be only) row
        end
        
        # Store previous replicators
        prev_replicator1 = last_round_data.replicator1
        prev_replicator2 = last_round_data.replicator2
    end
    
    # Get current iteration data
    current_iteration = @chain i begin
        @subset(:round .== maximum(:round))
        first()
    end
    
    # Get available replicators
    rs = read_replicators()
    
    # Create interactive menu for primary replicator selection
    println("\n📋 Select primary replicator for paper ID: $paperID")
    
    # Create options array with display text and email value
    options = []
    for r in eachrow(rs)
        email = r.email
        name = r.name
        
        # Mark previous replicators with a prefix instead of highlighting
        if !isnothing(prev_replicator1) && email == prev_replicator1
            display_text = "🔄 $name ($email) [previous primary]"
        elseif !isnothing(prev_replicator2) && email == prev_replicator2
            display_text = "🔄 $name ($email) [previous secondary]"
        else
            display_text = "$name ($email)"
        end
        
        push!(options, display_text => email)
    end
    
    # Find index to preselect
    preselect_idx = 1  # Default to first option
    if !isnothing(prev_replicator1)
        # Find index of prev_replicator1 in options
        for (idx, (_, email)) in enumerate(options)
            if email == prev_replicator1
                preselect_idx = idx
                break
            end
        end
    end
    
    # Display menu for primary replicator selection
    primary_menu = RadioMenu([opt[1] for opt in options])
    primary_choice = request(primary_menu)
    
    # Handle cancellation (if Esc is pressed)
    if primary_choice == -1
        println("Selection cancelled. Using first option as default.")
        primary_choice = 1
    end
    
    # Get the actual email from selection
    primary_email = options[primary_choice][2]
    
    # Get name of primary replicator
    primary_name = filter(r -> r.email == primary_email, eachrow(rs))[1].name
    
    # Ask if a second replicator is needed
    println("Do you want to assign a second replicator?")
    yes_no_menu = RadioMenu(["No", "Yes"])  # Default is first option (No)
    use_second = request(yes_no_menu) == 2  # Returns true if "Yes" is selected
    
    secondary_email = nothing
    secondary_name = nothing
    
    if use_second
        println("\n📋 Select secondary replicator:")
        
        # Filter out the primary replicator from options
        secondary_options = filter(opt -> opt[2] != primary_email, options)
        
        # If there's a previous second replicator, preselect it
        preselect_idx = 1  # Default to first option
        if !isnothing(prev_replicator2)
            # Find index of prev_replicator2 in secondary_options
            for (idx, (_, email)) in enumerate(secondary_options)
                if email == prev_replicator2
                    preselect_idx = idx
                    break
                end
            end
        end
        
        # Display menu for secondary replicator selection
        secondary_menu = RadioMenu([opt[1] for opt in secondary_options])
        secondary_choice = request(secondary_menu)
        
        # Handle cancellation (if Esc is pressed)
        if secondary_choice == -1
            println("Selection cancelled. Using first option as default.")
            secondary_choice = 1
        end
        
        # Get the actual email from selection
        secondary_email = secondary_options[secondary_choice][2]
        
        # Get name of secondary replicator
        secondary_name = filter(r -> r.email == secondary_email, eachrow(rs))[1].name
    end
    
    # Return selected replicators and related information
    return (
        primary_email = primary_email,
        primary_name = primary_name,
        secondary_email = secondary_email,
        secondary_name = secondary_name,
        current_round = maximum(i.round),
        current_iteration = current_iteration,
        is_subsequent_round = maximum(i.round) > 1
    )
end

"""
Assign selected replicators to a paper and update database
"""
function assign_replicators(paperID, selection)
    # Unpack selection
    primary_email = selection.primary_email
    primary_name = selection.primary_name
    secondary_email = selection.secondary_email
    secondary_name = selection.secondary_name
    current_round = selection.current_round
    current_iteration = selection.current_iteration
    is_subsequent_round = selection.is_subsequent_round
    
    # Update iterations table
    db_update_cell("iterations", "paper_id = '$(paperID)' AND round = $(current_round)", "replicator1", primary_email)
    db_update_cell("iterations", "paper_id = '$(paperID)' AND round = $(current_round)", "date_assigned_repl", today())
    
    if !isnothing(secondary_email)
        db_update_cell("iterations", "paper_id = '$(paperID)' AND round = $(current_round)", "replicator2", secondary_email)
    end
    
    # Get submission time from Dropbox and update
    submit_time = dbox_fr_submit_time(dbox_token, current_iteration.file_request_path)
    if !isnothing(submit_time)
        db_update_cell("iterations", "paper_id = '$(paperID)' AND round = $(current_round)", "date_arrived_from_authors", Date(submit_time))
    end
    
    # Update papers table status
    db_update_cell("papers", "paper_id = '$(paperID)'", "status", "with_replicator")
    
    # Send email to replicators
    # Get necessary information for email
    download_url = dbox_link_at_path(current_iteration.file_request_path, dbox_token)
    repo_url = current_iteration.github_url
    
    # Create case ID for email
    paper_row = db_df_where("papers", "paper_id", paperID)[1, :]
    caseID = case_id(paper_row.journal, paper_row.surname_of_author, paperID, current_round)
    
    # Send email
    if !isnothing(secondary_email)
        gmail_assign(primary_name, primary_email, caseID, download_url, repo_url, 
                    first2=secondary_name, email2=secondary_email, back=is_subsequent_round)
    else
        gmail_assign(primary_name, primary_email, caseID, download_url, repo_url, back=is_subsequent_round)
    end
    
    println("✅ Successfully assigned paper $(paperID) to replicators")
    return (primary=primary_email, secondary=secondary_email)
end

"""
assigns the latest round of a paper to replicators
"""
function assign(paperID)
    # Select replicators
    selection = select_replicators(paperID)
    
    # Assign replicators
    return assign_replicators(paperID, selection)
end

# list all papers that have been invited to submit
function list_arrivals_waiting()
    # 1. read papers table
    papers = db_df("papers")

    # 2. find papers with status "new_arrival" and round 1

    # 3. return those IDs

end

function collect_reports()
    # First, read any new reports from the Google form
    read_google_reports(; append = true)
    
    # Now get all reports from the reports table
    all_reports = db_df("reports")

    # make a backup of iterations
    db_write_backup("iterations", db_df("iterations"))

    
    if nrow(all_reports) > 0
        # Find reports that need to be processed
        # We'll identify these by checking which reports have data that hasn't been copied to iterations
        
        # Get the iterations table
        iterations = db_df("iterations")
        
        # Find reports that need processing by checking a key field that would indicate processing
        to_process = robust_db_operation() do con
            # This query finds reports that haven't been fully processed in iterations
            # It joins reports with iterations and finds where key fields haven't been updated
            DataFrame(DBInterface.execute(con, """
                SELECT r.*
                FROM reports r
                LEFT JOIN iterations i ON r.paper_id = i.paper_id AND r.round = i.round
                WHERE i.date_completed_repl IS NULL 
                   OR i.replicator1 IS NULL
                   OR i.replicator1 <> r.email_of_replicator_1
            """))
        end
        
        if nrow(to_process) > 0
            @info "Found $(nrow(to_process)) reports to process"
            
            # Register the reports dataframe as a temporary table in DuckDB
            robust_db_operation() do con
                # Register the reports to process
                DuckDB.register_data_frame(con, to_process, "temp_reports")
                
                # Use UPDATE with JOIN to update the iterations table
                out = DBInterface.execute(con, """
                    UPDATE iterations
                    SET 
                        replicator1 = tr.email_of_replicator_1,
                        replicator2 = tr.email_of_replicator_2,
                        hours1 = tr.hours_replicator_1,
                        hours2 = tr.hours_replicator_2,
                        is_success = tr.is_success,
                        software = tr.software_used_in_package,
                        is_confidential = tr.is_confidential,
                        is_confidential_shared = tr.shared_confidential,
                        is_remote = tr.is_remote,
                        is_HPC = tr.is_HPC,
                        runtime_code_hours = tr.running_time_of_code,
                        data_statement = tr.data_statement,
                        repl_comments = tr.comments,
                        date_completed_repl = CAST(tr.timestamp AS DATE)
                    FROM temp_reports tr
                    WHERE 
                        iterations.paper_id = tr.paper_id AND
                        iterations.round = tr.round
                    RETURNING iterations.*
                """) |> DataFrame
                rows_updated = nrow(out)

                
                # Update the status in the papers table
                DBInterface.execute(con, """
                    UPDATE papers
                    SET status = 'replicator_back_de'
                    FROM temp_reports tr
                    WHERE papers.paper_id = tr.paper_id
                """)
                
                @info "We had $(nrow(to_process)) reports to process"
                @info "We updated $(rows_updated) rows in iterations"
            end
            
            return to_process
        else
            @info "No reports need processing"
            return nothing
        end
    else
        @info "No reports found in the reports table"
        return nothing
    end
end

function prepare_rnrs()


    # filter papers table for status "replicator_back_de"

        # capture current_round from papers.round and check consistent with iterations


    # for each, print summary on screen

    # report needs to be compiled and edited (manually) in github repo

    # pdf with correct name needs to be saved in

    # set in "iterations": date_decision_de = today, file_request_id = fr_id, decision_de = "rnr", file_request_url = fr_url

    # START OF NEXT ITERATION HERE

    # create the next iteration for this paper, i.e. add a row in "iterations" by copying journal,paper_id,firstname_of_author,surname_of_author,round,but modifying round from previous to round + 1

    # set papers.round = current_round + 1
    rnew = copy(r)
    rnew.round += 1

    # create new branch on repo called current_round + 1 from branch current_round
    gh_create_branch_on_github_from(r.gh_url,"round$(r.round)","round$(rnew.round)")

    # call setup_dropbox_structure!(r) on that new row of the "iterations" dataframe

    # prepare email draft of reply to author using
    
    gmail_rnr(r.firstname_of_author,r.paper_id,r.title,r.fr_url,r.email_of_author, email2 = ismissing(r.email_of_second_author) : nothing : r.email_of_second_author)


    # set status of paper_id in papers to "with_author", set date_with_authors to today()
end

function collect_file_requests()
    # filter papers for status "with_author"
    rows = db_df_where("papers","status","with_author")

    for r in eachrow(rows)
        # get file_request id and check whether arrived

        # set papers.status= "author_back_de"

        # in iterations, set date_arrived etc

    end


    
end
