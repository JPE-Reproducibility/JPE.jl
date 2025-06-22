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


gs_date(x) = Date(x, dateformat"dd/mm/yyyy")
gs_timestamp(x) = Date(x, dateformat"dd/mm/yyyy H:M:S")
parsebool(x::String) = lowercase(x) == "yes" ? true : false


# ingestion of new papers into database
# sends FR to author and JO
# stores in papers table
function google_arrivals(; append = true)
    x = read_google_arrivals( append = append)
    y = prepare_arrivals_for_db(x)
   
    for r in eachrow(y)
        # mkpath to dropbox
        pid = string(r.surname_of_author,"-",r.paper_id)
        ghid = string(r.journal,"-",r.surname_of_author,"-",r.paper_id)
        @info "processing $ghid"
        cid = joinpath(r.journal,pid,"1")

        # create folder structure and file requests
        rpth = joinpath(cid,"replication_package")
        ppth = joinpath(cid,"paper_appendices")
        mkpath(joinpath(ENV["JPE_DBOX_APPS"],rpth))
        mkpath(joinpath(ENV["JPE_DBOX_APPS"],ppth))
        fr_pkg = dbox_create_file_request("/" * rpth,"$cid upload",dbox_token)
        fr_paper = dbox_create_file_request("/" * ppth,"$cid upload",dbox_token)
        r.file_request_id_pkg = fr_pkg["id"]
        r.file_request_id_paper = fr_paper["id"]
        r.file_request_url_pkg = fr_pkg["url"]
        r.file_request_url_paper = fr_paper["url"]

        # create gh repo for this package from template
        gh_url = "JPE-Reproducibility/" * ghid
        run(`gh repo create $(gh_url) --private --template JPE-Reproducibility/JPEtools.jl`)

        r.github_url = "https://github.com/" * gh_url

        # send email to authors
        gmail_file_request(r.firstname_of_author,r.paper_id,r.file_request_url_pkg,r.email_of_author)

        r.date_with_authors = Dates.today()


        # send email to JO
        gmail_file_request("Journal Office",r.paper_id,r.file_request_url_paper,"jpe@press.uchicago.edu", JO = true)
    end

    news = db_append_new_df("papers","paper_id",y)
    news
end

function read_all_arrivals()
    con = oc()
    d = DBInterface.execute(con, "SELECT * FROM form_arrivals") |> DataFrame
    cc(con)
    d
end

# function 
# append new rows from a dataframe to a database table
# data comes from an onlien form for example
function db_append_new_df(table::String,row_hash_var::String,df::DataFrame)
    con = oc()
    DuckDB.register_data_frame(con, df, "df")

    existing = if db_table_exists(table)
        DBInterface.execute(con, "SELECT $row_hash_var FROM $table") |> DataFrame
    else
        # Table doesn't exist; create it from the first import
        DBInterface.execute(con, "CREATE TABLE $table AS SELECT * FROM df")
        @info "Created table $table and imported all data from df."
        return df
    end
    # filter on row_hash
    new_rows = antijoin(df, existing; on=row_hash_var, matchmissing=:notequal)
    if nrow(new_rows) > 0
        # Append new rows
        DBInterface.execute(con, "INSERT INTO $table SELECT * FROM new_rows")
        @info "Appended $(nrow(new_rows)) new rows to $table"
    else
        @info "No new rows to import."
    end
    cc(con)
    
    return new_rows

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
    df.paper_id .= google_paperid(df,"paper_id")
    df.journal .= clean_journalname.(df.journal)

    # save in db
    # Read existing table, or create it
    if append
        new_rows = db_append_new_df("form_arrivals","paper_id",df)
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


# adding to papers table
function prepare_arrivals_for_db(df0::DataFrame)

    df = copy(df0)

    df.first_arrival_date .= Date.(df.timestamp)
    df.is_confidential     = parsebool.(df.is_confidential)
    df.share_confidential   = parsebool.(df.share_confidential)
    df.status           .= "new_arrival"
    df.round            .= 1
    df.file_request_id_pkg = Array{Union{Missing, String}}(missing, nrow(df))
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
    return new_records
end


function store_arrivals(df::DataFrame)

    news = db_append_new_df("papers","paper_id",df)

    @info "done importing."
end




