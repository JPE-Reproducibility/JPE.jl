

"""
display list of cases which require DE's attention
"""
function de_waiting()
    p = db_filter_status("author_back_de","replicator_back_de")
    select(p,:paper_id,:paper_slug,:round,:surname_of_author, :status)
end

function de_process_waiting_reports()
    p = db_filter_status("replicator_back_de")

    for r in eachrow(p)
        println("process $(r.paper_slug)?")
        yes_no_menu = RadioMenu(["Yes","No"])  # Default is first option (Yes)
        if request(yes_no_menu) == 1 
            # pull report
            write_report(r.paper_id)
            println()
            println("👉 Ready to take a decision?")
            yes_no_menu = RadioMenu(["No", "Yes"])  # Default is first option (No)
            if request(yes_no_menu) == 2 
                println()
                println("Accept or Revise and Resubmit?")
                accept_or_reject = RadioMenu(["Accept", "Revise"])  # Default is first option (Accept)
                if request(accept_or_reject) == 1
                    process_editor_decision(r.paper_id,"accept")
                    @info "$(r.paper_id) successfully accepted"

                else
                    process_editor_decision(r.paper_id,"revise")
                    @info "processed $(r.paper_id) successfully"
                    @info "DRAFT email ready, need to send now!"
                end
            else
                @info "no decision for $(r.paper_id) taken"
                return
            end
        else
            continue    
        end
    end

    @info "creating backup"
    db_bk_create()

end


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

    @info "updating replicator workload"
    replicator_workload_report(; save_csv=false, csv_path=nothing, update_gsheet=true)

    @info "updating replicator assignments"
    replicator_assignments( )

    @info "creating backup"
    db_bk_create()

end


function preprocess(paperID; which_round = nothing)
    
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
end


"""
Display replicators in a tabular view grouped by OS
"""
function display_replicators(rs::DataFrame)
    # Function to normalize OS names to just the main family
    function normalize_os(os_string)
        os_lower = lowercase(string(os_string))
        if occursin("windows", os_lower) || occursin("win", os_lower)
            return "Windows"
        elseif occursin("mac", os_lower) || occursin("darwin", os_lower) || occursin("osx", os_lower)
            return "macOS"
        elseif occursin("linux", os_lower) || occursin("ubuntu", os_lower) || occursin("debian", os_lower) || occursin("centos", os_lower) || occursin("fedora", os_lower)
            return "Linux"
        else
            return "Other"
        end
    end
    
    # Add normalized OS column
    rs_normalized = copy(rs)
    rs_normalized.os_family = [normalize_os(os) for os in rs_normalized.os]

    rs_normalized.current_workload .= Int.(rs_normalized.current_workload)
    
    # Group by normalized OS
    os_families = unique(rs_normalized.os_family)
    
    # Calculate column width based on terminal width and number of OS families
    terminal_width = 120  # Assume reasonable terminal width
    padding = 4  # Space between columns
    column_width = div(terminal_width - (length(os_families) - 1) * padding, length(os_families))
    
    # Create panels for each OS family
    os_panels = []
    
    for os_family in sort(os_families)  # Sort for consistent ordering
        # Filter replicators for this OS family
        family_replicators = filter(r -> r.os_family == os_family, eachrow(rs_normalized))
        
        # Create content for this OS family
        content_lines = String[]
        
        for r in family_replicators
            # Format name and email
            name = "$(r.name) $(r.surname)"
            email = r.email
            
            # Add workload indicator if > 0
            if r.current_workload > 0
                email = "$email ($(r.current_workload))"
                name = "{bold}$name{/bold}"
                email = "{bold}$email{/bold}"
            end
            
            # Apply color based on availability
            if r."can_take_+1_package" == "No"
                name = "{red}$name{/red}"
                email = "{red}$email{/red}"
            else
                name = "{green}$name{/green}"
                email = "{green}$email{/green}"
            end
            
            # Add to content (name on one line, email on next, then empty line)
            push!(content_lines, name)
            push!(content_lines, email)
            push!(content_lines, "")  # Empty line between replicators
        end
        
        # Remove the last empty line if it exists
        if !isempty(content_lines) && content_lines[end] == ""
            pop!(content_lines)
        end
        
        # Create panel for this OS family
        content = isempty(content_lines) ? "No replicators" : join(content_lines, "\n")
        
        panel = Term.Panel(
            content,
            title = os_family,
            width = column_width,
            fit = false,  # Don't auto-fit, use specified width
            justify = :left
        )
        
        push!(os_panels, panel)
    end
    
    # Combine panels horizontally with spacing
    if !isempty(os_panels)
        final_layout = os_panels[1]
        
        for i in 2:length(os_panels)
            spacer = " "^padding  # Create spacing between columns
            final_layout = final_layout * spacer * os_panels[i]
        end
        
        println(final_layout)
    else
        println("No replicators found.")
    end
    
    return rs  # Return the original dataframe
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
            @subset(:round .== (maximum(:round) .- 1))
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
    first_iteration = @chain i begin
        @subset(:round .== 1)
    end
    
    # Get available replicators
    rs = read_replicators()
    
    # Display replicators in a tabular view grouped by OS
    display_replicators(rs)
    
    # Create interactive menu for primary replicator selection
    println("\n📋 Select primary replicator for paper ID: $paperID")
    
    # Create options array with display text and email value
    options = []
    for r in eachrow(rs)
        email = r.email
        name = r.name
        
        # Mark previous replicators with a prefix instead of highlighting
        if (!isnothing(prev_replicator1) && !ismissing(prev_replicator1)) && email == prev_replicator1
            display_text = "🔄 $name ($email) [previous primary]"
        elseif (!isnothing(prev_replicator2) && !ismissing(prev_replicator2)) && email == prev_replicator2
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
        if !isnothing(prev_replicator2) && !ismissing(prev_replicator2)
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
        first_iteration = first_iteration,
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
    first_iteration = selection.first_iteration
    
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
    println()
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

