

gh_delete_repo(url) = run(`gh repo delete $url --yes`)

function gh_rename_branch(gh_url::String, old::String, new::String)
    cmd = Cmd([
        "gh", "api",
        "-X", "POST",
        "repos/$gh_url/branches/$old/rename",
        "-f", "new_name=$new"
    ])
    gh_silent_run(cmd)
end

function gh_clone_branch(gh_url,round;to = nothing)
    if isnothing(to)
        run(`git clone --branch $(round) --single-branch git@github.com:$(gh_url)`)
    else
        if isdir(to)
            @warn "directory $to already exists - removing"
            rm(to, recursive=true, force=true)
        end
        run(`git clone --branch $(round) --single-branch git@github.com:$(gh_url) $to`)
    end
end

function gh_create_branch_on_github_from(gh_url,from,to)
    # Get the latest commit SHA of version1
    sha=strip(read(`gh api repos/$(gh_url)/git/ref/heads/$(from) --jq .object.sha`, String))

    # Create `to` from `from`
    cmd = Cmd([
        "gh", "api",
        "-X", "POST",
        "repos/$(gh_url)/git/refs",
        "-f", "ref=refs/heads/$(to)",
        "-f", "sha=$(sha)"
    ])
    gh_silent_run(cmd)
end

function gh_repo_exists(repo::String)::Bool
    try
        read(`gh api repos/$repo --jq .id`, String)
        return true
    catch e
        return false
    end
end




function gh_delete_branch(owner_repo::String, branch::String)
    cmd = Cmd([
        "gh", "api",
        "-X", "DELETE",
        "repos/$owner_repo/git/refs/heads/$branch"
    ])
    run(cmd)  # or you can capture output with read(cmd, String) if you want
end


function wait_for_branch(gh_url::String, branch::String; max_wait=10, interval=1)
    for i in 1:max_wait
        try
            sha = strip(read(`gh api repos/$gh_url/git/ref/heads/$branch --jq .object.sha`, String))
            println("✅ Branch '$branch' is now available. SHA: $sha")
            return sha
        catch e
            @info "waiting for $branch to appear $i"
            sleep(interval)
        end
    end
    error("❌ Timed out waiting for branch '$branch' in repo '$gh_url'")
end


function gh_silent_run(cmd::Cmd)
    try
        run(pipeline(cmd, stdout=devnull, stderr=devnull))
        return true
    catch e
        @warn "Command failed" command=cmd error=e
        return false
    end
end


function force_git_clone(repo_url::String, local_path::String)
    # Remove existing directory if it exists
    if isdir(local_path)
        println("Removing existing directory: $local_path")
        rm(local_path, recursive=true, force=true)
    end
    
    # Clone fresh
    println("Cloning $repo_url to $local_path")
    run(`git clone $repo_url $local_path`)
    
    return local_path
end