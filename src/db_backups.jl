
"""
    db_bk_create(; verbose::Bool=true, keep_backups::Int=10)

Create a backup of database and CSV files with timestamp, maintaining only the most recent backups.

# Arguments
- `verbose`: Whether to print backup progress (default: true)
- `keep_backups`: Number of recent backups to keep (default: 10)

# Environment Variables (Required)
- `JPE_DB`: Source directory (e.g., "/Users/floswald/JPE")
- `JPE_DB_BACKUPS`: Backup destination directory (e.g., "/Users/floswald/Dropbox/JPE/database")

# Files backed up
- jpe.duckdb → backup_YYYY-MM-DD_HH-MM-SS.duckdb
- arrivals.csv → backup_YYYY-MM-DD_HH-MM-SS_arrivals.csv  
- papers.csv → backup_YYYY-MM-DD_HH-MM-SS_papers.csv

# Example
```julia
db_bk_create()
```
"""
function db_bk_create(; verbose::Bool=true, keep_backups::Int=10)
    # Get directories from environment variables
    source_dir = get(ENV, "JPE_DB", nothing)
    dest_dir = get(ENV, "JPE_DB_BACKUPS", nothing)
    
    # Validate that we have both directories
    if source_dir === nothing
        error("JPE_DB environment variable not set. Please set it to your source directory.")
    end
    if dest_dir === nothing
        error("JPE_DB_BACKUPS environment variable not set. Please set it to your backup directory.")
    end

    # Assumes you have a global connection variable (adjust the variable name as needed)
    try
        with_db() do conn
            DuckDB.execute(conn, "CHECKPOINT;")  # Use your existing connection
        end
        verbose && println("Forced DuckDB checkpoint before backup")
    catch e
        @warn "Failed to checkpoint DuckDB before backup: $e"
    end
    
    verbose && println("Source: $source_dir")
    verbose && println("Destination: $dest_dir")
    
    # Generate timestamp
    timestamp = Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")
    
    # Ensure destination directory exists
    if !isdir(dest_dir)
        mkpath(dest_dir)
        verbose && println("Created destination directory: $dest_dir")
    end
    
    # Files to backup with their destination patterns
    files_to_backup = [
        ("jpe.duckdb", "backup_$(timestamp).duckdb"),
        ("arrivals.csv", "backup_$(timestamp)_arrivals.csv"),
        ("papers.csv", "backup_$(timestamp)_papers.csv"),
        # Uncomment these if you want to backup reports and iterations
        ("reports.csv", "backup_$(timestamp)_reports.csv"),
        ("iterations.csv", "backup_$(timestamp)_iterations.csv")
    ]
    
    copied_files = String[]
    
    # Copy each file
    for (source_file, dest_file) in files_to_backup
        source_path = joinpath(source_dir, source_file)
        dest_path = joinpath(dest_dir, dest_file)
        
        if isfile(source_path)
            try
                cp(source_path, dest_path)
                push!(copied_files, dest_file)
                verbose && println("'$source_path' -> '$dest_path'")
            catch e
                @warn "Failed to copy $source_file: $e"
            end
        else
            verbose && @warn "Source file not found: $source_path"
        end
    end
    
    # Clean up old backups (keep only the most recent ones)
    db_bk_clean(keep_backups, verbose)
    
    verbose && println("Backup completed. $(length(copied_files)) files backed up.")
    
    return copied_files
end

