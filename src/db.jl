db_statuses() = ["new_arrival","with_author","with_replicator","replicator_back_de","author_back_de","acceptable_package","published_package"]

"replace missing with nothing"
missnothing(x) = ismissing(x) ? nothing : x
missna(x) = ismissing(x) ? "NA" : x

# yesno_bool = passmissing(x -> lowercase(x) == "yes")
yesno_bool(x) = ismissing(x) ? false : (lowercase(x) == "yes" ? true : false)

function db_release_connection()
    lock(DB_LOCK) do
        if DB_CONNECTION[] !== nothing
            try
                DBInterface.close(DB_CONNECTION[])
                println("✓ Database connection closed")
            catch e
                println("Warning: Error closing connection: $e")
            end
            DB_CONNECTION[] = nothing
        else
            println("No active connection to release")
        end
    end
end

function db_reconnect()
    lock(DB_LOCK) do
        if DB_CONNECTION[] === nothing
            DB_CONNECTION[] = DBInterface.connect(DuckDB.DB, DB_PATH)
            println("✓ Database connection re-established")
        else
            println("Connection already active")
        end
    end
end

# Optional: Check connection status
function db_connection_status()
    lock(DB_LOCK) do
        if DB_CONNECTION[] === nothing
            println("No active connection")
            return :disconnected
        elseif isopen(DB_CONNECTION[])
            println("Connection active and open")
            return :connected
        else
            println("Connection exists but not open")
            DB_CONNECTION[] = nothing  # Clean up stale reference
            return :stale
        end
    end
end

db_write_backup(table,y) = safe_csv_append(joinpath(DB_JPE,"$table.csv"), y)
db_read_backup(table) = CSV.read(joinpath(DB_JPE,"$table.csv"), DataFrame)

function safe_csv_append(path::String, df::DataFrame)
    is_new_file = !isfile(path)
    CSV.write(path, df; append=(!is_new_file), writeheader=is_new_file)
end

function with_db(f::Function)
    lock(DB_LOCK) do
        if DB_CONNECTION[] === nothing || !isopen(DB_CONNECTION[])
            DB_CONNECTION[] = DBInterface.connect(DuckDB.DB, DB_PATH)
        end
        f(DB_CONNECTION[])
    end
end

function robust_db_operation(f::Function)
    with_db() do con
        DBInterface.execute(con, "BEGIN TRANSACTION")
        try
            result = f(con)
            DBInterface.execute(con, "COMMIT")
            return result
        catch e
            DBInterface.execute(con, "ROLLBACK")
            rethrow(e)
        end
    end
end


# First, create a simple test table
function create_test_table()
    with_db() do con
        DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS test_persistence (id INTEGER, name VARCHAR)")
        DBInterface.execute(con, "INSERT INTO test_persistence VALUES (1, 'test')")
    end
end

# Then check if it persists
function check_test_table()
    with_db() do con
        DBInterface.execute(con, "SELECT * FROM test_persistence") |> DataFrame
    end
end

function testing()
    create_test_table()
    with_db() do con
        DBInterface.execute(con, """
        UPDATE test_persistence
        SET name = 'new'
        """)
    end
    check_test_table()
end


function db_df(table::String)
    with_db() do con
        DBInterface.execute(con,"SELECT * FROM $(table)") |> DataFrame
    end
end

function db_list_tables()
    with_db() do con
        DBInterface.execute(con, "SHOW TABLES")
    end
end

function db_df_where(table::String, where_col::String, where_val)
    with_db() do con
        query = "SELECT * FROM $table WHERE $where_col = ?"
        stmt = DBInterface.prepare(con, query)
        DataFrame(DBInterface.execute(stmt, (where_val,)))
    end
end

function db_table_exists_and_not_empty(table::String)
    # Only allow alphanumeric and underscore table names to prevent SQL injection
    if !occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", table)
        @warn "Invalid table name: $table"
        return false
    end

    query = "SELECT 1 FROM $table LIMIT 1"
    try
        with_db() do con
            nrow(DataFrame(DBInterface.execute(con, query))) > 0
        end
    catch e
        # @warn "Table does not exist or cannot be queried." exception=(e, catch_backtrace())
        return false
    end
end

function db_update_cell(table::String,whereclause,var,val)
    with_db() do con
        DBInterface.execute(con, "BEGIN TRANSACTION")
        stmt = DBInterface.prepare(con, """
        UPDATE $table
        SET $var = ?
        WHERE $whereclause
        """
        )
        DBInterface.execute(stmt, (val,))
        DBInterface.execute(con, "COMMIT")  # Explicit commit
    end
end

function db_rollback()
    with_db() do con
        DBInterface.execute(con, "ROLLBACK")
    end
end

function db_update_status(paperID, status)
    if status ∉ db_statuses()
        throw(ArgumentError("invalid status provided: $status. needs to be one of $(db_statuses())"))
    end
    with_db() do con
        DBInterface.execute(con, "BEGIN TRANSACTION")
        stmt = DBInterface.prepare(con, """
        UPDATE papers
        SET status = ?
        WHERE paper_id = ?
        """
        )
        DBInterface.execute(stmt, (status, paperID))
        DBInterface.execute(con, "COMMIT")  # Explicit commit
    end
end

"""
    update_paper_status(f::Function, paperID, from_status, to_status)

Update a paper's status from one status to another within a transaction,
executing a function that performs additional database operations.
This ensures that status updates only happen if all operations succeed.

# Arguments
- `paperID`: The ID of the paper to update
- `from_status`: The expected current status of the paper
- `to_status`: The new status to set
- `f::Function`: A function that takes a database connection and performs additional operations

# Returns
- The result of the function `f`

# Example
```julia
update_paper_status(paperID, "with_author", "author_back_de") do con
    # Additional database operations
    DBInterface.execute(con, "UPDATE iterations SET date_arrived = ? WHERE paper_id = ?", 
                       (today(), paperID))
    return "Success"
end
```
"""
function update_paper_status(f::Function, paperID, from_status, to_status; do_update = true)
    if to_status ∉ db_statuses()
        throw(ArgumentError("invalid target status: $to_status. needs to be one of $(db_statuses())"))
    end

    return robust_db_operation() do con
        # First check if paper exists and has the expected status
        paper_query = """
        SELECT status FROM papers WHERE paper_id = ?
        """
        paper_result = DataFrame(DBInterface.execute(con, paper_query, (paperID,)))
        
        if nrow(paper_result) == 0
            error("Paper ID $paperID not found")
        end
        
        current_status = paper_result[1, :status]
        if current_status != from_status
            error("Paper ID $paperID has status '$current_status', expected '$from_status'")
        end
        
        # Execute the provided function with the connection
        result = f(con)
        
        # Update the status
        if do_update
            DBInterface.execute(con, """
            UPDATE papers
            SET status = ?
            WHERE paper_id = ?
            """, (to_status, paperID))
        else
            @warn "not updated!"
        end

        return result
    end
