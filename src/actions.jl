

"""
send packages to replicators
this happens after authors submitted their packages via file request link
"""
function dispatch()
    rows = db_filter_status("author_back_de")

    # p = papers
    for r in eachrow(rows)
        cid = case_id(r.journal,r.surname_of_author,r.paper_id,r.round)
        println("dispatch $cid ?")
        yes_no_menu = RadioMenu(["Yes","No"])  # Default is first option 
        if request(yes_no_menu) == 1
            preprocess(r.paper_id)
            assign(r.paper_id)  # needs to prompt for which replicator
        else
            println("skipping $cid")
        end
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
        println(io, "title: \"$(r.title)\"" )
        println(io, "author: \"$(r.surname_of_author)\"" )
        println(io, "round: $(r.round)" )
        println(io, "repo: \"$(r.github_url)\"" )
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

     
    # Update database entries using robust status update pattern
    update_paper_status(paperID, "author_back_de", "with_replicator") do con
        # Update iterations table
        DBInterface.execute(con, """
        UPDATE iterations
        SET replicator1 = ?, date_assigned_repl = ?
        WHERE paper_id = ? AND round = ?
        """, (primary_email, today(), paperID, current_round))
        
        if !isnothing(secondary_email)
            DBInterface.execute(con, """
            UPDATE iterations
            SET replicator2 = ?
            WHERE paper_id = ? AND round = ?
            """, (secondary_email, paperID, current_round))
        end
        
        # Get submission time from Dropbox and update
        submit_time = dbox_fr_submit_time(dbox_token, current_iteration.file_request_path)
        if !isnothing(submit_time)
            DBInterface.execute(con, """
            UPDATE iterations
            SET date_arrived_from_authors = ?
            WHERE paper_id = ? AND round = ?
            """, (Date(submit_time), paperID, current_round))
        end
        
        return (primary=primary_email, secondary=secondary_email)
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

function collect_reports()
    # First, read any new reports from the Google form
    read_google_reports(; append = true)
    
    # Now get all reports from the reports table
    all_reports = db_df("reports")

    # Make a backup of iterations
    db_write_backup("iterations", db_df("iterations"))
    
    if nrow(all_reports) > 0
        # Find reports that need to be processed
        to_process = robust_db_operation() do con
            # This query finds reports that haven't been fully processed in iterations
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
            
            # Process each report individually with proper error handling
            for r in eachrow(to_process)
                try
                    # Update iterations table with report data
                    robust_db_operation() do con
                        DBInterface.execute(con, """
                            UPDATE iterations
                            SET 
                                replicator1 = ?,
                                replicator2 = ?,
                                hours1 = ?,
                                hours2 = ?,
                                is_success = ?,
                                software = ?,
                                is_confidential = ?,
                                is_confidential_shared = ?,
                                is_remote = ?,
                                is_HPC = ?,
                                runtime_code_hours = ?,
                                data_statement = ?,
                                repl_comments = ?,
                                date_completed_repl = ?
                            WHERE 
                                paper_id = ? AND
                                round = ?
                        """, (
                            r.email_of_replicator_1,
                            r.email_of_replicator_2,
                            r.hours_replicator_1,
                            r.hours_replicator_2,
                            r.is_success,
                            r.software_used_in_package,
                            r.is_confidential,
                            r.shared_confidential,
                            r.is_remote,
                            r.is_HPC,
                            r.running_time_of_code,
                            r.data_statement,
                            r.comments,
                            Date(r.timestamp),
                            r.paper_id,
                            r.round
                        ))
                    end
                    
                    # Update paper status
                    update_paper_status(r.paper_id, "with_replicator", "replicator_back_de") do con
                        return r
                    end
                    
                    @info "Successfully processed report for paper $(r.paper_id), round $(r.round)"
                catch e
                    @warn "Error processing report for paper $(r.paper_id), round $(r.round): $e"
                end
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

"""
    process_editor_decision(paperID, decision)

Process the Data Editor's decision for a paper after reviewing replicator reports.

# Arguments
- `paperID`: The ID of the paper
- `decision`: One of "accept" or "revise"

# Returns
- The updated paper information
"""
function process_editor_decision(paperID, decision)
    # Get paper information
    paper = db_filter_paper(paperID)
    if nrow(paper) != 1
        error("Paper ID $paperID not found or has multiple entries")
    end
    
    r = NamedTuple(paper[1, :])
    
    # Validate current status
    if r.status != "replicator_back_de"
        error("Paper must be in 'replicator_back_de' status to process a decision")
    end
    
    # Process based on decision
    if decision == "accept"
        update_paper_status(paperID, "replicator_back_de", "acceptable_package") do con
            # Update iterations table
            DBInterface.execute(con, """
            UPDATE iterations
            SET date_decision_de = ?, decision_de = 'accept'
            WHERE paper_id = ? AND round = ?
            """, (today(), paperID, r.round))
            
            # Send acceptance email to author
            gmail_g2g(r.firstname_of_author, r.paper_id)
            
            return r
        end
    elseif decision == "revise"
        # Use the existing prepare_rnrs function but with robust status update
        prepare_rnrs(paperID)
    else
        error("Invalid decision: $decision. Must be one of 'accept' or 'revise'")
    end
end

"""
    finalize_publication(paperID)

Mark a paper as published after it has been published in the journal.

# Arguments
- `paperID`: The ID of the paper

# Returns
- The updated paper information
"""
function finalize_publication(paperID)
    update_paper_status(paperID, "acceptable_package", "published_package") do con
        # Update iterations table
        DBInterface.execute(con, """
        UPDATE iterations
        SET date_published = ?
        WHERE paper_id = ? AND round = (
            SELECT MAX(round) FROM iterations WHERE paper_id = ?
        )
        """, (today(), paperID, paperID))
        
        # Any other publication-related tasks
        
        return db_filter_paper(paperID)[1, :]
    end