function reports_to_process()
    robust_db_operation() do con
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
end



function reports_2_iterations()
    [
        ("replicator1", :email_of_replicator_1),
        ("replicator2", :email_of_replicator_2),
        ("hours1", :hours_replicator_1),
        ("hours2", :hours_replicator_2),
        ("is_success", :is_success),
        ("software", :software_used_in_package),
        ("is_confidential", :is_confidential),
        ("is_confidential_shared", :shared_confidential),
        ("is_remote", :is_remote),
        ("is_HPC", :is_HPC),
        ("runtime_code_hours", :running_time_of_code),
        ("data_statement", :data_statement),
        ("repl_comments", :comments),
        ("date_completed_repl", :timestamp)
    ]
end

"""
    collect_reports()

Debug version of collect_reports that updates each field individually to identify type mismatches.
This function:
1. Reads new reports from Google form
2. Makes a backup of iterations
3. For each report, updates fields one at a time with detailed logging
4. Only updates paper status if all fields are successfully updated
"""
function collect_reports(;verbose = false)
    # First, read any new reports from the Google form
    read_google_reports(; append = true)
    
    # Make a backup of iterations
    db_write_backup("iterations", db_df("iterations"))
    
    to_process = reports_to_process()
    
    if nrow(to_process) > 0
        @info "Found $(nrow(to_process)) reports to process"
        
        # Process each report individually with proper error handling
        for r in eachrow(to_process)
            if verbose
                println("Processing report for paper $(r.paper_id), round $(r.round)")
            end
            
            # Track if all updates succeed
            all_updates_successful = true
            
            # Define the fields to update and their corresponding values
            # This maps field names to their values in the report
       
            
            # Update each field individually
            for (field, value_sym) in reports_2_iterations()
                try
                    if verbose
                        println("  Updating field: $field with value: $(r[value_sym])
                        ")
                    end
                    
                    # Special handling for date_completed_repl which needs Date conversion
                    value = value_sym == :timestamp ? Date(r[value_sym]) : r[value_sym]
                    
                    # Use robust_db_operation for each field update
                    robust_db_operation() do con
                        stmt = DBInterface.prepare(con, """
                        UPDATE iterations
                        SET $field = ?
                        WHERE paper_id = ? AND round = ?
                        """)
                        
                        DBInterface.execute(stmt, (value, r.paper_id, r.round))
                    end
                    
                    if verbose
                        println("  ✓ Successfully updated $field")
                    end
                catch e
                    println("  ❌ Error updating $field: $e")
                    println("  Value type: $(typeof(r[value_sym]))")
                    println("  Value: $(r[value_sym])")
                    all_updates_successful = false
                end
            end
            
            # Only update paper status if all fields were successfully updated
            if all_updates_successful
                try
                    if verbose
                        println("All fields updated successfully, updating paper status...")
                    end
                    
                    # Update paper status outside of update_paper_status to avoid transaction issues
                    robust_db_operation() do con
                        # First check if paper exists and has the expected status
                        paper_query = """
                        SELECT status FROM papers WHERE paper_id = ?
                        """
                        paper_result = DataFrame(DBInterface.execute(con, paper_query, (r.paper_id,)))
                        
                        if nrow(paper_result) == 0
                            error("Paper ID $(r.paper_id) not found")
                        end
                        
                        current_status = paper_result[1, :status]
                        if current_status != "with_replicator"
                            error("Paper ID $(r.paper_id) has status '$current_status', expected 'with_replicator'")
                        end
                        
                        # Update the status
                        DBInterface.execute(con, """
                        UPDATE papers
                        SET status = ?
                        WHERE paper_id = ?
                        """, ("replicator_back_de", r.paper_id))
                    end
                    
                    if verbose
                        println("✓ Successfully updated paper status to 'replicator_back_de'")
                    end
                catch e
                    println("❌ Error updating paper status: $e")
                end
            else
                println("⚠️ Not updating paper status due to field update failures")
            end
            
            println("Completed processing report for paper $(r.paper_id), round $(r.round)")
            println("---------------------------------------------------------")
        end
        
        return to_process
    else
        @info "No reports need processing"
        return nothing
    end
end


# function collect_reports()
#     # First, read any new reports from the Google form
#     # read_google_reports(; append = true)
    
#     # Make a backup of iterations
#     db_write_backup("iterations", db_df("iterations"))
    
#     to_process = reports_to_process()
    
#     if nrow(to_process) > 0
#         @info "Found $(nrow(to_process)) reports to process"
        
#         # Process each report individually with proper error handling
#         for r in eachrow(to_process)
#             try
#                 # Update iterations table with report data
#                 update_paper_status(r.paper_id, "with_replicator", "replicator_back_de") do con
#                     # robust_db_operation() do con
#                     DBInterface.execute(con, """
#                         UPDATE iterations
#                         SET 
#                             replicator1 = ?,
#                             replicator2 = ?,
#                             hours1 = ?,
#                             hours2 = ?,
#                             is_success = ?,
#                             software = ?,
#                             is_confidential = ?,
#                             is_confidential_shared = ?,
#                             is_remote = ?,
#                             is_HPC = ?,
#                             runtime_code_hours = ?,
#                             data_statement = ?,
#                             repl_comments = ?,
#                             date_completed_repl = ?
#                         WHERE 
#                             paper_id = ? AND
#                             round = ?
#                         """, (
#                         r.email_of_replicator_1,
#                         r.email_of_replicator_2,
#                         r.hours_replicator_1,
#                         r.hours_replicator_2,
#                         r.is_success,
#                         r.software_used_in_package,
#                         r.is_confidential,
#                         r.shared_confidential,
#                         r.is_remote,
#                         r.is_HPC,
#                         r.running_time_of_code,
#                         r.data_statement,
#                         r.comments,
#                         Date(r.timestamp),
#                         r.paper_id,
#                         r.round
#                     ))
#                 end
                
#                 @info "Successfully processed report for paper $(r.paper_id), round $(r.round)"
#             catch e
#                 @warn "Error processing report for paper $(r.paper_id), round $(r.round): $e"
#             end
#         end
        
#         return to_process
#     else
#         @info "No reports need processing"
#         return nothing
#     end

# end

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
            gmail_g2g(r.firstname_of_author, r.paper_id, r.title,r.email_of_author, r.paper_slug, email2 = ismissing(r.email_of_second_author) ? nothing : r.email_of_second_author)
            
            return r
        end
    elseif decision == "revise"
        # Use the existing prepare_rnrs function but with robust status update
        println("Do you want to move on and send this RnR now or not?")
        yes_no_menu = RadioMenu(["No", "Yes"])  # Default is first option (No)
        if request(yes_no_menu) == 2 
            prepare_rnrs(paperID)
        else
            @info "decision for $paperID done"
            return
        end
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


function report_pdf_path(r::NamedTuple)
    localloc = get_dbox_loc(r.journal, r.paper_slug, r.round, full = true)
    # Compute PDF path
    pdf_filename = "$(get_case_id(r.journal, r.paper_slug, r.round, fpath = false)).pdf"
    pdf_path = joinpath(localloc,"repo", pdf_filename)
    return pdf_path
end


function write_report(paperID)
    # Get paper information
    paper = db_filter_paper(paperID)
    if nrow(paper) != 1
        error("Paper ID $paperID not found or has multiple entries")
    end

    r = NamedTuple(paper[1, :])

    # Validate current status
    if r.status != "replicator_back_de"
        error("Paper must be in 'replicator_back_de' status to prepare RnR report")
    end    
    # Set up paths
    localloc = get_dbox_loc(r.journal, r.paper_slug, r.round, full = true)
    repo_path = joinpath(localloc, "repo")
    
    # Handle repository - check if it exists first
    if isdir(repo_path)
        @info "Repository already exists at $repo_path"
        # Pull latest changes instead of cloning
        try
            run(Cmd(`git pull`, dir=repo_path))
            @info "Pulled latest changes from remote repository"
        catch e
            @warn "Could not pull latest changes: $e"
            @info "You may need to commit your local changes first"
        end
    else
        # Clone if it doesn't exist
        gh_clone_branch(r.gh_org_repo, "round$(r.round)", to = repo_path)
        @info "Cloned repository to $repo_path"
    end
    
    # Rename the template file from TEMPLATE.qmd to the correct filename
    template_path = joinpath(repo_path, "TEMPLATE.qmd")
    report_filename = "$(get_case_id(r.journal, r.paper_slug, r.round, fpath = false)).qmd"
    report_path = joinpath(repo_path, report_filename)

    if isfile(template_path) && !isfile(report_path)
        cp(template_path, report_path)
        @info "Renamed template to $report_filename"
    elseif !isfile(template_path)
        @warn "Template file not found at $template_path"
    end    
    # Open VSCode
    run(`code $repo_path`)
    
    # Compute PDF path
    pdf_filename = "$(get_case_id(r.journal, r.paper_slug, r.round,fpath = false)).pdf"
    pdf_path = joinpath(repo_path, pdf_filename)
    println(pdf_path)
    println(report_pdf_path(r))
    @assert pdf_path == report_pdf_path(r)
    
    @info """
    Report preparation started:
    1. Repository available at: $repo_path
    2. Report template renamed to: $report_filename (if needed)
    3. VSCode opened for editing
    
    IMPORTANT: After editing the report:
    1. Compile it to generate: $pdf_filename
    2. Commit your changes: git add . && git commit -m "Updated report"
    3. Push to GitHub: git push
    
    The GitHub repository is the source of truth for the report.
    The PDF will be used as an attachment in prepare_rnr.
    """
    
    return pdf_path
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

    try
        @assert isfile(report_pdf_path(r))
        println("✅ pdf report found.")
    catch
        @warn "you need to compile the report to pdf first!"
        println("done?")
        yes_no_menu = RadioMenu(["Yes","No"])  # Default is first option 
        if request(yes_no_menu) == 1
            @assert isfile(report_pdf_path(r))
        else
            @assert isfile(report_pdf_path(r))
        end
    end


    # Use the robust status update pattern
    update_paper_status(paperID, "replicator_back_de", "with_author", do_update = true) do con
        # Get current iteration
        iter_query = """
        SELECT * FROM iterations 
        WHERE paper_id = ? AND round = ?
        """
        current_iter = DataFrame(DBInterface.execute(con, iter_query, (paperID, r.round))) |> allowmissing
        
        if nrow(current_iter) != 1
            error("Iteration not found for paper $paperID, round $(r.round)")
        end
        
        # Create new iteration for next round
        rnew = deepcopy(r)
        rnew = merge(rnew, (round = r.round + 1,))

        @debug "old round = $(r.round)"
        @debug "new round = $(rnew.round)"
        
        
        # Create new branch on repo
        gh_create_branch_on_github_from(r.gh_org_repo, "round$(r.round)", "round$(rnew.round)")
        
        # Insert new iteration row
        new_iters = copy(current_iter)
        new_iter = new_iters[1,:] # creates a dataframerow

        new_iter.round = rnew.round
        new_iter.date_with_authors = today()
        
        # Clear fields that should be reset for new iteration
        for field in union([i[1] for i in JPE.reports_2_iterations() ], string.([:replicator1,:replicator2, :hours1, :hours2, :is_success, :date_arrived_from_authors, :date_assigned_repl, :date_completed_repl,:date_decision_de, :decision_de]))
            if hasproperty(new_iter, field)
                new_iter[field] = missing
            end
        end

        # # Set up Dropbox structure for new iteration
        setup_dropbox_structure!(new_iter, dbox_token)

        sleep(1)  # safety break

        # # Register the new iteration
        DuckDB.register_data_frame(con, DataFrame(new_iter), "new_iter")
        DBInterface.execute(con, "INSERT INTO iterations SELECT * FROM new_iter")
        
        # where is the report pdf?
        attachfile = report_pdf_path(r)
        @debug attachfile
        
        # Prepare email draft
        gmail_rnr(r.firstname_of_author, r.paper_id, r.title, new_iter.file_request_url_pkg, 
                 r.email_of_author, attachfile,
                 email2 = ismissing(r.email_of_second_author) ? nothing : r.email_of_second_author)

        # Update papers table with new round and file request ids
        DBInterface.execute(con, """
        UPDATE papers
        SET round = ?,
        date_with_authors = ?,
        file_request_id_pkg = ?,
        file_request_id_paper = ?
        WHERE paper_id = ?
        """, (rnew.round, new_iter.date_with_authors, new_iter.file_request_id_pkg, new_iter.file_request_id_paper, paperID))

        # Update old iteration with decision
        DBInterface.execute(con, """
        UPDATE iterations
        SET date_decision_de = ?, decision_de = 'rnr'
        WHERE paper_id = ? AND round = ?
        """, (today(), paperID, r.round))
        
        return new_iter
    end
end


function monitor_file_requests()
    # Filter papers for status "with_author" or "new_arrival"
    i = @chain db_df("papers") begin
        subset(:status => ByRow(.∈(Ref(["with_author","new_arrival"]))))
        select(:status, :paper_id)
        leftjoin(db_df("iterations"), on = [:paper_id])
        groupby(:paper_id)
        subset(:round => (x -> x .== maximum(x)))
        combine(identity)  # or select the columns you want
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
                println("File request arrived! ✅")
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

    if (nrow(arrived) > 0) && (nrow(papwaiting) > 0)
        reminders = intersect(arrived.paper_id, papwaiting.paper_id)  
        if length(reminders) > 0
            df_reminders = @chain papwaiting begin
                subset(:paper_id => ByRow(∈(reminders)))
            end
        end
    end

    # Use robust status updates
    if (nrow(arrived) > 0)
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
                    # submit_time = dbox_fr_submit_time(dbox_token, iter.file_request_path)
                    submit_time = today()
                    if !isnothing(submit_time)
                        DBInterface.execute(con, """
                        UPDATE iterations
                        SET date_arrived_from_authors = ?
                        WHERE paper_id = ? AND round = ?
                        """, (Date(submit_time), a.paper_id, a.round))
                        @info "File request arrived! ✅"
                    end
                    return a
                end
            catch e
                @warn "Error updating status for $(a.paper_id): $e"
            end
        end
    else
        @info "No file request arrived ❌"
    end

    return Dict(:waiting => waiting, :arrived => arrived, :remindJO => df_reminders) 
end