end


"""
    validate_paper_status(paperID)

Validate that a paper's status is consistent with its data in the iterations table.

# Arguments
- `paperID`: The ID of the paper to validate

# Returns
- A tuple with (is_valid, issues) where issues is a list of any inconsistencies found
"""
function validate_paper_status(paperID)
    paper = db_filter_paper(paperID)
    if nrow(paper) != 1
        return (false, ["Paper ID $paperID not found or has multiple entries"])
    end
    
    r = NamedTuple(paper[1, :])
    
    # Get iterations
    iterations = with_db() do con
        DataFrame(DBInterface.execute(con, """
            SELECT * FROM iterations
            WHERE paper_id = ?
            ORDER BY round
        """, (paperID,)))
    end
    
    if nrow(iterations) == 0
        return (false, ["No iterations found for paper $paperID"])
    end
    
    issues = String[]
    
    # Check status against iterations data
    current_round = r.round
    current_iter = filter(row -> row.round == current_round, iterations)
    
    if nrow(current_iter) != 1
        push!(issues, "No iteration found for current round $(current_round)")
        return (false, issues)
    end
    
    iter = NamedTuple(current_iter[1, :])
    
    # Validate status based on iteration data
    if r.status == "new_arrival"
        # Should have no dates set except first_arrival_date
        if !ismissing(iter.date_with_authors) || 
           !ismissing(iter.date_arrived_from_authors) ||
           !ismissing(iter.date_assigned_repl) ||
           !ismissing(iter.date_completed_repl) ||
           !ismissing(iter.date_decision_de)
            push!(issues, "Status is 'new_arrival' but has dates set that indicate further progress")
        end
    elseif r.status == "with_author"
        # Should have date_with_authors set but not date_arrived_from_authors
        if ismissing(iter.date_with_authors)
            push!(issues, "Status is 'with_author' but date_with_authors is not set")
        end
        if !ismissing(iter.date_arrived_from_authors)
            push!(issues, "Status is 'with_author' but date_arrived_from_authors is set")
        end
    elseif r.status == "author_back_de"
        # Should have date_arrived_from_authors set but not date_assigned_repl
        if ismissing(iter.date_arrived_from_authors)
            push!(issues, "Status is 'author_back_de' but date_arrived_from_authors is not set")
        end
        if !ismissing(iter.date_assigned_repl)
            push!(issues, "Status is 'author_back_de' but date_assigned_repl is set")
        end
    elseif r.status == "with_replicator"
        # Should have date_assigned_repl set but not date_completed_repl
        if ismissing(iter.date_assigned_repl)
            push!(issues, "Status is 'with_replicator' but date_assigned_repl is not set")
        end
        if !ismissing(iter.date_completed_repl)
            push!(issues, "Status is 'with_replicator' but date_completed_repl is set")
        end
    elseif r.status == "replicator_back_de"
        # Should have date_completed_repl set but not date_decision_de
        if ismissing(iter.date_completed_repl)
            push!(issues, "Status is 'replicator_back_de' but date_completed_repl is not set")
        end
        if !ismissing(iter.date_decision_de)
            push!(issues, "Status is 'replicator_back_de' but date_decision_de is set")
        end
    elseif r.status == "acceptable_package"
        # Should have date_decision_de set and decision_de == "accept"
        if ismissing(iter.date_decision_de)
            push!(issues, "Status is 'acceptable_package' but date_decision_de is not set")
        end
        if iter.decision_de != "accept"
            push!(issues, "Status is 'acceptable_package' but decision_de is not 'accept'")
        end
    elseif r.status == "published_package"
        # Should have date_published set
        if ismissing(iter.date_published)
            push!(issues, "Status is 'published_package' but date_published is not set")
        end
    else
        push!(issues, "Unknown status: $(r.status)")
    end
    
    return (isempty(issues), issues)
end

"""
    repair_paper_status(paperID)

Attempt to repair a paper's status based on its data in the iterations table.

# Arguments
- `paperID`: The ID of the paper to repair

# Returns
- A tuple with (success, old_status, new_status, message)
"""
function repair_paper_status(paperID)
    valid, issues = validate_paper_status(paperID)
    
    if valid
        return (true, nothing, nothing, "Paper status is already valid")
    end
    
    paper = db_filter_paper(paperID)
    if nrow(paper) != 1
        return (false, nothing, nothing, "Paper ID $paperID not found or has multiple entries")
    end
    
    r = NamedTuple(paper[1, :])
    old_status = r.status
    
    # Get iterations
    iterations = with_db() do con
        DataFrame(DBInterface.execute(con, """
            SELECT * FROM iterations
            WHERE paper_id = ?
            ORDER BY round
        """, (paperID,)))
    end
    
    if nrow(iterations) == 0
        return (false, old_status, nothing, "No iterations found for paper $paperID")
    end
    
    current_round = r.round
    current_iter = filter(row -> row.round == current_round, iterations)
    
    if nrow(current_iter) != 1
        return (false, old_status, nothing, "No iteration found for current round $(current_round)")
    end
    
    iter = NamedTuple(current_iter[1, :])
    
    # Determine correct status based on iteration data
    new_status = nothing
    
    if !ismissing(iter.date_published)
        new_status = "published_package"
    elseif !ismissing(iter.date_decision_de) && iter.decision_de == "accept"
        new_status = "acceptable_package"
    elseif !ismissing(iter.date_completed_repl) && ismissing(iter.date_decision_de)
        new_status = "replicator_back_de"
    elseif !ismissing(iter.date_assigned_repl) && ismissing(iter.date_completed_repl)
        new_status = "with_replicator"
    elseif !ismissing(iter.date_arrived_from_authors) && ismissing(iter.date_assigned_repl)
        new_status = "author_back_de"
    elseif !ismissing(iter.date_with_authors) && ismissing(iter.date_arrived_from_authors)
        new_status = "with_author"
    else
        new_status = "new_arrival"
    end
    
    if new_status == old_status
        return (true, old_status, new_status, "Status is already correct")
    end
    
    # Update the status
    try
        with_db() do con
            DBInterface.execute(con, """
                UPDATE papers
                SET status = ?
                WHERE paper_id = ?
            """, (new_status, paperID))
        end
        
        return (true, old_status, new_status, "Status updated from '$old_status' to '$new_status'")
    catch e
        return (false, old_status, new_status, "Error updating status: $e")
    end
end



