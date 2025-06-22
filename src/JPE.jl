


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
using Term.Prompts
using Cleaner
using RCall
using PyCall
using Chain
using Infiltrator

global dbox_token = ""

replicators = Ref(DataFrame())   # replicators


# Write your package code here.
include("google.jl")
include("db.jl")
include("dropbox.jl")
include("snippets.jl")
include("gmailing.jl")

function dbox_set_token()
    global dbox_token = dbox_refresh_token()
end

function __init__()
    # include two python modules
    # 1. dropbox API
    @pyinclude("db_filerequests.py")
    dbox_set_token()

    # 2. gmail API
    @pyinclude("gmail_client.py")

    @info "Module loaded ok"

end





end  # module
