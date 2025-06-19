

"""
invite author for initial submission
"""
function first_file_request(paperID)
    # create FR
    # enter FR ID in db
    # set status in db
    # compose email
    # send emaiol
end

function create_repo(paperID)
    # create gh repo from template which can run prechecks and create template report
    # commit docs in paper dropbox
    # embed doi in commit message as [doi]
    # push to remote to run prechecks and populate report
end

function update_repo(paperID)
    # get doi
    # get github repo
    # get last version from last commit message (or latest tag)
    # commit docs in paper dropbox if any change
    # embed doi in commit message as [doi]
    # push to remote to run prechecks and populate report
end




function assign_new()
    news = DataFrame(DBInterface.execute(con,
        "SELECT * FROM papers WHERE status = 'new_arrival'"
    ))

end