function set_status!(paperID; force_status = nothing, verbose = true)
    valid, issues = validate_paper_status(paperID)
    if valid && isnothing(force_status)
        verbose && println("✓ Paper status is already valid. No changes needed.")
        return (true, nothing, nothing, "Paper status is already valid")
    end
    
    # Get paper information
    paper = db_filter_paper(paperID)
    if nrow(paper) != 1
        return (false, nothing, nothing, "Paper ID $paperID not found or has multiple entries")
    end
    
    r = NamedTuple(paper[1, :])
    old_status = r.status
    
    # If force_status is provided, validate it
    if !isnothing(force_status)
        if force_status ∉ db_statuses()
            return (false, old_status, nothing, "Invalid status: $force_status. Must be one of $(db_statuses())")
        end
        new_status = force_status
    else
        # Determine correct status based on iteration data
        iterations = with_db() do con
            DataFrame(DBInterface.execute(con, """
                SELECT * FROM iterations
                WHERE paper_id = ?
                ORDER BY round
            """, (paperID,)))
        end
        
        if nrow(iterations) == 0
            return (false, old_status, nothing, "No iterations found for paper $paperID")
        end
        
        current_round = r.round
        current_iter = filter(row -> row.round == current_round, iterations)
        
        if nrow(current_iter) != 1
            return (false, old_status, nothing, "No iteration found for current round $(current_round)")
        end
        
        iter = current_iter[1, :]
        
        # Determine correct status based on iteration data
        # if !ismissing(iter.date_published)
        #     new_status = "published_package"
        if !ismissing(iter.date_decision_de) && iter.decision_de == "accept"
            new_status = "acceptable_package"
        elseif !ismissing(iter.date_completed_repl) && ismissing(iter.date_decision_de)
            new_status = "replicator_back_de"
        elseif !ismissing(iter.date_assigned_repl) && ismissing(iter.date_completed_repl)
            new_status = "with_replicator"
        elseif !ismissing(iter.date_arrived_from_authors) && ismissing(iter.date_assigned_repl)
            new_status = "author_back_de"
        elseif !ismissing(iter.date_with_authors) && ismissing(iter.date_arrived_from_authors)
            new_status = "with_author"
        else
            new_status = "new_arrival"
        end
    end
    
    if new_status == old_status
        verbose && println("✓ Status is already correct: $old_status")
        return (true, old_status, new_status, "Status is already correct")
    end
    
    # Update the status using a transaction
    try
        result = robust_db_operation() do con
            DBInterface.execute(con, """
                UPDATE papers
                SET status = ?
                WHERE paper_id = ?
            """, (new_status, paperID))
            return true
        end
        
        if result
            verbose && println("✓ Status updated from '$old_status' to '$new_status'")
            return (true, old_status, new_status, "Status updated from '$old_status' to '$new_status'")
        else
            return (false, old_status, new_status, "Failed to update status")
        end
    catch e
        return (false, old_status, new_status, "Error updating status: $e")
    end
end    

function db_filter_status(status::String)
    if status ∉ db_statuses()
        throw(ArgumentError("invalid status provided: $status. needs to be one of $(db_statuses())"))
    end
        
    with_db() do con
        DBInterface.execute(con, "SELECT * FROM papers WHERE status = ?", (status,)) |> DataFrame
    end
end
function db_filter_status(status1::String,status2::String)
    if (status1 ∉ db_statuses()) || (status2 ∉ db_statuses())
        throw(ArgumentError("invalid status provided: $status1, $status2. needs to be one of $(db_statuses())"))
    end
    with_db() do con
        DBInterface.execute(con, "SELECT * FROM papers WHERE status = ? OR status = ?", (status1,status2,)) |> DataFrame
    end
end

function db_filter_paper(id)
    with_db() do con
        DBInterface.execute(con, "SELECT * FROM papers WHERE paper_id = ?", (id,)) |> DataFrame
    end
end

function db_filter_iteration(id,round)
    with_db() do con
        DBInterface.execute(con, "SELECT * FROM iterations WHERE paper_id = ? AND round = ?", (id,round,)) |> DataFrame
    end
end


function db_table_exists(table::String)
    with_db() do con
        stmt = DBInterface.prepare(con, """
            SELECT 1
            FROM information_schema.tables
            WHERE table_name = ?
            LIMIT 1
        """)
        nrow(DataFrame(DBInterface.execute(stmt, (table,)))) > 0
    end
end

