

gh_delete_repo(url) = run(`gh repo delete $url --yes`)

function gh_pull(paper_id; round=nothing)
    paper = db_filter_paper(paper_id)
    if nrow(paper) != 1
        error("Paper ID $paperID not found or has multiple entries")
    end

    r = NamedTuple(paper[1, :])
 
    # Set up paths
    localloc = get_dbox_loc(r.journal, r.paper_slug, r.round, full = true)
    repo_path = joinpath(localloc, "repo")
    
    # Handle repository - check if it exists first
    if isdir(repo_path)
        @info "Repository already exists at $repo_path"
        # Pull latest changes instead of cloning
        try
            run(Cmd(`git pull`, dir=repo_path))
            @info "Pulled latest changes from remote repository"
        catch e
            @warn "Could not pull latest changes: $e"
            @info "You may need to commit your local changes first"
        end
    else
        # Clone if it doesn't exist
        gh_clone_branch(r.gh_org_repo, "round$(r.round)", to = repo_path)
        @info "Cloned repository to $repo_path"
    end
    return (r,repo_path)
end

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
    
    # Check if `to` branch already exists
    try
        read(`gh api repos/$(gh_url)/git/ref/heads/$(to)`, String)
        @warn "Branch $(to) already exists, skipping creation"
        return
    catch
        # Branch doesn't exist, proceed with creation
    end
    
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

"""
    sanitize_repo_name(name::AbstractString; interactive::Bool=true)

Convert a personal name into a GitHub-safe ASCII repository name.
Includes extensive transliteration rules and a final fallback that
prompts the user for unknown characters if `interactive=true`.
"""
function sanitize_repo_name(name::AbstractString; interactive::Bool=true)
    translit_map = Dict(
        # Scandinavian & German
        'ä'=>"ae",'ö'=>"oe",'ü'=>"ue",'Ä'=>"Ae",'Ö'=>"Oe",'Ü'=>"Ue",'ß'=>"ss",
        'å'=>"aa",'Å'=>"Aa",'æ'=>"ae",'Æ'=>"Ae",'ø'=>"oe",'Ø'=>"Oe",

        # Spanish
        'á'=>"a",'é'=>"e",'í'=>"i",'ó'=>"o",'ú'=>"u",'ñ'=>"n",
        'Á'=>"a",'É'=>"e",'Í'=>"i",'Ó'=>"o",'Ú'=>"u",'Ñ'=>"n",

        # French / Portuguese
        'ç'=>"c",'Ç'=>"C",'à'=>"a",'À'=>"a",'è'=>"e",'È'=>"e",'ù'=>"u",'Ù'=>"u",
        'â'=>"a",'Â'=>"a",'ê'=>"e",'Ê'=>"e",'î'=>"i",'Î'=>"i",'ô'=>"o",'Ô'=>"o",
        'û'=>"u",'Û'=>"u",'ë'=>"e",'Ë'=>"e",'ï'=>"i",'Ï'=>"i",'ÿ'=>"y",'Ÿ'=>"y",

        # Italian
        'ò'=>"o",'Ò'=>"o",'ì'=>"i",'Ì'=>"i",'ù'=>"u",'Ù'=>"u",

        # Polish
        'ą'=>"a",'Ą'=>"a",'ć'=>"c",'Ć'=>"c",'ę'=>"e",'Ę'=>"e",'ł'=>"l",'Ł'=>"l",
        'ń'=>"n",'Ń'=>"n",'ś'=>"s",'Ś'=>"s",'ź'=>"z",'Ź'=>"z",'ż'=>"z",'Ż'=>"z",

        # Czech / Slovak
        'č'=>"c",'Č'=>"c",'ď'=>"d",'Ď'=>"d",'ě'=>"e",'Ě'=>"e",'ň'=>"n",'Ň'=>"n",
        'ř'=>"r",'Ř'=>"r",'š'=>"s",'Š'=>"s",'ť'=>"t",'Ť'=>"t",'ž'=>"z",'Ž'=>"z",

        # Hungarian
        'ő'=>"o",'Ő'=>"o",'ű'=>"u",'Ű'=>"u",

        # Romanian
        'ă'=>"a",'Ă'=>"a",'ș'=>"s",'Ș'=>"s",'ş'=>"s",'ţ'=>"t",'ț'=>"t",
        'Ț'=>"t",'Ţ'=>"t",

        # Baltic
        'ā'=>"a",'Ā'=>"a",'č'=>"c",'Č'=>"c",'ē'=>"e",'Ē'=>"e",'ģ'=>"g",'Ģ'=>"g",
        'ī'=>"i",'Ī'=>"i",'ķ'=>"k",'Ķ'=>"k",'ļ'=>"l",'Ļ'=>"l",'ņ'=>"n",'Ņ'=>"n",
        'ū'=>"u",'Ū'=>"u",

        # Balkan (Croatian/Serbian/Slovenian/Albanian variants)
        'đ'=>"d",'Đ'=>"d",'ć'=>"c",'Ć'=>"c",'š'=>"s",'Š'=>"s",'ž'=>"z",'Ž'=>"z"
    )

    # Step 1 — explicit transliteration
    buf = IOBuffer()
    unknown_chars = Char[]

    for c in name
        if haskey(translit_map, c)
            print(buf, translit_map[c])
        elseif c in 'A':'Z' || c in 'a':'z' || c in '0':'9' || isspace(c)
            print(buf, c)
        else
            push!(unknown_chars, c)
        end
    end

    # Step 2 — fallback for unknown chars:
    if !isempty(unknown_chars)
        # Try Unicode NFD decomposition and strip diacritics
        decomposed = Unicode.normalize(name, :NFD)
        stripped = replace(decomposed, r"\p{Mn}" => "")  # remove marks

        # After stripping, check if any unexpected chars remain
        still_bad = filter(c -> !(c in 'A':'Z' || c in 'a':'z' ||
                                  c in '0':'9' || isspace(c)), stripped)

        if !isempty(still_bad) && interactive
            println("Unrecognized characters found: ", still_bad)
            println("Enter a plain ASCII replacement for each character.")
            repl = Dict{Char,String}()
            for c in still_bad
                print("Replacement for '$c': ")
                repl[c] = readline()
            end
            # Apply the mapping
            for (c, r) in repl
                stripped = replace(stripped, string(c) => r)
            end
        end

        write(buf, stripped)
    end

    s = String(take!(buf))

    # Step 3 — whitespace → hyphens
    s = replace(s, r"\s+" => "-")

    # Step 4 — keep only allowed [a-z0-9._-]
    s = replace(lowercase(s), r"[^a-z0-9._-]" => "")

    # Step 5 — collapse hyphens and trim
    s = replace(s, r"-+" => "-")
    s = strip(s, '-')

    return titlecase(s)
end
