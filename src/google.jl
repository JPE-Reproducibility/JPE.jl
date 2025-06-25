# # use R googlesheets4 to work with google sheets

function gs4_auth()

    path = ENV["JPE_GOOGLE_KEY"]
    R"""
    googlesheets4::gs4_auth(email = "jpe.dataeditor@gmail.com")
    """
end

function gs4_browse()
    R"""
    d = googlesheets4::gs4_browse($(gs_arrivals_id()))
    """
end

function gs4_arrivals()
    R"""
    d = googlesheets4::read_sheet($(gs_arrivals_id()), sheet = 'new-arrivals' )
    """
    @rget d
    
end

function gs4_reports()
    R"""
    d = googlesheets4::read_sheet($(gs_reports_id()), sheet = 'reports' )
    """
    @rget d
    
end

function gs4_append_arrivals(d)
    R"""
    googlesheets4::sheet_append($(gs_arrivals_id()), data = d, sheet = 'recorded' )
    """
end

function gs4_mark_processed(d)



    R"""
    googlesheets4::range_delete($(gs_arrivals_id()), sheet = 'new-arrivals', range = "2:100" )
    """
end

function gs4_update_replicators()
    d = rcopy(R"""
    googlesheets4::read_sheet($(gs_replicators_id()), sheet = 'confirmed')
    """)
    replicators[] = d
    d
end

function available_replicators(; update = false)
    d = if update
        gs4_update_replicators()
    else
        replicators
    end
    @chain d begin
        subset("can take +1 package" => ByRow(==("Yes")), skipmissing = true)
        select(:email,"Number of current packages")
    end
end
ar(; update = false) = available_replicators(; update = update)





# avoid https://duckdb-gsheets.com



function activate(; user = "jpe")
    if user == "jpe"
        haskey(ENV, "JPE_GOOGLE_KEY") || error("No JPE_GOOGLE_KEY found in ENV")
        key = ENV["JPE_GOOGLE_KEY"]
    else 
        error("User not recognized")
    end 
    run(`gcloud auth activate-service-account --key-file $(ENV["JPE_GOOGLE_KEY"])`)
end


function printwalkdir(path)
    for (root,dirs,files) in walkdir(path)
        for dir in dirs
            println("Directories in $root")
            println(joinpath(root,dir))
        end
        println("Files in $root")
        for file in files
            println(joinpath(root, file)) # path to files
        end
    end  
end


gs_replicators_id() = "1QtmmBMEhq5BcoJqMy-FeVrbcsseI7rA_NEjXH94UtV0"
gs_arrivals_id() = "1tmOuid7s7fMhj7oAG_YNHAjRd7bmr7YDM5QKLF6LXys"
gs_arrivals_url() = "https://docs.google.com/spreadsheets/d/1VE2t7Ia2UCWPpcIOAcqBqGH9Q8X1LHGFk7uUrcCqMbg/edit"
gs_jpe() = "1Pa-qShyqE57CdUXHlhHD95wIP9MFPJG9xmlzTVPeGzA"
gs_reports_id() = "1R74dGMJ2UAfSSVCmjSQLo-qflGRXvNnDGD9ZCEebtTw"


gs_date(x) = Date(x, dateformat"dd/mm/yyyy")
gs_timestamp(x) = Date(x, dateformat"dd/mm/yyyy H:M:S")
parsebool(x::String) = lowercase(x) == "yes" ? true : false

get_case_id(journal,slug,round) = joinpath(journal, slug, string(round))
function get_dbox_loc(journal,slug,round; full = false)
    cid = get_case_id(journal,slug,round)

    if !full 
        "/" * cid
    else
        joinpath(ENV["JPE_DBOX_APPS"],cid)
    end
end