"""
    db_get_table_schema(table::String)

Return the schema definition for a given table as a dictionary mapping column names
to their data types and constraints.

# Arguments
- `table::String`: The name of the table to get the schema for

# Returns
- `Dict{String, Dict{Symbol, Any}}`: A dictionary mapping column names to their properties
"""
function db_get_table_schema(table::String)
    schemas = Dict{String, Dict{String, Dict{Symbol, Any}}}(
        "papers" => Dict(
            "timestamp" => Dict(:type => "TIMESTAMP", :constraints => ""),
            "journal" => Dict(:type => "VARCHAR", :constraints => ""),
            "paper_id" => Dict(:type => "VARCHAR", :constraints => "UNIQUE"),
            "title" => Dict(:type => "VARCHAR", :constraints => ""),
            "firstname_of_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "surname_of_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "email_of_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "email_of_second_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "handling_editor" => Dict(:type => "VARCHAR", :constraints => ""),
            "is_confidential" => Dict(:type => "BOOLEAN", :constraints => ""),
            "share_confidential" => Dict(:type => "BOOLEAN", :constraints => ""),
            "comments" => Dict(:type => "VARCHAR", :constraints => ""),
            "paper_slug" => Dict(:type => "VARCHAR", :constraints => ""),
            "first_arrival_date" => Dict(:type => "DATE", :constraints => ""),
            "status" => Dict(:type => "VARCHAR", :constraints => ""),
            "round" => Dict(:type => "INTEGER", :constraints => ""),
            "file_request_id_pkg" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_path" => Dict(:type => "VARCHAR", :constraints => ""),
            "repl_package_path" => Dict(:type => "VARCHAR", :constraints => ""),
            "paper_path" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_path_full" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_url_pkg" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_id_paper" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_url_paper" => Dict(:type => "VARCHAR", :constraints => ""),
            "date_with_authors" => Dict(:type => "DATE", :constraints => ""),
            "is_remote" => Dict(:type => "BOOLEAN", :constraints => ""),
            "is_HPC" => Dict(:type => "BOOLEAN", :constraints => ""),
            "data_statement" => Dict(:type => "VARCHAR", :constraints => ""),
            "software" => Dict(:type => "VARCHAR", :constraints => ""),
            "github_url" => Dict(:type => "VARCHAR", :constraints => ""),
            "gh_org_repo" => Dict(:type => "VARCHAR", :constraints => "")
        ),
        "form_arrivals" => Dict(
            "paper_id" => Dict(:type => "VARCHAR", :constraints => ""),
            "journal" => Dict(:type => "VARCHAR", :constraints => ""),
            "comments" => Dict(:type => "VARCHAR", :constraints => "")
        ),
        "iterations" => Dict(
            "timestamp" => Dict(:type => "TIMESTAMP", :constraints => ""),
            "journal" => Dict(:type => "VARCHAR", :constraints => ""),
            "paper_id" => Dict(:type => "VARCHAR", :constraints => ""),
            "title" => Dict(:type => "VARCHAR", :constraints => ""),
            "firstname_of_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "surname_of_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "email_of_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "email_of_second_author" => Dict(:type => "VARCHAR", :constraints => ""),
            "handling_editor" => Dict(:type => "VARCHAR", :constraints => ""),
            "is_confidential" => Dict(:type => "BOOLEAN", :constraints => ""),
            "share_confidential" => Dict(:type => "BOOLEAN", :constraints => ""),
            "comments" => Dict(:type => "VARCHAR", :constraints => ""),
            "paper_slug" => Dict(:type => "VARCHAR", :constraints => ""),
            "first_arrival_date" => Dict(:type => "DATE", :constraints => ""),
            "round" => Dict(:type => "INTEGER", :constraints => ""),
            "replicator1" => Dict(:type => "VARCHAR", :constraints => ""),
            "replicator2" => Dict(:type => "VARCHAR", :constraints => ""),
            "hours1" => Dict(:type => "NUMERIC", :constraints => ""),
            "hours2" => Dict(:type => "NUMERIC", :constraints => ""),
            "is_success" => Dict(:type => "BOOLEAN", :constraints => ""),
            "software" => Dict(:type => "VARCHAR", :constraints => ""),
            "is_confidential_shared" => Dict(:type => "BOOLEAN", :constraints => ""),
            "is_remote" => Dict(:type => "BOOLEAN", :constraints => ""),
            "is_HPC" => Dict(:type => "BOOLEAN", :constraints => ""),
            "runtime_code_hours" => Dict(:type => "NUMERIC", :constraints => ""),
            "data_statement" => Dict(:type => "VARCHAR", :constraints => ""),
            "repl_comments" => Dict(:type => "VARCHAR", :constraints => ""),
            "date_with_authors" => Dict(:type => "DATE", :constraints => ""),
            "date_arrived_from_authors" => Dict(:type => "DATE", :constraints => ""),
            "date_assigned_repl" => Dict(:type => "DATE", :constraints => ""),
            "date_completed_repl" => Dict(:type => "DATE", :constraints => ""),
            "date_decision_de" => Dict(:type => "DATE", :constraints => ""),
            "decision_de" => Dict(:type => "VARCHAR", :constraints => ""),
            "fr_path_apps" => Dict(:type => "VARCHAR", :constraints => ""),
            "fr_path_full" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_path" => Dict(:type => "VARCHAR", :constraints => ""),
            "repl_package_path" => Dict(:type => "VARCHAR", :constraints => ""),
            "paper_path" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_path_full" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_id_pkg" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_id_paper" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_url_pkg" => Dict(:type => "VARCHAR", :constraints => ""),
            "file_request_url_paper" => Dict(:type => "VARCHAR", :constraints => ""),
            "github_url" => Dict(:type => "VARCHAR", :constraints => ""),
            "gh_org_repo" => Dict(:type => "VARCHAR", :constraints => ""),
            "_primary_key" => Dict(:columns => ["paper_id", "round"])
        ),
        "reports" => Dict(
            "paper_id" => Dict(:type => "VARCHAR", :constraints => ""),
            "round" => Dict(:type => "INTEGER", :constraints => ""),
            "journal" => Dict(:type => "VARCHAR", :constraints => ""),
            "date_completed_repl" => Dict(:type => "DATE", :constraints => ""),
            "replicator1" => Dict(:type => "VARCHAR", :constraints => ""),
            "replicator2" => Dict(:type => "VARCHAR", :constraints => ""),
            "hours1" => Dict(:type => "NUMERIC", :constraints => ""),
            "hours2" => Dict(:type => "NUMERIC", :constraints => ""),
            "is_success" => Dict(:type => "BOOLEAN", :constraints => ""),
            "software" => Dict(:type => "VARCHAR", :constraints => ""),
            "is_confidential" => Dict(:type => "BOOLEAN", :constraints => ""),
            "is_confidential_shared" => Dict(:type => "BOOLEAN", :constraints => ""),
            "is_remote" => Dict(:type => "BOOLEAN", :constraints => ""),
            "is_HPC" => Dict(:type => "BOOLEAN", :constraints => ""),
            "runtime_code_hours" => Dict(:type => "NUMERIC", :constraints => ""),
            "data_statement" => Dict(:type => "VARCHAR", :constraints => ""),
            "quality" => Dict(:type => "INTEGER", :constraints => ""),
            "complexity" => Dict(:type => "INTEGER", :constraints => ""),
            "repl_comments" => Dict(:type => "VARCHAR", :constraints => ""),
            "comments" => Dict(:type => "VARCHAR", :constraints => ""),
            "_primary_key" => Dict(:columns => ["paper_id", "round"])
        )
    )
    
    if haskey(schemas, table)
        return schemas[table]
    else
        error("Schema for table '$table' not defined")
    end
end

"""
    db_ensure_table_exists(table::String; verbose::Bool=true)

Ensure that a table exists in the database. If it doesn't exist, create it
based on its schema definition.

# Arguments
- `table::String`: The name of the table to ensure exists
- `verbose::Bool`: Whether to print status messages (default: true)

# Returns
- `Bool`: Whether the table was created (true) or already existed (false)
"""
function db_ensure_table_exists(table::String; verbose::Bool=true)
    if db_table_exists(table)
        verbose && println("Table '$table' already exists")
        return false
    end
    
    verbose && println("Creating table '$table'...")
    
    # Get the schema for this table
    schema = db_get_table_schema(table)
    
    # Build the CREATE TABLE statement
    columns = String[]
    for (col_name, col_props) in schema
        # Skip the special _primary_key entry
        col_name == "_primary_key" && continue
        
        push!(columns, "$col_name $(col_props[:type]) $(col_props[:constraints])")
    end
    
    # Add primary key constraint if specified
    if haskey(schema, "_primary_key")
        pk_cols = join(schema["_primary_key"][:columns], ", ")
        push!(columns, "PRIMARY KEY ($pk_cols)")
    end
    
    # Create the table
    create_stmt = "CREATE TABLE IF NOT EXISTS $table (\n    " * join(columns, ",\n    ") * "\n)"
    
    with_db() do con
        DBInterface.execute(con, create_stmt)
    end
    
    verbose && println("✓ Table '$table' created")
    return true
end