"""
    db_bk_clean(keep_count::Int, verbose::Bool=true)

Remove old backup files, keeping only the most recent ones.
Uses JPE_DB_BACKUPS environment variable for backup directory.
"""
function db_bk_clean(keep_count::Int, verbose::Bool=true)
    dest_dir = get(ENV, "JPE_DB_BACKUPS", nothing)
    if dest_dir === nothing
        error("JPE_DB_BACKUPS environment variable not set.")
    end
    # Find all .duckdb backup files (use these as reference for cleanup)
    duckdb_pattern = r"^backup_.*\.duckdb$"
    duckdb_files = filter(f -> match(duckdb_pattern, f) !== nothing, readdir(dest_dir))
    
    if length(duckdb_files) <= keep_count
        return  # Nothing to clean up
    end
    
    # Sort by modification time (newest first)
    full_paths = [joinpath(dest_dir, f) for f in duckdb_files]
    sort!(full_paths, by=f -> stat(f).mtime, rev=true)
    
    # Files to delete (everything beyond keep_count)
    files_to_delete = full_paths[(keep_count+1):end]
    
    for old_backup in files_to_delete
        try
            # Extract timestamp from the duckdb file to find related CSV files
            filename = basename(old_backup)
            if match(r"^backup_(.+)\.duckdb$", filename) !== nothing
                timestamp_match = match(r"^backup_(.+)\.duckdb$", filename)
                if timestamp_match !== nothing
                    timestamp = timestamp_match.captures[1]
                    
                    # Delete related files with same timestamp
                    related_patterns = [
                        "backup_$(timestamp).duckdb",
                        "backup_$(timestamp)_arrivals.csv",
                        "backup_$(timestamp)_papers.csv",
                        "backup_$(timestamp)_reports.csv",
                        "backup_$(timestamp)_iterations.csv"
                    ]
                    
                    for pattern in related_patterns
                        file_path = joinpath(dest_dir, pattern)
                        if isfile(file_path)
                            rm(file_path)
                            verbose && println("Removed old backup: $file_path")
                        end
                    end
                end
            end
        catch e
            @warn "Failed to delete old backup $old_backup: $e"
        end
    end
end

"""
    db_bk_get_most_recent(file_type::String="duckdb")

Get the path to the most recent backup file of the specified type.
Uses JPE_DB_BACKUPS environment variable for backup directory.

# Arguments
- `file_type`: File type to look for ("duckdb", "arrivals.csv", "papers.csv", etc.)

# Returns
- String path to the most recent backup file, or `nothing` if no backups found
"""
function db_bk_get_most_recent(file_type::String="duckdb")
    backup_dir = get(ENV, "JPE_DB_BACKUPS", nothing)
    if backup_dir === nothing
        error("JPE_DB_BACKUPS environment variable not set.")
    end
    
    if !isdir(backup_dir)
        @warn "Backup directory does not exist: $backup_dir"
        return nothing
    end
    
    pattern = if file_type == "duckdb"
        r"^backup_.*\.duckdb$"
    elseif endswith(file_type, ".csv")
        csv_type = replace(file_type, ".csv" => "")
        Regex("^backup_.*_$(csv_type)\\.csv\$")
    else
        Regex("^backup_.*\\.$(file_type)\$")
    end
    
    matching_files = filter(f -> match(pattern, f) !== nothing, readdir(backup_dir))
    
    if isempty(matching_files)
        @warn "No backup files found for type: $file_type"
        return nothing
    end
    
    # Sort by modification time, most recent first
    full_paths = [joinpath(backup_dir, f) for f in matching_files]
    sort!(full_paths, by=f -> stat(f).mtime, rev=true)
    
    return full_paths[1]
end

"""
    db_bk_get_all()

Get paths to the most recent backup files for all types.
Uses JPE_DB_BACKUPS environment variable for backup directory.

# Returns
- NamedTuple with fields: `duckdb`, `arrivals`, `papers`
"""
function db_bk_get_all()
    return (
        duckdb = db_bk_get_most_recent("duckdb"),
        arrivals = db_bk_get_most_recent("arrivals.csv"), 
        papers = db_bk_get_most_recent("papers.csv")
    )
end

function check_database_status()
    local_db = joinpath(get(ENV, "JPE_DB", ""), "jpe.duckdb")
    backup_db = db_bk_get_most_recent("duckdb")
    
    println("Database Status:")
    println("=" ^ 50)
    
    if !isfile(local_db)
        println("❌ Local database not found: $local_db")
    else
        local_info = db_bk_last_modified(local_db)
        local_readable = db_bk_last_modified_readable(local_db)
        println("📁 Local:  $local_readable")
    end
    
    if backup_db === nothing
        println("❌ No backup database found")
    else
        backup_time = stat(backup_db).mtime
        backup_date = unix2datetime(backup_time)
        println("☁️  Backup: $(Dates.format(backup_date, "yyyy-mm-dd HH:MM:SS")) (file)")
    end
    
    # For comparison, use the comparison_timestamp
    if isfile(local_db) && backup_db !== nothing
        local_info = db_bk_last_modified(local_db)
        local_time = local_info.comparison_timestamp
        backup_time = stat(backup_db).mtime
        
        if local_time > backup_time
            age_diff = local_time - backup_time
            hours = round(age_diff / 3600, digits=1)
            println("✅ Local database is newer (by $(hours) hours)")
        elseif backup_time > local_time
            age_diff = backup_time - local_time
            hours = round(age_diff / 3600, digits=1)
            println("⚠️  Backup database is newer (by $(hours) hours)")
            println("   Consider fetching the latest backup!")
        else
            println("✅ Databases are in sync")
        end
    end
    
    println("=" ^ 50)
