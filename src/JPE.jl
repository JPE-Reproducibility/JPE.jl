


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
# using RCall
using PyCall

global dbox_token = ""




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

    # 2. gmail API
    @pyinclude("gmail_client.py")

    @info "Module loaded ok"

end

dbox_refresh_token() = py"refresh_token"()
dbox_get_user(to) = py"get_user_info"(to)

function dbox_link_at_path(path,dbox_token)
    try
        py"get_link_at_path"(path,dbox_token)
    catch e1
        try
            @error "$e1"
            @info "refreshing dropbox token"
            dbox_set_token()
            py"get_link_at_path"(path,dbox_token)
        catch e2
            throw(e2)
        end
    end
end



end  # module
