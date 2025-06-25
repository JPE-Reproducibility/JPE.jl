

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
    d = joinpath(ENV["JPE_DBOX_APPS"],journal,author * "-" * paperid,round,"replication_package")
    readdir(d)
end

function dbox_check_fr_paper(journal,paperid,author,round)
    d = joinpath(ENV["JPE_DBOX_APPS"],journal,author * "-" * paperid,round,"paper_appendices")
    readdir(d)
end

function dbox_fr_submit_time(token,dest)
    py"submission_time"(token,dest)
end