end


"""
    db_bk_last_modified(db_path::String)

Get the actual last data modification time by checking timestamps across all tables.
Returns a NamedTuple with the most recent Date and DateTime found, plus a combined Unix timestamp.
"""
function db_bk_last_modified(db_path::String)
    if !isfile(db_path)
        return nothing
    end
    
    latest_date = nothing
    latest_datetime = nothing
    
    try
        # DateTime tables
        datetime_tables = [
            ("form_arrivals", "timestamp"),
            ("reports", "timestamp")
        ]
        
        for (table_name, time_col) in datetime_tables
            try
                df = db_df(table_name)
                
                if nrow(df) > 0 && time_col in names(df)
                    max_time = maximum(skipmissing(df[!, time_col]))
                    
                    if latest_datetime === nothing || max_time > latest_datetime
                        latest_datetime = max_time
                    end
                end
                
            catch e
                @warn "Could not check table $table_name: $e"
            end
        end
        
        # Date tables  
        date_tables = [
            ("iterations", "date_with_authors"),
            ("papers", "date_with_authors")
        ]
        
        for (table_name, time_col) in date_tables
            try
                df = db_df(table_name)
                
                if nrow(df) > 0 && time_col in names(df)
                    max_time = maximum(skipmissing(df[!, time_col]))
                    
                    if latest_date === nothing || max_time > latest_date
                        latest_date = max_time
                    end
                end
                
            catch e
                @warn "Could not check table $table_name: $e"
            end
        end
        
        # Determine the "best" timestamp for comparison purposes
        # Priority: DateTime if available, otherwise Date at start of day
        if latest_datetime !== nothing
            comparison_timestamp = datetime2unix(latest_datetime)
        elseif latest_date !== nothing
            comparison_timestamp = datetime2unix(DateTime(latest_date))
        else
            # Fallback to file modification time
            @warn "No data timestamps found, using file mtime for $db_path"
            comparison_timestamp = stat(db_path).mtime
        end
        
        return (
            latest_date = latest_date,
            latest_datetime = latest_datetime, 
            comparison_timestamp = comparison_timestamp
        )
        
    catch e
        @warn "Error checking database tables: $e"
        return (
            latest_date = nothing,
            latest_datetime = nothing,
            comparison_timestamp = stat(db_path).mtime
        )
    end
end

"""
    db_bk_last_modified_readable(db_path::String)

Get a human-readable string showing the most recent data modification.
"""
function db_bk_last_modified_readable(db_path::String)
    result = db_bk_last_modified(db_path)
    if result === nothing
        return "File not found"
    end
    
    parts = String[]
    
    if result.latest_datetime !== nothing
        push!(parts, "DateTime: $(Dates.format(result.latest_datetime, "yyyy-mm-dd HH:MM:SS"))")
    end
    
    if result.latest_date !== nothing
        push!(parts, "Date: $(Dates.format(result.latest_date, "yyyy-mm-dd"))")
    end
    
    if isempty(parts)
        dt = unix2datetime(result.comparison_timestamp)
        return "File: $(Dates.format(dt, "yyyy-mm-dd HH:MM:SS"))"
    end
    
    return join(parts, ", ")
end

function db_bk_fetch_latest()
    mr = db_bk_get_most_recent()
    println("overwriting local database file with : $mr")
    println("y or n?")
    response = readline()
    if lowercase(strip(response)) == "y"
        cp(mr,joinpath(ENV["JPE_DB"],"jpe.duckdb"),force = true)
        @info "copied $mr to $(joinpath(ENV["JPE_DB"],"jpe.duckdb"))"
        println()
        check_database_status()
    end

end