"""
    setup_dropbox_structure!(r::DataFrameRow, dbox_token; sendauthor=true)

Creates the necessary folder structure in Dropbox for a paper and optionally
creates file requests for the replication package and paper appendices.

# Arguments
- `r::DataFrameRow`: A row from the papers dataframe containing paper information
- `dbox_token`: Dropbox authentication token
- `sendauthor::Bool=true`: Whether to create file requests for authors

# Returns
- The updated DataFrameRow with file request information
"""
function setup_dropbox_structure!(r::DataFrameRow, dbox_token; create_fr = true)
    # Get case ID for file request naming
    cid = get_case_id(r.journal, r.paper_slug, r.round)
    
    # Set up paths
    r.file_request_path = get_dbox_loc(r.journal, r.paper_slug, r.round)
    r.file_request_path_full = get_dbox_loc(r.journal, r.paper_slug, r.round, full = true)
    r.repl_package_path = joinpath(r.file_request_path,"replication_package")
    r.paper_path = joinpath(r.file_request_path,"paper_appendices")

    # Create directories
    mr = string(ENV["JPE_DBOX_APPS"], r.repl_package_path)
    mp = string(ENV["JPE_DBOX_APPS"], r.paper_path)
    mkpath(mr)
    mkpath(mp)
    
    # Create file requests if needed
    if create_fr
        fr_pkg   = dbox_create_file_request(r.repl_package_path, "$cid upload", dbox_token)
        fr_paper = dbox_create_file_request(r.paper_path, "$cid upload", dbox_token)
        r.file_request_id_pkg = fr_pkg["id"]
        r.file_request_id_paper = fr_paper["id"]
        r.file_request_url_pkg = fr_pkg["url"]
        r.file_request_url_paper = fr_paper["url"]
    end
end

"""
    google_arrivals(; append = true, sendJO = true, sendauthor = true, create_gh = true)

Ingest new papers into the database from Google Sheets, send file requests to authors and JO,
and store in the papers table. This function is designed to be robust against database corruption
by using transactions and proper error handling for database operations.

# Arguments
- `append::Bool`: Whether to append to existing tables or replace them
- `sendJO::Bool`: Whether to send emails to the Journal Office
- `sendauthor::Bool`: Whether to send emails to authors
- `create_gh::Bool`: Whether to create GitHub repositories

# Returns
- The new rows that were added to the database, or all rows if not appending
"""
function google_arrivals(; append = true, sendJO = true, sendauthor = true, create_gh = true, create_fr = true)
    # Step 1: Read data from Google Sheets - this already uses db_append_new_df internally
    # which now has improved transaction handling
    x = read_google_arrivals(append = append)

    # If no new data, use existing data from database
    if isnothing(x)
        x1 = db_df("form_arrivals")
    else
        x1 = x
    end
    
    # Prepare data for database
    y = prepare_arrivals_for_db(x1)
    
    # Create a backup before processing
    # This is a critical step for data integrity
    db_write_backup("papers_backup", y)
    
    # Process each row
    for r in eachrow(y)
        ghid = string(r.journal, "-", r.surname_of_author, "-", r.paper_id)
        @info "processing $ghid"
        cid = get_case_id(r.journal, r.paper_slug, r.round)

        # create folder structure and file requests
        setup_dropbox_structure!(r, dbox_token; create_fr = create_fr)

        # create gh repo for this package from template
        gh_url = "JPE-Reproducibility/" * ghid
        if create_gh
            run(`gh repo create $(gh_url) --private --template JPE-Reproducibility/JPEtools.jl`)
        else
            @warn "not creating repo for $ghid"
        end

        r.github_url = "https://github.com/" * gh_url

        # send email to authors
        if sendauthor
            gmail_file_request(r.firstname_of_author, r.paper_id, r.title, r.file_request_url_pkg, r.email_of_author)
        else
            @warn "not sending author FR for $ghid"
        end

        r.date_with_authors = Dates.today()

        # send email to JO
        if sendJO
            gmail_file_request("Journal Office", r.paper_id, r.title, r.file_request_url_paper, "jpe@press.uchicago.edu", JO = true)
        else
            @warn "not sending email to JO requesting paper for $ghid"
        end
    end

    # Final security backup after all processing
    db_write_backup("papers", y)

    
    # Use the improved db_append_new_df function for database operations
    # This now uses robust_db_operation internally for better transaction handling
    if append
        # This is the critical database operation that needs to be robust
        new_papers = db_append_new_df("papers", "paper_id", y)
        db_add_unique_constraint("papers", "paper_id")
        # Use composite key for iterations table
        new_iters = db_append_new_df("iterations", ["paper_id", "round"], select(y,Not(:timestamp)))

        # Add unique constraint for composite key in iterations table
        db_add_unique_constraint("iterations", ["paper_id", "round"])

        # add missing columns to iterations
        mi = db_add_missing_columns("iterations")
        return new_papers,new_iters
    else
        return y
    end
end

function db_read_all_arrivals()
    with_db() do con
        DBInterface.execute(con, "SELECT * FROM form_arrivals") 
    end
end