"""
    db_add_missing_columns(table::String; verbose::Bool=true)

Add any missing columns to an existing table based on its schema definition.

# Arguments
- `table::String`: The name of the table to add missing columns to
- `verbose::Bool`: Whether to print status messages (default: true)

# Returns
- `Vector{String}`: Names of columns that were added
"""
function db_add_missing_columns(table::String; verbose::Bool=true)
    if !db_table_exists(table)
        error("Table '$table' does not exist")
    end
    
    # Get the schema for this table
    schema = db_get_table_schema(table)
    
    # Get the current columns in the table
    current_columns = with_db() do con
        df = DataFrame(DBInterface.execute(con, "PRAGMA table_info($table)"))
        df.name
    end
    
    # Find missing columns
    missing_columns = String[]
    for (col_name, col_props) in schema
        # Skip the special _primary_key entry and columns that already exist
        if col_name != "_primary_key" && !(col_name in current_columns)
            push!(missing_columns, col_name)
        end
    end
    
    # Add missing columns
    for col_name in missing_columns
        col_props = schema[col_name]
        alter_stmt = "ALTER TABLE $table ADD COLUMN $col_name $(col_props[:type]) $(col_props[:constraints])"
        
        with_db() do con
            DBInterface.execute(con, alter_stmt)
        end
        
        verbose && println("✓ Added column '$col_name' to table '$table'")
    end
    
    if isempty(missing_columns)
        verbose && println("No missing columns to add to table '$table'")
    end
    
    return missing_columns
end



function db_show()
    d = with_db() do con
        DBInterface.execute(con,"SELECT * FROM duckdb_tables()") |> DataFrame
    end
    select(d, :database_name, :table_name,:temporary, :estimated_size, :column_count)
end

function db_describe(table::String)
    with_db() do con
        DBInterface.execute(con,"DESCRIBE $table")
    end
end

function db_drop_col(table::String,col::String)
    with_db() do con
        DBInterface.execute(con,"ALTER TABLE $table DROP COLUMN $col")
    end
end

function db_drop(table)
    @warn "this will delete table $table. You sure?"
    choice = ask(DefaultPrompt(["y", "no"], 1, "Are you sure?"))
    if choice == "y"
        with_db() do con
            DuckDB.drop!(con, "$table")
        end
        
        println("Table $table dropped")
    else
        println("Table $table not dropped")
    end
end

function db_get_columns(table::String, cols::Vector{String})
    # Compose the column list as a comma-separated string
    col_str = join(cols, ", ")
    query = "SELECT $col_str FROM $table"
    with_db() do con
        DBInterface.execute(con, query) |> DataFrame
    end
end

function db_get_columns(table::String, cols::Vector{String}, where_col::String, where_val)
    col_str = join(cols, ", ")
    query = "SELECT $col_str FROM $table WHERE $where_col = ?"
    with_db() do con
        stmt = DBInterface.prepare(con, query)
        DBInterface.execute(stmt, (where_val,)) |> DataFrame
    end
end

function db_types()
    DataFrame(
        string = ["INTEGER","VARCHAR","DATE","BOOLEAN","NUMERIC"],
        dtype = [Int,String,Date,Bool,Float64])
end

function db_empty_df(table::String)
    d = DataFrame(
        DBInterface.execute(con, 
            "PRAGMA table_info($table)"
        )
    )
    d = innerjoin(d,db_types(), on = :type => :string)

    # create an empty dataframe of column types in d.type, with 
    # colnames in d.name
    DataFrame([T[] for T in d.dtype], d.name)
end

function db_delete_where(table::String, where_col::String, where_val)
    with_db() do con
        query = "DELETE FROM $table WHERE $where_col = ?"
        stmt = DBInterface.prepare(con, query)
        DBInterface.execute(con, "BEGIN TRANSACTION")
        DBInterface.execute(stmt, (where_val,))
        DBInterface.execute(con, "COMMIT")  # Explicit commit
    end
    @info "Deleted rows from $table where $where_col = $where_val"
end

function db_delete_where(table::String, where_cols::Vector{String}, where_vals)
    where_clause = join([col * " = ?" for col in where_cols], " AND ")
    query = "DELETE FROM $table WHERE $where_clause"
    
    with_db() do con
        stmt = DBInterface.prepare(con, query)
        DBInterface.execute(con, "BEGIN TRANSACTION")
        DBInterface.execute(stmt, where_vals)
        DBInterface.execute(con, "COMMIT") # Explicit commit
    end
    @info "Deleted rows from $table where $(join(where_cols .* " = " .* string.(where_vals), " AND "))"
end

