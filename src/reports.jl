"""
Reporting tools for the JPE database.

This module provides functions for generating reports from the JPE database,
including global statistics, paper-specific reports, replicator workload reports,
and time-in-status reports.
"""


"""
    global_report(; save_csv=false, csv_path=nothing)

Generate a global report of the JPE database, including:
- Count of unique papers
- Total iterations
- Tabulation of papers by status

# Arguments
- `save_csv::Bool=false`: Whether to save the report as a CSV file
- `csv_path::Union{String, Nothing}=nothing`: Path to save the CSV file (if save_csv is true)

# Returns
- A tuple of DataFrames containing the report data
"""
function global_report(; save_csv=false, csv_path=nothing)
    # Query database for papers
    papers_df = db_df("papers")
    iterations_df = db_df("iterations")
    
    # 1. Count of unique papers
    unique_papers = nrow(papers_df)
    
    # 2. Total iterations
    total_iterations = nrow(iterations_df)
    
    # 3. Papers by status
    status_counts = @chain papers_df begin
        @groupby(:status)
        @combine(:count = length(:status))
        @transform(:percentage = round.(:count / unique_papers * 100, digits=1))
        @orderby(:count, rev=true)
    end
    
    # Create summary DataFrame
    summary_df = DataFrame(
        Metric = ["Unique Papers", "Total Iterations"],
        Value = [unique_papers, total_iterations]
    )
    
    # Print the reports with PrettyTables
    println("\n=== JPE Global Report ===\n")
    
    # Print summary
    pretty_table(summary_df; header=["Metric", "Value"], alignment=[:l, :r])
    
    println("\n--- Papers by Status ---\n")
    
    # Print status counts
    pretty_table(status_counts; 
                header=["Status", "Count", "Percentage (%)"], 
                alignment=[:l, :r, :r])
    
    # Optionally save as CSV
    if save_csv
        if isnothing(csv_path)
            csv_path = "jpe_global_report_$(Dates.format(today(), "yyyy-mm-dd")).csv"
        end
        
        # Save summary
        CSV.write(replace(csv_path, ".csv" => "_summary.csv"), summary_df)
        
        # Save status counts
        CSV.write(replace(csv_path, ".csv" => "_status.csv"), status_counts)
        
        println("\nReport saved to $(replace(csv_path, ".csv" => "_summary.csv")) and $(replace(csv_path, ".csv" => "_status.csv"))")
    end
    
    return (summary=summary_df, status=status_counts)
end

"""
    paper_report(paperID; save_csv=false, csv_path=nothing)

Generate a report for a specific paper, including:
- Paper details (ID, title, authors)
- Current status
- Days in current status
- Actor responsible for next action
- Timeline of status changes

# Arguments
- `paperID::String`: The ID of the paper to report on
- `save_csv::Bool=false`: Whether to save the report as a CSV file
- `csv_path::Union{String, Nothing}=nothing`: Path to save the CSV file (if save_csv is true)

# Returns
- A tuple of DataFrames containing the report data
"""
function paper_report(paperID; save_csv=false, csv_path=nothing)
    # Query database for paper
    paper_df = db_filter_paper(paperID)
    
    if nrow(paper_df) == 0
        println("Paper ID $paperID not found in database.")
        return nothing
    end
    
    paper = paper_df[1, :]
    
    # Get iterations for this paper
    iterations_df = with_db() do con
        DataFrame(DBInterface.execute(con, """
            SELECT * FROM iterations
            WHERE paper_id = ?
            ORDER BY round
        """, (paperID,)))
    end
    
    # Calculate days in current status
    days_in_status = calculate_days_in_status(paper)
    
    # Determine actor responsible for next action
    responsible_actor = determine_actor(paper.status)
    
    # Create paper details DataFrame
    details_df = DataFrame(
        Field = ["Paper ID", "Title", "Authors", "Journal", "Current Status", 
                "Days in Current Status", "Responsible Actor", "Current Round"],
        Value = [paper.paper_id, paper.title, 
                "$(paper.firstname_of_author) $(paper.surname_of_author)", 
                paper.journal, paper.status, days_in_status, 
                responsible_actor, paper.round]
    )
    
    # Create timeline DataFrame
    timeline_df = create_timeline(iterations_df)
    
    # Print the reports with PrettyTables
    println("\n=== Paper Report: $(paper.paper_id) ===\n")
    
    # Print paper details
    pretty_table(details_df; header=["Field", "Value"], alignment=[:l, :l])
    
    println("\n--- Timeline ---\n")
    
    # Print timeline
    if nrow(timeline_df) > 0
        pretty_table(timeline_df; 
                    header=["Date", "Event", "Details"], 
                    alignment=[:l, :l, :l])
    else
        println("No timeline events found for this paper.")
    end
    
    # Optionally save as CSV
    if save_csv
        if isnothing(csv_path)
            csv_path = "jpe_paper_report_$(paperID)_$(Dates.format(today(), "yyyy-mm-dd")).csv"
        end
        
        # Save details
        CSV.write(replace(csv_path, ".csv" => "_details.csv"), details_df)
        
        # Save timeline
        if nrow(timeline_df) > 0
            CSV.write(replace(csv_path, ".csv" => "_timeline.csv"), timeline_df)
        end
        
        println("\nReport saved to $(replace(csv_path, ".csv" => "_details.csv")) and $(replace(csv_path, ".csv" => "_timeline.csv"))")
    end
    
    return (details=details_df, timeline=timeline_df)
