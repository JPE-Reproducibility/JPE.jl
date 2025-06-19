# use R googlesheets4 to work with google sheets

function gs4_auth()

    path = ENV["JPE_GOOGLE_KEY"]
    R"""
    googlesheets4::gs4_auth(path = $(path))
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

function gs4_delete_arrivals()
    R"""
    googlesheets4::range_delete($(gs_arrivals_id()), sheet = 'new-arrivals', range = "2:100" )
    """
end






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


gs_arrivals_id() = "1suU5e1Vc9LeVW9MgPFDsctZPSLKKwYn8pSf8LLMfNB8"
gs_arrivals_url() = "https://docs.google.com/spreadsheets/d/1suU5e1Vc9LeVW9MgPFDsctZPSLKKwYn8pSf8LLMfNB8/edit"
gs_jpe() = "1Pa-qShyqE57CdUXHlhHD95wIP9MFPJG9xmlzTVPeGzA"


gs_date(x) = Date(x, dateformat"dd/mm/yyyy")
gs_timestamp(x) = Date(x, dateformat"dd/mm/yyyy H:M:S")
parsebool(x::String) = lowercase(x) == "yes" ? true : false

function google_arrivals()
    x = read_google_arrivals()
    @info "$(nrow(x)) incoming new arrivals"

    y = process_google_arrivals(x)
    store_google_arrivals(y)
end

function read_google_arrivals()

    gs4_auth()
    gs_arrivals = gs4_arrivals()

    # create a clean df from gs_arrivals
    df = gs_arrivals |> polish_names |> DataFrame

    # append gs_arrivals to `recorded` spreadsheet
    gs4_append_arrivals(gs_arrivals)

    return df
end

function google_paperid(df,var::String)
    x = df[!,var]
    if collect(skipmissing(x))[1] isa Number
        passmissing(floor).(Int,x) 
    else
        passmissing(floor).(Int,passmissing(parse).(Float64,x))
    end
end

clean_journalname(j::String) = replace(j, ":" => "-")


function process_google_arrivals(df0::DataFrame)

    df = copy(df0)
    select!(df, Not(r"password"))

    DataFrames.rename!(df,names(df,r"reminder")[1] => "dropbox_reminder")
    DataFrames.rename!(df, 
        "paper_id_(micro_macro)" => "paper_id_micro_macro",
        "first_name(s)_of_author" => "firstname_of_author",
        "email_of_second_author_(if_applicable)" => "email_of_second_author",
        "does_the_das_mention_any_access_restrictions_for_used_data" => "is_confidential"
    )
    
    df.paper_id .= google_paperid(df,"paper_id")
    df.paper_id_micro_macro .= google_paperid(df,"paper_id_micro_macro")
    
    # fix paper id column and drop
    df.paper_id = ifelse.(df.journal .== "JPE", df.paper_id, df.paper_id_micro_macro)
    select!(df, Not(:paper_id_micro_macro))

    df.first_arrival_date .= Date.(df.timestamp)
    df.is_confidential     = parsebool.(df.is_confidential)

    df.file_request_id = Array{Union{Missing, String}}(missing, nrow(df))

    df.status           .= "new_arrival"
    df.round            .= 1
    df.date_with_authors = Array{Union{Missing, Date}}(missing, nrow(df))
    df.is_remote         = Array{Union{Missing, Bool}}(missing, nrow(df))
    df.is_HPC            = Array{Union{Missing, Bool}}(missing, nrow(df))
    df.data_statement    = Array{Union{Missing, String}}(missing, nrow(df))
    df.dataverse_label   = Array{Union{Missing, String}}(missing, nrow(df))
    df.software          = Array{Union{Missing, String}}(missing, nrow(df))
    df.github_url        = Array{Union{Missing, String}}(missing, nrow(df))
    

    # cycle through each row and check what needs to be done in each case.
    @debug "$(nrow(df)) new arrivals to process"
    for ir in eachrow(df)

        @info "processing new arrival $(ir.paper_id) from $(ir.journal)"

        # check that dropbox folder exists and is populated
        pname = join([ir.surname_of_author, ir.paper_id], "-")
        dpath = joinpath(dropbox(), "package-arrivals", replace(ir.journal, ":" => "-"), pname)
        if !isdir(dpath)
            @warn "Dropbox folder does not exist for $(pname)"
        else
            @info "Dropbox does exist:"
            printwalkdir(dpath)
        end
        
        choice = ask(DefaultPrompt(["y", "no"], 1, "Verified dropbox - Good to continue?"))
        if choice == "y"
            println("Continuing with package")
        else
            println("Stopping process")
            return 1
        end

        if ir.is_confidential
            @info "JO says there is confidential data in the package"
            choice = ask(DefaultPrompt(["y", "no"], 1, "send file request upload link?"))
            if choice == "y"
                # create dropbox file request

                # draft email to authors with link

                # add FR id to ir.

            else
                @info "not sending file request link"
            end
        end

        choice = ask(DefaultPrompt(["y", "no"], 1, "Package complete and ready for dispatch?"))
        if choice == "y"
            # nothing to do, status is correct
        else
            ir.status = "new_arrival_missing"
        end

    end
    return df
end


function store_arrivals(df::DataFrame)

    # build an insertion dataframe
    # i =

    # add to local database of papers
    a = ask(DefaultPrompt(["y", "no"], 1, "Insert $(nrow(df)) new papers into local database?"))
    if a == "y"
        appender = DuckDB.Appender(con, "papers")
        for i in eachrow(df)
            for j in i
                DuckDB.append(appender, j)
            end
            DuckDB.end_row(appender)
        end
        DuckDB.close(appender)

        @show db_df("papers")

    else
        return 1
    end

    a = ask(DefaultPrompt(["y", "no"], 1, "delete responses on google sheet?"))
    if a == "y"
        gs4_delete_arrivals()
    else
        gs4_browse()
    end

    @info "done importing."
end




