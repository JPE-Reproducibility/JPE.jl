

dbox_arrivals() = joinpath(dropbox(), "package-arrivals")

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

function dbox_create_file_request(dest,title,token)
    try
        py"create_file_request"(token,title,dest)
    catch e1
        try
            @error "$e1"
            @info "refreshing dropbox token"
            dbox_set_token()
            py"create_file_request"(token,title,dest)
        catch e2
            throw(e2)
        end
    end

end

function dbox_check_fr_pkg(journal,paperid,author,round)
    d = joinpath(ENV["JPE_DBOX_APPS"],journal,author * "-" * paperid,round,"replication-package")
    readdir(d)
end

function dbox_check_fr_paper(journal,paperid,author,round)
    d = joinpath(ENV["JPE_DBOX_APPS"],journal,author * "-" * paperid,round,"paper-appendices")
    readdir(d)
end

function dbox_fr_submit_time(token,dest)
    py"submission_time"(token,dest)
end

function dbox_fr_exists(token,dest)
    py"file_request_exists"(token,dest)
end

function dbox_fr_arrived(token,id)
    py"check_file_request_submissions"(token, id)
end

"""
Show the file requests and their status for all iterations of a given paper
"""
function dbox_fr_paper(paperID)
    i = @chain db_filter_iteration(paperID) begin
        select(:round, r"file_request_id")
        stack(Not(:round))
    end
    i.submitted_files .= 0
    for r in eachrow(i)
        r.submitted_files = dbox_fr_arrived(dbox_token, r.value)["file_count"]
    end
    println()
    @info "--- paper $paperID file requests status ----"
    i
end

"""
Show the file request urls and ids
"""
function dbox_fr_paper_urls(paperID)
    i = @chain db_filter_iteration(paperID) begin
        select(:round, r"file_request_id_", r"file_request_url_")
        stack(Not(:round))
    end
    return i
end