end

function prepare_rnrs(paperID)
    # Get paper information
    paper = db_filter_paper(paperID)
    if nrow(paper) != 1
        error("Paper ID $paperID not found or has multiple entries")
    end
    
    r = NamedTuple(paper[1, :])
    
    # Validate current status
    if r.status != "replicator_back_de"
        error("Paper must be in 'replicator_back_de' status to prepare RnR")
    end
    
    # Use the robust status update pattern
    update_paper_status(paperID, "replicator_back_de", "with_author") do con
        # Get current iteration
        iter_query = """
        SELECT * FROM iterations 
        WHERE paper_id = ? AND round = ?
        """
        current_iter = DataFrame(DBInterface.execute(con, iter_query, (paperID, r.round)))
        
        if nrow(current_iter) != 1
            error("Iteration not found for paper $paperID, round $(r.round)")
        end
        
        # Update current iteration with decision
        DBInterface.execute(con, """
        UPDATE iterations
        SET date_decision_de = ?, decision_de = 'rnr'
        WHERE paper_id = ? AND round = ?
        """, (today(), paperID, r.round))
        
        # Create new iteration for next round
        rnew = copy(r)
        rnew = merge(rnew, (round = r.round + 1,))
        
        # Create new branch on repo
        gh_create_branch_on_github_from(r.gh_org_repo, "round$(r.round)", "round$(rnew.round)")
        
        # Insert new iteration row
        new_iter = copy(current_iter[1, :])
        new_iter.round = rnew.round
        new_iter.date_with_authors = today()
        
        # Clear fields that should be reset for new iteration
        for field in [:replicator1, :replicator2, :hours1, :hours2, :is_success, 
                      :date_arrived_from_authors, :date_assigned_repl, :date_completed_repl,
                      :date_decision_de, :decision_de]
            if hasproperty(new_iter, field)
                new_iter[field] = missing
            end
        end
        
        # Register the new iteration
        DuckDB.register_data_frame(con, DataFrame([new_iter]), "new_iter")
        DBInterface.execute(con, "INSERT INTO iterations SELECT * FROM new_iter")
        
        # Set up Dropbox structure for new iteration
        setup_dropbox_structure!(NamedTuple(new_iter), dbox_token)
        
        # Update papers table with new round
        DBInterface.execute(con, """
        UPDATE papers
        SET round = ?
        WHERE paper_id = ?
        """, (rnew.round, paperID))
        
        # Prepare email draft
        gmail_rnr(r.firstname_of_author, r.paper_id, r.title, new_iter.file_request_url_pkg, 
                 r.email_of_author, 
                 email2 = ismissing(r.email_of_second_author) ? nothing : r.email_of_second_author)
        
        return new_iter
    end
end


function monitor_file_requests()
    # Filter papers for status "with_author" or "new_arrival"
    i = @chain db_df("papers") begin
        subset(:status => ByRow(.∈(Ref(["with_author","new_arrival"]))))
        select(:status, :paper_id)
        leftjoin(db_df("iterations"), on = [:paper_id])
        subset(:round => (x -> x .== maximum(x)))
    end

    pkg_arrived = NamedTuple[]
    pkg_waiting = NamedTuple[]
    pap_arrived = NamedTuple[]
    pap_waiting = NamedTuple[]

    @info "checking packages..."
    for r in eachrow(i)
        try
            # Get file_request id and check whether arrived
            println("  📦 $(r.paper_slug)")

            if dbox_fr_arrived(dbox_token, r.file_request_id_pkg)["file_count"] > 0
                push!(pkg_arrived, (journal = r.journal, paper_id = r.paper_id, round = r.round, slug = r.paper_slug))
            else
                push!(pkg_waiting, (journal = r.journal, paper_id = r.paper_id, round = r.round, slug = r.paper_slug))
            end

            if dbox_fr_arrived(dbox_token, r.file_request_id_paper)["file_count"] > 0
                push!(pap_arrived, (journal = r.journal, paper_id = r.paper_id, round = r.round, slug = r.paper_slug))
            else
                push!(pap_waiting, (journal = r.journal, paper_id = r.paper_id, round = r.round, slug = r.paper_slug))
            end
        catch e
            @warn "Error checking file requests for $(r.paper_slug): $e"
        end
    end
    
    waiting = DataFrame(pkg_waiting)
    papwaiting = DataFrame(pap_waiting)
    arrived = DataFrame(pkg_arrived)
    df_reminders = nothing

    if nrow(arrived) > 0
        reminders = intersect(arrived.paper_id, papwaiting.paper_id)  
        if length(reminders) > 0
            df_reminders = @chain papwaiting begin
                subset(:paper_id => ByRow(∈(reminders)))
            end
        end
    end

    # Use robust status updates
    for a in eachrow(arrived)
        try
            # Get the file request path from iterations
            iter = @chain db_df("iterations") begin
                @subset(:paper_id .== a.paper_id)
                @subset(:round .== a.round)
                first()
            end
            
            update_paper_status(a.paper_id, "with_author", "author_back_de") do con
                # Update iterations table with arrival date
                submit_time = dbox_fr_submit_time(dbox_token, iter.file_request_path)
                if !isnothing(submit_time)
                    DBInterface.execute(con, """
                    UPDATE iterations
                    SET date_arrived_from_authors = ?
                    WHERE paper_id = ? AND round = ?
                    """, (Date(submit_time), a.paper_id, a.round))
                end
                return a
            end
        catch e
            @warn "Error updating status for $(a.paper_id): $e"
        end
    end

    return Dict(:waiting => waiting, :arrived => arrived, :remindJO => df_reminders) 
end
