


"""
JPE.jl Module

This package is the database backend and job assignment logic for the JPE Data Editor. 

Functionality:

* Read new arrivals from google sheet
* Log new arrivals in database
* Assign cases to replicators
* Read replicator reports from google sheets
* Create or update github repositories for packages
* Send dropbox file requests to authors
* Send emails with RnR and reports to authors
"""
module JPE

using Dates
using DuckDB
using DataFrames
using Term
using Term.Prompts: DefaultPrompt
using Term: ask, tprint
using REPL.TerminalMenus
using Cleaner
using RCall
using PyCall
using Chain
using Infiltrator
using CSV
using DataFramesMeta
using PrettyTables  # re-exports Crayons
using Statistics


global dbox_token = ""


# Write your package code here.
include("google.jl")
include("db.jl")
include("dropbox.jl")
include("snippets.jl")
include("gmailing.jl")
include("github.jl")
include("actions.jl")
include("zip.jl")
include("reporting.jl")
include("db_backups.jl")

# Export reporting functions
export global_report, paper_report, replicator_workload_report, time_in_status_report
# Export database functions
export db_df, db_filter_paper, db_statuses


function dbox_set_token()
    global dbox_token = dbox_refresh_token()
end

# Global persistent database connection
const JPE_DB = if haskey(ENV,"JPE_DB")
    ENV["JPE_DB"] 
else
    error("env var JPE_DB must be set to location where you want your local duckdb - set the var and restart julia")
end
const DB_PATH = joinpath(JPE_DB,"jpe.duckdb")

const DB_LOCK = ReentrantLock()
const DB_CONNECTION = Ref{Union{Nothing, Any}}(nothing)

# const con = DBInterface.connect(DuckDB.DB, _DB_PATH)

# if needed
function close_db()
    DBInterface.close(con)
end

function show_logo()
    logo = """

       _  _____   ______          _
      | ||  __ \\ |  ____|      _ | |
      | || |__) || |__        | || |
   _  | ||  ___/ |  __|       | || |
  | |_| || |     | |____  _  _| || |
  \\_____/|_|     |______|(_)|___||_|
    """
    println(Crayon(foreground = :black, bold = true,background = :light_cyan), logo, Crayon(reset = true))
    println()
    println(Crayon(foreground = :black, background = :light_cyan, bold = true), "Welcome to JPE.jl!", Crayon(reset = true))
    println()
    println()
end



function __init__()
    # include two python modules
    # 1. dropbox API
    @pyinclude(joinpath(@__DIR__,"db_filerequests.py"))
    dbox_set_token()

    # 2. gmail API
    @pyinclude(joinpath(@__DIR__,"gmail_client.py"))

    if haskey(ENV,"JPE_TEST")
        @warn "running in test mode!"
    end

    show_logo()


    # check_database_status()
    println()
    print("Would you like to fetch a database backup? (y/n): ")
    response = readline()
    if lowercase(strip(response)) == "y"
        db_bk_fetch_latest()
        db_bk_clean(50)
    end
    
    @info "Module loaded ok"

end





end  # module