"""
    db_append_new_df(table::String, row_hash_var::Union{String, Vector{String}}, df::DataFrame)

Append new rows from a dataframe to a database table.
This function handles both creating a new table and appending to an existing one.
It uses transactions and error handling to ensure database integrity.

# Arguments
- `table::String`: The name of the table to append to
- `row_hash_var::Union{String, Vector{String}}`: The column name(s) to use for identifying unique rows.
  Can be a single column name as a String or multiple column names as a Vector{String}.
  For tables with composite primary keys (like "reports" with paper_id and round), use a vector.
- `df::DataFrame`: The dataframe containing the rows to append

# Returns
- The new rows that were appended, or the entire dataframe if a new table was created
- `nothing` if no new rows were added
"""
function db_append_new_df(table::String, row_hash_var::Union{String, Vector{String}}, df::DataFrame)
    # Validate table name to prevent SQL injection
    if !occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", table)
        error("Invalid table name: $table")
    end
    
    # Make a copy of the dataframe to avoid modifying the original
    df_copy = copy(df)
    
    exists = db_table_exists_and_not_empty(table)

    if exists 
        # Use robust_db_operation for better transaction management
        return robust_db_operation() do con
            if row_hash_var isa String
                # Single column case - original behavior
                # Get existing rows
                existing = DataFrame(DBInterface.execute(con, "SELECT $row_hash_var FROM $table"))
                
                # Find new rows using a more robust method
                new_rows = antijoin(df_copy, existing; on=row_hash_var, matchmissing=:notequal)
            else
                # Multiple columns case
                # Construct the SQL query to select all key columns
                columns_str = join(row_hash_var, ", ")
                existing = DataFrame(DBInterface.execute(con, "SELECT $columns_str FROM $table"))
                
                # Find new rows using antijoin with multiple columns
                new_rows = antijoin(df_copy, existing; on=row_hash_var, matchmissing=:notequal)
            end
            
            if nrow(new_rows) > 0
                # Register the dataframe and insert new rows
                DuckDB.register_data_frame(con, new_rows, "new_rows")
                query = string("INSERT INTO ", table, " SELECT * FROM new_rows")
                DBInterface.execute(con, query)
                
                @info "Appended $(nrow(new_rows)) new rows to $table"
                return new_rows
            else
                @info "No new rows to import into existing table."
                return nothing
            end
        end
    else
        # Table doesn't exist, create it
        return robust_db_operation() do con
            DuckDB.register_data_frame(con, df_copy, "df_new")
            query = string("CREATE OR REPLACE TABLE ", table, " AS SELECT * FROM df_new")
            DBInterface.execute(con, query)
            
            @info "Created table $table and imported all data from df."
            return df_copy
        end
    end
end

"""
reads the entire google form about arrivals from the JO
does some quick cleaning of names
by default appends new rows to the local database
"""
function read_google_arrivals( ; append = true)

    gs4_auth()
    gs_arrivals = gs4_arrivals()

    # create a clean df from gs_arrivals
    df = gs_arrivals |> polish_names |> DataFrame

    # rename
    DataFrames.rename!(df, 
        "first_name(s)_of_author" => "firstname_of_author",
        "email_of_second_author_(if_applicable)" => "email_of_second_author",
        "does_the_data_availatilibty_statement_form_mention_any_access_restrictions_for_used_data" => "is_confidential",
        "can_the_confidential_data_be_shared_with_the_data_editor_(if_applicable)" => "share_confidential"
    )
    if nrow(df) > 0
        df.paper_id .= google_paperid(df,"paper_id")
        df.journal .= clean_journalname.(df.journal)
        df.paper_slug = get_paper_slug.(df.surname_of_author,df.paper_id)
    end

    # save in db
    # Read existing table, or create it
    db_write_backup("arrivals",df)

    if append
        new_rows = db_append_new_df("form_arrivals","paper_id",df)
        return new_rows
    else
        return df
    end
end

"""
reads the entire google form with reports from replicators
"""
function read_google_reports( ; append = true)

    gs4_auth()
    gs_reports = gs4_reports()

    # create a clean df from gs_arrivals
    df = gs_reports |> polish_names |> DataFrame

    df.round = convert.(Int,df.round)

    # rename
    nm = names(df)
    nm = replace.(nm, "_(if_applicable)" => "", 
        "replication_successul" => "is_success",
        "does_the_package_rely_on_confidential_data_i_e_not_all_required_data_can_be_included_in_the_package" => "is_confidential",
        "was_the_confidential_data_shared_with_us" => "shared_confidential",
        "did_you_perform_a_remote_replication" => "is_remote",
        "did_the_package_contain_high_performance_computing_(hpc)_requirements_(whether_or_not_we_ran_those_parts)" => "is_HPC",
        "what_was_the_total_runtime_of_this_package_in_hours" => "running_time_of_code",
        "quality_assessment_of_readme" => "readme_quality",
        "package_complexity_assessment" => "package_complexity",
        "did_push_your_report_to_the_github_repo_of_this_paper" => "did_push"
    )

    DataFrames.rename!(df,nm)
    select!(df, Not([:please_enter_the_password_for_this_form,:did_push]))

    if nrow(df) > 0
        df.paper_id .= google_paperid(df,"paper_id")
        df.journal .= clean_journalname.(df.journal)
    end

    # save in db
    # Read existing table, or create it
    db_write_backup("reports",df)

    if append
        # Use both paper_id and round as the composite key for reports table
        new_rows = db_append_new_df("reports", ["paper_id", "round"], df)
        return new_rows
    else
        return df
    end
