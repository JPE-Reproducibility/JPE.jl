


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

function dbox_set_token()
    global dbox_token = dbox_refresh_token()
end

function __init__()
    # pushfirst!(pyimport("sys")."path", "")
    # pyimport("gmail_client")
    @pyinclude("db_filerequests.py")

    # py"""
    # import dropbox
    # from dropbox.sharing import RequestedVisibility, SharedLinkSettings
    # import os
    # import requests
    # from dropbox import Dropbox

    # # main.py

    # # from gmail_client import create_draft_email, send_email

    # # Load secrets from environment variables
    # APP_KEY = os.environ["JPE_DBOX_APP"]
    # APP_SECRET = os.environ["JPE_DBOX_APP_SECRET"]
    # REFRESH_TOKEN = os.environ["JPE_DBOX_APP_REFRESH"]

    # def refresh_token():
    #     url = "https://api.dropbox.com/oauth2/token"
    #     response = requests.post(
    #         url,
    #         auth=(APP_KEY, APP_SECRET),
    #         data={
    #             "grant_type": "refresh_token",
    #             "refresh_token": REFRESH_TOKEN
    #         }
    #     )
    #     response.raise_for_status()
    #     return response.json()["access_token"]
    

    # def get_user_info(token):
    #     dbx = Dropbox(token)
    #     return dbx.users_get_current_account()


    # def get_link_at_path(path,token):
    #     "get a shareable link for local path /Apps/JPE-packages/path"

    #     dbx = Dropbox(token)

    #     try:
    #         # Create settings with 'public' visibility (default for shared links)
    #         settings = SharedLinkSettings(
    #             requested_visibility=RequestedVisibility.public
    #         )
        
    #         # Attempt to create a new shared link
    #         link = dbx.sharing_create_shared_link_with_settings(path, settings)
    #         print("Public shared link:", link.url)
    #         return link.url
        
    #     except dropbox.exceptions.ApiError as e:
    #         # If a link already exists, list existing links instead
    #         if isinstance(e.error, dropbox.sharing.CreateSharedLinkWithSettingsError) and e.error.is_shared_link_already_exists():
    #             links = dbx.sharing_list_shared_links(path=path, direct_only=True)
    #             if links.links:
    #                 print("Existing public shared link:", links.links[0].url)
    #                 return inks.links[0].url
    #             else:
    #                 print("A shared link exists, but we couldn't retrieve it.")
    #         else:
    #             print("Error creating shared link:", e)

    # """

    # set the dropbox token
    # dbox_refresh_token()


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

function dbox_create_file_request(token,title,destination)
    py"create_file_request"(token, title, destination)
end

end  # module