end

"""
    replicator_workload_report(; save_csv=false, csv_path=nothing, update_gsheet=false)

Generate a report of replicator workloads, including:
- Replicator name/email
- Number of papers assigned
- List of paper IDs with their statuses

# Arguments
- `save_csv::Bool=false`: Whether to save the report as a CSV file
- `csv_path::Union{String, Nothing}=nothing`: Path to save the CSV file (if save_csv is true)
- `update_gsheet::Bool=false`: Whether to update the Google Sheet with replicator workloads

# Returns
- A DataFrame containing the report data
"""
function replicator_workload_report(; save_csv=false, csv_path=nothing, update_gsheet=false)
    # Query database for papers assigned to replicators
    iterations_df = with_db() do con
        DataFrame(DBInterface.execute(con, """
            SELECT i.*, p.status
            FROM iterations i
            JOIN papers p ON i.paper_id = p.paper_id AND i.round = p.round
            WHERE i.replicator1 IS NOT NULL OR i.replicator2 IS NOT NULL
        """))
    end
    
    # Get current replicators
    replicators_df = read_replicators()
    
    # Calculate workload for each replicator
    workload_df = calculate_replicator_workload(iterations_df, replicators_df)
    
    # Print the report with PrettyTables
    println("\n=== Replicator Workload Report ===\n")
    
    pretty_table(workload_df; 
                header=["Name", "Email", "Current Workload", "Papers"], 
                alignment=[:l, :l, :r, :l])
    
    # Optionally save as CSV
    if save_csv
        if isnothing(csv_path)
            csv_path = "jpe_replicator_workload_$(Dates.format(today(), "yyyy-mm-dd")).csv"
        end
        
        CSV.write(csv_path, workload_df)
        
        println("\nReport saved to $csv_path")
    end
    
    # Optionally update Google Sheet
    if update_gsheet
        update_replicator_workload_gsheet(workload_df)
    end
    
    return workload_df
end