"""
    db_delete_test()

Safely delete all test entries (rows with "[TEST]" in the comments column) from the database.
This function creates backups before deletion, uses transactions for atomicity,
and validates the database state after deletion.

Returns a DataFrame with information about the deletion operation.
"""
function db_delete_test()
    # Create a result DataFrame to track operations
    results = DataFrame(
        operation = String[],
        target = String[],
        status = String[],
        details = String[]
    )
    
    # Step 1: Create backups of affected tables
    try
        papers_df = db_df("papers")
        push!(results, ("backup", "papers", "success", "$(nrow(papers_df)) rows backed up"))
        db_write_backup("papers_pre_delete", papers_df)
        
        form_arrivals_df = db_df("form_arrivals")
        push!(results, ("backup", "form_arrivals", "success", "$(nrow(form_arrivals_df)) rows backed up"))
        db_write_backup("form_arrivals_pre_delete", form_arrivals_df)

        iterations_df = db_df("iterations")
        push!(results, ("backup", "iterations", "success", "$(nrow(iterations_df)) rows backed up"))
        db_write_backup("iterations_pre_delete", iterations_df)
        
        reports_df = db_df("reports")
        push!(results, ("backup", "reports", "success", "$(nrow(reports_df)) rows backed up"))
        db_write_backup("reports_pre_delete", reports_df)
    catch backup_err
        push!(results, ("backup", "tables", "error", "Failed to create backups: $backup_err"))
        return results  # Return early if backups fail
    end
    
    # Step 2: Get test repos to delete
    test_repos = DataFrame()
    try
        test_repos = db_get_columns("papers", ["github_url"], "comments", "[TEST]")
        push!(results, ("query", "test_repos", "success", "Found $(nrow(test_repos)) test repos"))
    catch query_err
        push!(results, ("query", "test_repos", "error", "Failed to query test repos: $query_err"))
        # Continue even if this fails
    end
    
    # Step 3: Delete GitHub repos
    for r in eachrow(test_repos)
        try
            if !ismissing(r.github_url) && !isempty(r.github_url)
                gh_delete_repo(r.github_url)
                push!(results, ("delete", "github_repo", "success", "Deleted $(r.github_url)"))
            end
        catch gh_err
            push!(results, ("delete", "github_repo", "error", "Failed to delete $(r.github_url): $gh_err"))
            # Continue with other repos even if one fails
        end
    end
    
    # Step 4: Delete database entries using transactions
    try
        # Delete from form_arrivals
        robust_db_operation() do con
            # First count how many rows will be affected
            count_query = "SELECT COUNT(*) as count FROM form_arrivals WHERE comments = ?"
            stmt = DBInterface.prepare(con, count_query)
            count_result = DataFrame(DBInterface.execute(stmt, ("[TEST]",)))
            count = count_result.count[1]
            
            # Then delete
            delete_query = "DELETE FROM form_arrivals WHERE comments = ?"
            stmt = DBInterface.prepare(con, delete_query)
            DBInterface.execute(stmt, ("[TEST]",))
            
            push!(results, ("delete", "form_arrivals", "success", "Deleted $count rows"))
        end
    catch form_err
        push!(results, ("delete", "form_arrivals", "error", "Failed to delete from form_arrivals: $form_err"))
    end
    
    try
        # Delete from papers
        robust_db_operation() do con
            # First count how many rows will be affected
            count_query = "SELECT COUNT(*) as count FROM papers WHERE comments = ?"
            stmt = DBInterface.prepare(con, count_query)
            count_result = DataFrame(DBInterface.execute(stmt, ("[TEST]",)))
            count = count_result.count[1]
            
            # Then delete
            delete_query = "DELETE FROM papers WHERE comments = ?"
            stmt = DBInterface.prepare(con, delete_query)
            DBInterface.execute(stmt, ("[TEST]",))
            
            push!(results, ("delete", "papers", "success", "Deleted $count rows"))
        end
    catch papers_err
        push!(results, ("delete", "papers", "error", "Failed to delete from papers: $papers_err"))
    end
    
    try
        # Delete from iterations
        robust_db_operation() do con
            # First count how many rows will be affected
            count_query = "SELECT COUNT(*) as count FROM iterations WHERE comments = ?"
            stmt = DBInterface.prepare(con, count_query)
            count_result = DataFrame(DBInterface.execute(stmt, ("[TEST]",)))
            count = count_result.count[1]
            
            # Then delete
            delete_query = "DELETE FROM iterations WHERE comments = ?"
            stmt = DBInterface.prepare(con, delete_query)
            DBInterface.execute(stmt, ("[TEST]",))
            
            push!(results, ("delete", "iterations", "success", "Deleted $count rows"))
        end
    catch iterations_err
        push!(results, ("delete", "iterations", "error", "Failed to delete from iterations: $iterations_err"))
    end
    
    try
        # Delete from reports
        robust_db_operation() do con
            # First count how many rows will be affected
            count_query = "SELECT COUNT(*) as count FROM reports WHERE comments = ?"
            stmt = DBInterface.prepare(con, count_query)
            count_result = DataFrame(DBInterface.execute(stmt, ("[TEST]",)))
            count = count_result.count[1]
            
            # Then delete
            delete_query = "DELETE FROM reports WHERE comments = ?"
            stmt = DBInterface.prepare(con, delete_query)
            DBInterface.execute(stmt, ("[TEST]",))
            
            push!(results, ("delete", "reports", "success", "Deleted $count rows"))
        end
    catch reports_err
        push!(results, ("delete", "reports", "error", "Failed to delete from reports: $reports_err"))
    end
    
    # Step 5: Validate database state after deletion
    try
        # Check if tables still exist and are in a valid state
        papers_exists = db_table_exists("papers")
        form_exists = db_table_exists("form_arrivals")
        iterations_exists = db_table_exists("iterations")
        reports_exists = db_table_exists("reports")
        
        if papers_exists && form_exists && iterations_exists && reports_exists
            push!(results, ("validate", "tables", "success", "Tables exist after deletion"))
            
            # Check if we can still query the tables
            papers_count = nrow(db_df("papers"))
            form_count = nrow(db_df("form_arrivals"))
            iterations_count = nrow(db_df("iterations"))
            reports_count = nrow(db_df("reports"))
            push!(results, ("validate", "query", "success", 
                "papers: $papers_count rows, form_arrivals: $form_count rows, " *
                "iterations: $iterations_count rows, reports: $reports_count rows"))
        else
            push!(results, ("validate", "tables", "error", 
                "Tables missing after deletion: papers=$papers_exists, form_arrivals=$form_exists, " *
                "iterations=$iterations_exists, reports=$reports_exists"))
        end
    catch validate_err
        push!(results, ("validate", "database", "error", "Validation failed: $validate_err"))
    end
    
    return results
end


"""
    test_db_delete_test()

Test the improved db_delete_test() function to ensure it safely deletes test entries
and maintains database integrity.

This function:
1. Creates test entries in the database
2. Calls db_delete_test() to delete them
3. Verifies the database remains in a consistent state
"""
function test_db_delete_test()
    println("Testing improved db_delete_test() function...")
    
    # Step 1: Create some test entries if they don't exist
    try
        # Ensure all required tables exist
        db_ensure_table_exists("papers")
        db_ensure_table_exists("form_arrivals")
        db_ensure_table_exists("iterations")
        db_ensure_table_exists("reports")
        
        # Add any missing columns to the tables
        db_add_missing_columns("papers")
        db_add_missing_columns("form_arrivals")
        db_add_missing_columns("iterations")
        db_add_missing_columns("reports")
        
        # Insert test data
        println("Inserting test data...")
        with_db() do con
            # Insert test data into papers
            DBInterface.execute(con, """
            INSERT INTO papers (paper_id, journal, firstname_of_author, surname_of_author, github_url, comments)
            VALUES ('12345', 'JPE', 'Test', 'Author', 'https://github.com/test/repo', '[TEST]')
            """)
            
            # Insert test data into form_arrivals
            DBInterface.execute(con, """
            INSERT INTO form_arrivals (paper_id, journal, comments)
            VALUES ('12345', 'JPE', '[TEST]')
            """)
            
            # Insert test data into iterations
            DBInterface.execute(con, """
            INSERT INTO iterations (paper_id, round, journal, replicator1, comments)
            VALUES (12345, 1, 'JPE', 'Test Replicator', '[TEST]')
            """)
            
            # Insert test data into reports
            DBInterface.execute(con, """
            INSERT INTO reports (paper_id, round, journal, replicator1, comments)
            VALUES (12345, 1, 'JPE', 'Test Replicator', '[TEST]')
            """)
        end
        
        # Step 2: Run the delete test function
        println("\nRunning db_delete_test()...")
        results = db_delete_test()
        
        # Step 3: Display results
        println("\nResults of db_delete_test():")
        for r in eachrow(results)
            println("$(r.operation) | $(r.target) | $(r.status) | $(r.details)")
        end
        
        # Step 4: Verify database state
        println("\nVerifying database state after deletion...")
        
        # Check if tables still exist
        papers_exists = db_table_exists("papers")
        form_exists = db_table_exists("form_arrivals")
        
        println("Tables exist: papers=$papers_exists, form_arrivals=$form_exists")
        
        if papers_exists && form_exists
            # Check if test data was deleted
            test_papers = with_db() do con
                DataFrame(DBInterface.execute(con, "SELECT COUNT(*) as count FROM papers WHERE comments = '[TEST]'"))
            end
            
            test_arrivals = with_db() do con
                DataFrame(DBInterface.execute(con, "SELECT COUNT(*) as count FROM form_arrivals WHERE comments = '[TEST]'"))
            end
            
            test_iterations = with_db() do con
                DataFrame(DBInterface.execute(con, "SELECT COUNT(*) as count FROM iterations WHERE comments = '[TEST]'"))
            end
            
            test_reports = with_db() do con
                DataFrame(DBInterface.execute(con, "SELECT COUNT(*) as count FROM reports WHERE comments = '[TEST]'"))
            end
            
            println("Remaining test entries: papers=$(test_papers.count[1]), form_arrivals=$(test_arrivals.count[1]), " *
                   "iterations=$(test_iterations.count[1]), reports=$(test_reports.count[1])")
            
            if test_papers.count[1] == 0 && test_arrivals.count[1] == 0 && 
               test_iterations.count[1] == 0 && test_reports.count[1] == 0
                println("✓ All test entries successfully deleted")
            else
                println("⚠️ Some test entries remain")
            end
        else
            println("⚠️ One or more tables missing after deletion")
        end
        
        println("\nTest completed.")
    catch e
        println("Error during test: $e")
    end
