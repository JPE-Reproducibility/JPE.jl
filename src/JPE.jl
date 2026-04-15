


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
using Unicode
using HTTP
using JSON
using MD5
using Random
using CategoricalArrays

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
include("dataverse.jl")
include("preprocess.jl")



# Export reporting functions
export ps
# Export database functions
export db_df, db_filter_paper


function dbox_set_token()
    global dbox_token = dbox_refresh_token()
end

# Global persistent database connection
# These are Refs so they are set at __init__ time (runtime), NOT baked into the
# precompile cache. Using const String values here caused DB_PATH to be frozen
# to whatever JPE_DB was at precompile time, making the module fail when loaded
# from cache in a different environment.
const JPE_DB = Ref{String}("")
const DB_PATH = Ref{String}("")

const DB_LOCK = ReentrantLock()
const DB_CONNECTION = Ref{Union{Nothing, Any}}(nothing)

# dataverse token
dvtoken() = ENV["JPE_DV"]

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
    # Initialise runtime-dependent paths (must come first; these are Refs, not
    # precompiled consts, so they are safe across different environments)
    if !haskey(ENV, "JPE_DB")
        error("env var JPE_DB must be set to location where you want your local duckdb - set the var and restart julia")
    end
    JPE_DB[] = ENV["JPE_DB"]
    DB_PATH[] = joinpath(ENV["JPE_DB"], "jpe.duckdb")

    # include two python modules
    # 1. dropbox API
    @pyinclude(joinpath(@__DIR__,"db_filerequests.py"))
    dbox_set_token()

    # 2. gmail API
    @pyinclude(joinpath(@__DIR__,"gmail_client.py"))

    # verify gh CLI is authenticated as the JPE account
    gh_check_auth()

    

    if haskey(ENV,"JPE_TEST")
        @warn "running in test mode!"
    end

    show_logo()

    ps()
    println()
    
    @info "Module loaded ok"

end





end  # module