"""
    update_replicator_workload_gsheet(workload_df)

Update the replicator workload in the Google Sheet.

# Arguments
- `workload_df::DataFrame`: DataFrame containing replicator workload data

# Returns
- A string indicating success or failure
"""
function update_replicator_workload_gsheet(workload_df)
    # Authenticate with Google Sheets
    gs4_auth()
    
    # Create a simplified DataFrame for updating the Google Sheet
    update_df = select(workload_df, :email, :current_workload)
    
    # Update the Google Sheet
    try
        R"""
        # Get the sheet ID
        sheet_id <- $(gs_replicators_id())
        
        # Read the current sheet
        current_sheet <- googlesheets4::read_sheet(sheet_id, sheet = 'confirmed')
        
        # For each replicator in workload_df, update their workload in the Google Sheet
        for (i in 1:nrow($(update_df))) {
            email <- $(update_df)[i, "email"]
            workload <- $(update_df)[i, "current_workload"]
            
            # Find the row in the current sheet with this email
            row_idx <- which(current_sheet$email == email)
            
            if (length(row_idx) > 0) {
                # Update the "Number of current packages" column
                googlesheets4::range_write(
                    sheet_id,
                    data = workload,
                    sheet = "confirmed",
                    range = paste0("Number of current packages", row_idx + 1)  # +1 for header row
                )
            }
        }
        """
        
        println("\nGoogle Sheet updated successfully")
        return "Google Sheet updated successfully"
    catch e
        println("\nError updating Google Sheet: $e")
        return "Error updating Google Sheet: $e"
    end
end

"""
    time_in_status_report(; save_csv=false, csv_path=nothing)

Generate a report of the average time papers spend in each status.

# Arguments
- `save_csv::Bool=false`: Whether to save the report as a CSV file
- `csv_path::Union{String, Nothing}=nothing`: Path to save the CSV file (if save_csv is true)

# Returns
- A DataFrame containing the report data
"""
function time_in_status_report(; save_csv=false, csv_path=nothing)
    # Query database for papers and iterations
    papers_df = db_df("papers")
    iterations_df = db_df("iterations")
    
    # Calculate time in each status for all papers
    status_times_df = calculate_time_in_status(papers_df, iterations_df)
    
    # Print the report with PrettyTables
    println("\n=== Time in Status Report ===\n")
    
    pretty_table(status_times_df; 
                header=["Status", "Average Days", "Minimum Days", "Maximum Days", "Papers in Status"], 
                alignment=[:l, :r, :r, :r, :r])
    
    # Optionally save as CSV
    if save_csv
        if isnothing(csv_path)
            csv_path = "jpe_time_in_status_$(Dates.format(today(), "yyyy-mm-dd")).csv"
        end
        
        CSV.write(csv_path, status_times_df)
        
        println("\nReport saved to $csv_path")
    end
    
    return status_times_df
end

# Helper functions

"""
    calculate_days_in_status(paper)

Calculate the number of days a paper has been in its current status.

# Arguments
- `paper`: A NamedTuple or DataFrame row representing a paper

# Returns
- The number of days the paper has been in its current status
"""
function calculate_days_in_status(paper)
    status = paper.status
    
    # Determine the date the paper entered its current status
    date_entered = missing
    
    if status == "new_arrival"
        date_entered = paper.first_arrival_date
    elseif status == "with_author"
        date_entered = paper.date_with_authors
    elseif status == "author_back_de"
        # Query iterations table for date_arrived_from_authors
        iter = with_db() do con
            DataFrame(DBInterface.execute(con, """
                SELECT date_arrived_from_authors
                FROM iterations
                WHERE paper_id = ? AND round = ?
            """, (paper.paper_id, paper.round)))
        end
        
        if nrow(iter) > 0 && !ismissing(iter[1, :date_arrived_from_authors])
            date_entered = iter[1, :date_arrived_from_authors]
        end
    elseif status == "with_replicator"
        # Query iterations table for date_assigned_repl
        iter = with_db() do con
            DataFrame(DBInterface.execute(con, """
                SELECT date_assigned_repl
                FROM iterations
                WHERE paper_id = ? AND round = ?
            """, (paper.paper_id, paper.round)))
        end
        
        if nrow(iter) > 0 && !ismissing(iter[1, :date_assigned_repl])
            date_entered = iter[1, :date_assigned_repl]
        end
    elseif status == "replicator_back_de"
        # Query iterations table for date_completed_repl
        iter = with_db() do con
            DataFrame(DBInterface.execute(con, """
                SELECT date_completed_repl
                FROM iterations
                WHERE paper_id = ? AND round = ?
            """, (paper.paper_id, paper.round)))
        end
        
        if nrow(iter) > 0 && !ismissing(iter[1, :date_completed_repl])
            date_entered = iter[1, :date_completed_repl]
        end
    elseif status == "acceptable_package"
        # Query iterations table for date_decision_de
        iter = with_db() do con
            DataFrame(DBInterface.execute(con, """
                SELECT date_decision_de
                FROM iterations
                WHERE paper_id = ? AND round = ?
            """, (paper.paper_id, paper.round)))
        end
        
        if nrow(iter) > 0 && !ismissing(iter[1, :date_decision_de])
            date_entered = iter[1, :date_decision_de]
        end
    elseif status == "published_package"
        # Query iterations table for date_published
        iter = with_db() do con
            DataFrame(DBInterface.execute(con, """
                SELECT date_published
                FROM iterations
                WHERE paper_id = ? AND round = ?
            """, (paper.paper_id, paper.round)))
        end
        
        if nrow(iter) > 0 && !ismissing(iter[1, :date_published])
            date_entered = iter[1, :date_published]
        end
    end
    
    # Calculate days in status
    if !ismissing(date_entered)
        return Dates.value(today() - date_entered)
    else
        return missing
    end