end

function google_paperid(df,var::String)
    x = df[!,var]
    r = if collect(skipmissing(x))[1] isa Number
        passmissing(floor).(Int,x) 
    else
        passmissing(floor).(Int,passmissing(parse).(Float64,x))
    end
    string.(r)
end

clean_journalname(j::String) = replace(j, ":" => "-")
get_paper_slug(last,id) = last * "-" * id


# adding to papers table
function prepare_arrivals_for_db(df0::DataFrame)

    df = copy(df0)

    df.first_arrival_date .= Date.(df.timestamp)
    df.is_confidential     = parsebool.(df.is_confidential)
    df.share_confidential   = parsebool.(df.share_confidential)
    df.status           .= "new_arrival"
    df.round            .= 1
    df.file_request_id_pkg = Array{Union{Missing, String}}(missing, nrow(df))
    df.file_request_path = Array{Union{Missing, String}}(missing, nrow(df))
    df.repl_package_path = Array{Union{Missing, String}}(missing, nrow(df))
    df.paper_path = Array{Union{Missing, String}}(missing, nrow(df))
    df.file_request_path_full = Array{Union{Missing, String}}(missing, nrow(df))
    df.file_request_url_pkg = Array{Union{Missing, String}}(missing, nrow(df))
    df.file_request_id_paper = Array{Union{Missing, String}}(missing, nrow(df))
    df.file_request_url_paper = Array{Union{Missing, String}}(missing, nrow(df))

    df.date_with_authors = Array{Union{Missing, Date}}(missing, nrow(df))
    df.is_remote         = Array{Union{Missing, Bool}}(missing, nrow(df))
    df.is_HPC            = Array{Union{Missing, Bool}}(missing, nrow(df))
    df.data_statement    = Array{Union{Missing, String}}(missing, nrow(df))
    df.software          = Array{Union{Missing, String}}(missing, nrow(df))
    df.github_url        = Array{Union{Missing, String}}(missing, nrow(df))

    return df
   
    

    # # cycle through each row and check what needs to be done in each case.
    # @debug "$(nrow(df)) new arrivals to process"
    # for ir in eachrow(df)

    #     @info "processing new arrival $(ir.paper_id) from $(ir.journal)"

    #     # check that dropbox folder exists and is populated
    #     pname = join([ir.surname_of_author, ir.paper_id], "-")
    #     dpath = joinpath(dropbox(), "package-arrivals", replace(ir.journal, ":" => "-"), pname)
    #     if !isdir(dpath)
    #         @warn "Dropbox folder does not exist for $(pname)"
    #     else
    #         @info "Dropbox does exist:"
    #         printwalkdir(dpath)
    #     end
        
    #     choice = ask(DefaultPrompt(["y", "no"], 1, "Verified dropbox - Good to continue?"))
    #     if choice == "y"
    #         println("Continuing with package")
    #     else
    #         println("Stopping process")
    #         return 1
    #     end

    #     if ir.is_confidential
    #         @info "JO says there is confidential data in the package"
    #         choice = ask(DefaultPrompt(["y", "no"], 1, "send file request upload link?"))
    #         if choice == "y"
    #             # create dropbox file request

    #             # draft email to authors with link

    #             # add FR id to ir.

    #         else
    #             @info "not sending file request link"
    #         end
    #     end

    #     choice = ask(DefaultPrompt(["y", "no"], 1, "Package complete and ready for dispatch?"))
    #     if choice == "y"
    #         # nothing to do, status is correct
    #     else
    #         ir.status = "new_arrival_missing"
    #     end

    # end
    return df
end


function store_arrivals(df::DataFrame)

    news = db_append_new_df("papers", "paper_id", df)

    @info "done importing."
end
