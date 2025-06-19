


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


# Write your package code here.
include("google.jl")
include("db.jl")
include("dropbox.jl")
include("snippets.jl")


end