end

"""
    determine_actor(status)

Determine the actor responsible for the next action based on the paper's status.

# Arguments
- `status::String`: The current status of the paper

# Returns
- A string indicating the responsible actor
"""
function determine_actor(status)
    if status == "new_arrival"
        return "Data Editor"
    elseif status == "with_author"
        return "Author"
    elseif status == "author_back_de"
        return "Data Editor"
    elseif status == "with_replicator"
        return "Replicator"
    elseif status == "replicator_back_de"
        return "Data Editor"
    elseif status == "acceptable_package"
        return "Journal Office"
    elseif status == "published_package"
        return "None (Completed)"
    else
        return "Unknown"
    end
end

"""
    create_timeline(iterations_df)

Create a timeline of events for a paper based on its iterations.

# Arguments
- `iterations_df::DataFrame`: DataFrame containing iterations data for a paper

# Returns
- A DataFrame representing the timeline of events
"""
function create_timeline(iterations_df)
    timeline = DataFrame(Date = Date[], Event = String[], Details = String[])
    
    for iter in eachrow(iterations_df)
        # First arrival
        if !ismissing(iter.first_arrival_date)
            push!(timeline, (iter.first_arrival_date, "Paper Arrived", "Round $(iter.round)"))
        end
        
        # Sent to author
        if !ismissing(iter.date_with_authors)
            push!(timeline, (iter.date_with_authors, "Sent to Author", "Round $(iter.round)"))
        end
        
        # Received from author
        if !ismissing(iter.date_arrived_from_authors)
            push!(timeline, (iter.date_arrived_from_authors, "Received from Author", "Round $(iter.round)"))
        end
        
        # Assigned to replicator
        if !ismissing(iter.date_assigned_repl)
            repl_details = "Assigned to $(iter.replicator1)"
            if !ismissing(iter.replicator2)
                repl_details *= " and $(iter.replicator2)"
            end
            push!(timeline, (iter.date_assigned_repl, "Assigned to Replicator", repl_details))
        end
        
        # Completed by replicator
        if !ismissing(iter.date_completed_repl)
            success_str = ismissing(iter.is_success) ? "Unknown" : (iter.is_success ? "Success" : "Failure")
            push!(timeline, (iter.date_completed_repl, "Completed by Replicator", "Result: $success_str"))
        end
        
        # Decision by Data Editor
        if !ismissing(iter.date_decision_de)
            decision = ismissing(iter.decision_de) ? "Unknown" : iter.decision_de
            push!(timeline, (iter.date_decision_de, "Decision by Data Editor", "Decision: $decision"))
        end
        
        # Published
        if hasproperty(iter, :date_published) && !ismissing(iter.date_published)
            push!(timeline, (iter.date_published, "Package Published", ""))
        end
    end
    
    # Sort by date
    sort!(timeline, :Date)
    
    return timeline
end

