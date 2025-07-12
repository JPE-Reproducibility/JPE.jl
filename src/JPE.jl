


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
using Term.Prompts: DefaultPrompt
using Term: ask
using REPL.TerminalMenus
using Cleaner
using RCall
using PyCall
using Chain
using Infiltrator
using CSV
using DataFramesMeta
using PrettyTables
using Statistics

global dbox_token = ""

replicators = Ref(DataFrame())   # replicators


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

# Export reporting functions
export global_report, paper_report, replicator_workload_report, time_in_status_report
# Export database functions
export db_df, db_filter_paper, db_statuses


function dbox_set_token()
    global dbox_token = dbox_refresh_token()
end

# Global persistent database connection
const DB_PATH = "/Users/floswald/JPE/jpe.duckdb"
const DB_JPE = "/Users/floswald/JPE"

const DB_LOCK = ReentrantLock()
const DB_CONNECTION = Ref{Union{Nothing, Any}}(nothing)

# const con = DBInterface.connect(DuckDB.DB, _DB_PATH)

# if needed
function close_db()
    DBInterface.close(con)
end

# caution: there cannot be another open connection at the same time!
# function open_db()
#     DBInterface.connect(DuckDB.DB, _DB_PATH)
# end

function __init__()
    # include two python modules
    # 1. dropbox API
    @pyinclude(joinpath(@__DIR__,"db_filerequests.py"))
    dbox_set_token()

    # 2. gmail API
    @pyinclude(joinpath(@__DIR__,"gmail_client.py"))

    if haskey(ENV,"JPE_TEST")
        @info "running in test mode"
    end

    @info "Module loaded ok"

end





end  # module