end


# function db_create()
#     DBInterface.execute(con, """
#         CREATE TABLE IF NOT EXISTS papers (
#             paper_id INTEGER PRIMARY KEY,
#             round INTEGER,
#             status VARCHAR,
#             journal VARCHAR,
#             firstname_of_author VARCHAR,
#             surname_of_author VARCHAR,
#             email_of_author VARCHAR,
#             email_of_second_author VARCHAR,
#             handling_editor VARCHAR,
#             first_arrival_date DATE,
#             title VARCHAR,
#             date_with_authors DATE,
#             is_remote BOOLEAN,
#             is_HPC BOOLEAN,
#             data_statement VARCHAR,
#             github_url VARCHAR,
#             dataverse_doi VARCHAR,
#             dataverse_label VARCHAR,
#             is_confidential BOOLEAN,
#             file_request_id  VARCHAR,
#             software VARCHAR,
#             comments VARCHAR
#         )
#         """)
#     DBInterface.execute(con, """
#         CREATE TABLE IF NOT EXISTS iterations (
#             paper_id INTEGER,
#             round INTEGER,
#             journal VARCHAR,
#             replicator1 VARCHAR,
#             replicator2 VARCHAR,
#             hours1 NUMERIC,
#             hours2 NUMERIC,
#             is_success BOOLEAN,
#             software VARCHAR,
#             is_confidential BOOLEAN,
#             is_confidential_shared BOOLEAN,
#             is_remote  BOOLEAN,
#             is_HPC BOOLEAN,
#             runtime_code_hours NUMERIC,
#             data_statement VARCHAR,
#             quality INTEGER,
#             complexity INTEGER,
#             repl_comments VARCHAR,
#             date_with_authors         DATE,
#             date_arrived_from_authors DATE,
#             date_assigned_repl        DATE,
#             date_completed_repl       DATE,
#             date_decision_de          DATE,
#             file_request_id           VARCHAR,
#             decision_de               VARCHAR,
#             PRIMARY KEY (paper_id, round)
#             );
#         """)
#     DBInterface.execute(con, """
#         CREATE TABLE IF NOT EXISTS reports (
#             paper_id INTEGER,
#             round INTEGER,
#             journal VARCHAR,
#             date_completed_repl DATE,
#             replicator1 VARCHAR,
#             replicator2 VARCHAR,
#             hours1 NUMERIC,
#             hours2 NUMERIC,
#             is_success BOOLEAN,
#             software VARCHAR,
#             is_confidential BOOLEAN,
#             is_confidential_shared BOOLEAN,
#             is_remote  BOOLEAN,
#             is_HPC BOOLEAN,
#             runtime_code_hours NUMERIC,
#             data_statement VARCHAR,
#             quality INTEGER,
#             complexity INTEGER,
#             repl_comments VARCHAR,
#             PRIMARY KEY (paper_id, round)
#         );
#         """)
# end



"""
get a connection to local db and load the gsheets extension
"""
function getcon()
    # con is a global
    DBInterface.execute(con, "load gsheets")
    DBInterface.execute(con, """
        CREATE SECRET (
        TYPE gsheet, 
        PROVIDER key_file, 
        FILEPATH '$(ENV["JPE_GOOGLE_KEY"])'
        );
        """)
    return nothing
end

"""
    check_db_integrity()

Perform integrity checks on the database to detect potential corruption issues.
This function checks for:
1. Missing tables
2. Inconsistent data between tables
3. Orphaned records

Returns a DataFrame with any issues found, or an empty DataFrame if no issues are detected.
"""
function check_db_integrity()
    issues = DataFrame(
        table = String[],
        issue_type = String[],
        description = String[],
        severity = String[]
    )
    
    # Check if essential tables exist
    essential_tables = ["papers", "form_arrivals", "iterations", "reports"]
    for table in essential_tables
        if !db_table_exists(table)
            push!(issues, (
                table, 
                "missing_table", 
                "Table $table does not exist", 
                "critical"
            ))
        end
    end
    
    # If critical tables are missing, return early
    if nrow(issues) > 0 && any(issues.severity .== "critical")
        return issues
    end
    
    # Check for data consistency between papers and form_arrivals
    try
        papers = db_df("papers")
        arrivals = db_df("form_arrivals")
        
        # Check for papers that exist in form_arrivals but not in papers
        if "paper_id" in names(papers) && "paper_id" in names(arrivals)
            paper_ids_in_papers = Set(papers.paper_id)
            paper_ids_in_arrivals = Set(arrivals.paper_id)
            
            missing_in_papers = setdiff(paper_ids_in_arrivals, paper_ids_in_papers)
            if !isempty(missing_in_papers)
                push!(issues, (
                    "papers", 
                    "missing_records", 
                    "$(length(missing_in_papers)) paper_ids exist in form_arrivals but not in papers", 
                    "high"
                ))
            end
        end
    catch e
        push!(issues, (
            "multiple", 
            "query_error", 
            "Error checking data consistency: $e", 
            "medium"
        ))
    end
    
    # Check for orphaned records in other tables
    # Add more checks as needed
    
    return issues
end