"""
    calculate_replicator_workload(iterations_df, replicators_df)

Calculate the workload for each replicator.

# Arguments
- `iterations_df::DataFrame`: DataFrame containing iterations data
- `replicators_df::DataFrame`: DataFrame containing replicator data

# Returns
- A DataFrame containing replicator workload data
"""
function calculate_replicator_workload(iterations_df, replicators_df)
    # Filter for papers currently with replicators
    current_papers = @chain iterations_df begin
        @subset(:status .== "with_replicator")
    end
    
    # Create a DataFrame to store workload data
    workload_df = DataFrame(
        name = String[],
        email = String[],
        current_workload = Int[],
        papers = String[]
    )
    
    # Calculate workload for each replicator
    for replicator in eachrow(replicators_df)
        # Find papers assigned to this replicator
        replicator_papers1 = @chain current_papers begin
            @subset(:replicator1 .== replicator.email)
            select(:paper_id, :round, :status)
        end
        
        replicator_papers2 = @chain current_papers begin
            @subset(:replicator2 .== replicator.email)
            select(:paper_id, :round, :status)
        end
        
        # Combine papers from replicator1 and replicator2
        replicator_papers = vcat(replicator_papers1, replicator_papers2)
        
        # Remove duplicates (in case a replicator is both replicator1 and replicator2 for the same paper)
        unique!(replicator_papers, [:paper_id, :round])
        
        # Create a string representation of the papers
        papers_str = join(["$(p.paper_id) (R$(p.round))" for p in eachrow(replicator_papers)], ", ")
        
        # Add to workload DataFrame
        push!(workload_df, (
            name = replicator.name,
            email = replicator.email,
            current_workload = nrow(replicator_papers),
            papers = papers_str
        ))
    end
    
    # Sort by workload (descending)
    sort!(workload_df, :current_workload, rev=true)
    
    return workload_df
end

"""
    calculate_time_in_status(papers_df, iterations_df)

Calculate the average, minimum, and maximum time papers spend in each status.

# Arguments
- `papers_df::DataFrame`: DataFrame containing papers data
- `iterations_df::DataFrame`: DataFrame containing iterations data

# Returns
- A DataFrame containing time-in-status data
"""
function calculate_time_in_status(papers_df, iterations_df)
    # Create a DataFrame to store time-in-status data
    statuses = db_statuses()
    n = length(statuses)
    status_times_df = DataFrame(
        status = statuses,
        avg_days = Vector{Union{Missing, Float64}}(missing, n),
        min_days = Vector{Union{Missing, Int}}(missing, n),
        max_days = Vector{Union{Missing, Int}}(missing, n),
        papers_count = zeros(Int, n)
    )
    
    # Calculate time in status for each status
    for status in db_statuses()
        # Filter papers in this status
        status_papers = @chain papers_df begin
            @subset(:status .== status)
        end
        
        # Calculate days in status for each paper
        days_in_status = Int[]
        for paper in eachrow(status_papers)
            days = calculate_days_in_status(paper)
            if !ismissing(days)
                push!(days_in_status, days)
            end
        end
        
        # Calculate statistics
        avg_days = isempty(days_in_status) ? missing : mean(days_in_status)
        min_days = isempty(days_in_status) ? missing : minimum(days_in_status)
        max_days = isempty(days_in_status) ? missing : maximum(days_in_status)
        
        # Update status_times_df
        idx = findfirst(status_times_df.status .== status)
        if !isnothing(idx)
            status_times_df[idx, :avg_days] = avg_days
            status_times_df[idx, :min_days] = min_days
            status_times_df[idx, :max_days] = max_days
            status_times_df[idx, :papers_count] = nrow(status_papers)
        end
    end
    
    return status_times_df
end

"""
    save_report_as_csv(df, path)

Save a DataFrame as a CSV file.

# Arguments
- `df::DataFrame`: The DataFrame to save
- `path::String`: The path to save the CSV file

# Returns
- The path to the saved CSV file
"""
function save_report_as_csv(df, path)
    CSV.write(path, df)
    return path
end