"""
    repair_db_from_backups()

Attempt to repair database issues by using the CSV backups.
This function should be used when database corruption is detected.

Returns a DataFrame with the repair actions taken.
"""
function repair_db_from_backups()
    repairs = DataFrame(
        table = String[],
        action = String[],
        result = String[]
    )
    
    # Check if backups exist
    backup_tables = ["papers", "form_arrivals", "iterations", "reports"]
    for table in backup_tables
        backup_path = joinpath(DB_JPE, "$table.csv")
        if isfile(backup_path)
            try
                # Read the backup
                backup_df = db_read_backup(table)
                
                # Check if table exists in database
                if !db_table_exists(table)
                    # Create the table from backup
                    robust_db_operation() do con
                        DuckDB.register_data_frame(con, backup_df, "backup_df")
                        DBInterface.execute(con, "CREATE OR REPLACE TABLE $table AS SELECT * FROM backup_df")
                    end
                    push!(repairs, (table, "create_from_backup", "success"))
                else
                    # Table exists, check if it has data
                    table_empty = !db_table_exists_and_not_empty(table)
                    if table_empty
                        # Populate empty table from backup
                        robust_db_operation() do con
                            DuckDB.register_data_frame(con, backup_df, "backup_df")
                            DBInterface.execute(con, "INSERT INTO $table SELECT * FROM backup_df")
                        end
                        push!(repairs, (table, "populate_from_backup", "success"))
                    else
                        # Table has data, merge with backup
                        # This is more complex and depends on your specific needs
                        push!(repairs, (table, "merge_not_implemented", "skipped"))
                    end
                end
            catch e
                push!(repairs, (table, "repair_attempt", "failed: $e"))
            end
        else
            push!(repairs, (table, "find_backup", "no backup found at $backup_path"))
        end
    end
    
    return repairs
end


"""
    db_add_unique_constraint(table::String, columns::Union{String, Vector{String}})

Add a UNIQUE constraint to an existing table on one or more columns.

# Arguments
- `table::String`: The name of the table to add the constraint to
- `columns::Union{String, Vector{String}}`: The column(s) to add the unique constraint to.
  Can be a single column name as a String or multiple column names as a Vector{String}.

# Examples
```julia
# Add a unique constraint on a single column
db_add_unique_constraint("papers", "paper_id")

# Add a unique constraint on a composite key
db_add_unique_constraint("iterations", ["paper_id", "round"])
```
"""
function db_add_unique_constraint(table::String, columns::Union{String, Vector{String}})
    # Convert single string to vector for consistent handling
    cols = columns isa String ? [columns] : columns
    
    # Create constraint name based on table and columns
    col_part = join(cols, "_")
    constraint_name = "$(table)_$(col_part)_unique"
    
    # Create column list for SQL statement
    col_list = join(cols, ", ")
    
    with_db() do con
        DBInterface.execute(con, "ALTER TABLE $table ADD CONSTRAINT $constraint_name UNIQUE ($col_list)")
    end
    
    if length(cols) == 1
        println("✓ Added UNIQUE constraint on column $(cols[1]) to table $table")
    else
        println("✓ Added UNIQUE constraint on columns ($(col_list)) to table $table")
    end
end

"""
    db_append_new_row(table::String, key_column::Union{String, Vector{String}}, row::DataFrameRow, df::Union{Nothing, DataFrame}=nothing)

Append a single row to a database table if a row with the same key value doesn't already exist.
This function assumes the table already exists and will error if it doesn't.
It uses direct SQL insertion with parameterized queries for database operations.

# Arguments
- `table::String`: The name of the table to append to
- `key_column::Union{String, Vector{String}}`: The column name(s) to use for identifying unique rows.
  Can be a single column name as a String or multiple column names as a Vector{String}.
- `row::DataFrameRow`: The row to append
- `df::Union{Nothing, DataFrame}=nothing`: Optional original DataFrame (not used for table creation anymore)

# Returns
- The row if it was added
- `nothing` if a row with the same key already exists
"""
function db_append_new_row(table::String, key_column::Union{String, Vector{String}}, row::DataFrameRow)
    # Validate table name to prevent SQL injection
    if !occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", table)
        error("Invalid table name: $table")
    end
    
    # Check if table exists - error if it doesn't
    if !db_table_exists(table)
        error("Table '$table' does not exist. Ensure the table exists before calling db_append_new_row.")
    end
    
    # Table exists, use direct SQL insertion to avoid Union{} type issues
    return robust_db_operation() do con
        # Check if row already exists
        if key_column isa String
            # Single column case
            key_value = row[Symbol(key_column)]
            # Handle missing values in the key
            if ismissing(key_value)
                check_query = "SELECT 1 FROM $table WHERE $key_column IS NULL LIMIT 1"
                check_result = DataFrame(DBInterface.execute(con, check_query))
            else
                check_query = "SELECT 1 FROM $table WHERE $key_column = ? LIMIT 1"
                check_result = DataFrame(DBInterface.execute(DBInterface.prepare(con, check_query), (key_value,)))
            end
            
            if nrow(check_result) > 0
                @info "Row with $key_column = $(ismissing(key_value) ? "NULL" : key_value) already exists in $table"
                return nothing
            end
        else
            # Multiple columns case - build WHERE clause with proper NULL handling
            where_clauses = String[]
            where_values = []
            
            for col in key_column
                col_sym = Symbol(col)
                if ismissing(row[col_sym])
                    push!(where_clauses, "$col IS NULL")
                else
                    push!(where_clauses, "$col = ?")
                    push!(where_values, row[col_sym])
                end
            end
            
            where_str = join(where_clauses, " AND ")
            
            # Check if a row with these keys already exists
            check_query = "SELECT 1 FROM $table WHERE $where_str LIMIT 1"
            check_result = DataFrame(DBInterface.execute(DBInterface.prepare(con, check_query), Tuple(where_values)))
            
            if nrow(check_result) > 0
                key_desc = join(["$col = $(ismissing(row[Symbol(col)]) ? "NULL" : row[Symbol(col)])" for col in key_column], ", ")
                @info "Row with $key_desc already exists in $table"
                return nothing
            end
        end
        
        # Row doesn't exist, insert it using direct SQL
        # Extract column names and values, handling missing values
        columns = String[]
        values = []
        
        for (col, val) in pairs(row)
            push!(columns, string(col))
            push!(values, val)  # DuckDB's parameterized queries handle missing values correctly
        end
        
        # Create the INSERT statement
        columns_str = join(columns, ", ")
        placeholders = join(fill("?", length(columns)), ", ")
        
        insert_query = "INSERT INTO $table ($columns_str) VALUES ($placeholders)"
        stmt = DBInterface.prepare(con, insert_query)
        DBInterface.execute(stmt, Tuple(values))
        
        if key_column isa String
            @info "Appended row with $key_column = $(ismissing(row[Symbol(key_column)]) ? "NULL" : row[Symbol(key_column)]) to $table"
        else
            key_desc = join(["$col = $(ismissing(row[Symbol(col)]) ? "NULL" : row[Symbol(col)])" for col in key_column], ", ")
            @info "Appended row with $key_desc to $table"
        end
        
        return row
    end
end



function db_name(name::AbstractString)
    # Build case-insensitive regex pattern
    pattern = "(?i)^" * name  # ^ for prefix match, (?i) for case-insensitive

    # Prepare SQL query
    query = "SELECT * FROM papers WHERE surname_of_author ~ ?"

    # Run query with parameterized input
    d = with_db() do con
        DBInterface.execute(db, query, (pattern,)) |> DataFrame
    end
    select(d, :paper_id, :surname_of_author, :round, :status)
end
