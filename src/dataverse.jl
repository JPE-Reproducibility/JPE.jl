# functionality to query dataverse deposits
# - get all JPE papers on datavers
# - with associated status (published, draft, revision) )

dvserver() = "https://dataverse.harvard.edu"


"""
Get all metadata associated to a dataverse dataset

example
```julia
dv_get_dataset_metadata("doi:10.7910/DVN/VXR3XB")
```
"""
function dv_get_dataset_metadata(doi::String)
    url = "$(dvserver())/api/datasets/:persistentId/versions/:latest?persistentId=$(doi)"
    headers = Dict("X-Dataverse-key" => dvtoken())
    response = HTTP.get(url, headers)
    result = JSON.parse(String(response.body))
    
    if result["status"] == "OK"
        return result["data"]
    else
        error("API error: $(result["message"])")
    end
end


function dv_get_file_list(meta::Dict)
    return [(
        filename = f["dataFile"]["filename"],
        filesize = f["dataFile"]["filesize"],
        md5      = f["dataFile"]["md5"]
    ) for f in meta["files"]]
end

function dv_get_publication_citation(meta::Dict)
    fields = meta["metadataBlocks"]["citation"]["fields"]
    pub_field = findfirst(f -> f["typeName"] == "publication", fields)
    isnothing(pub_field) && error("No publication field found")
    return fields[pub_field]["value"][1]["publicationCitation"]["value"]
end

function local_file_md5s(root::String)
    read_and_unzip_directory(root, rm_zip = false)
    
    result = Dict{String, @NamedTuple{path::String, basename::String}}()
    for (dirpath, _, files) in walkdir(root)
        # Skip __MACOSX and hidden directories
        if contains(dirpath, "__MACOSX") || any(startswith(p, ".") for p in splitpath(dirpath))
            continue
        end
        
        for file in files
            fullpath = joinpath(dirpath, file)
            
            # Skip zip files only at root level
            if dirpath == root && endswith(file, ".zip")
                continue
            end
            
            relpath_ = relpath(fullpath, root)
            hash = bytes2hex(md5(read(fullpath)))
            result[hash] = (path = relpath_, basename = file)
        end
    end
    return result
end

function dv_check_replication_package(meta::Dict, local_root::String)
    dv_files  = dv_get_file_list(meta)
    local_md5s = local_file_md5s(local_root)
    dv_md5s = Dict(f.md5 => f.filename for f in dv_files)

    matched       = [(dv_name = dv_md5s[md5], local_path = info.path) 
                     for (md5, info) in local_md5s 
                     if haskey(dv_md5s, md5) && dv_md5s[md5] == info.basename]
    
    hash_match_name_mismatch = [(dv_name = dv_md5s[md5], local_path = info.path, local_name = info.basename)
                                for (md5, info) in local_md5s
                                if haskey(dv_md5s, md5) && dv_md5s[md5] != info.basename]
    
    only_local    = [info.path for (md5, info) in local_md5s if !haskey(dv_md5s, md5)]
    only_dv       = [name for (md5, name) in dv_md5s if !haskey(local_md5s, md5)]

    return (matched = matched, 
            hash_match_name_mismatch = hash_match_name_mismatch,
            only_local = only_local, 
            only_dv = only_dv)
end

function dv_check_report(nt::NamedTuple)

    answer = 0
    
    while answer < 6
        @info """
        File checks on dataverse report:
        1. md5 and names matched: $(length(nt.matched))
        2. md5 matches, not name: $(length(nt.hash_match_name_mismatch))
        3. files existing only locally: $(length(nt.only_local))
        4. files existing only on dv: $(length(nt.only_dv))
        """
        println("want to see?")
        yes_no_menu = RadioMenu(["no (n)","1. md5 and names matched (m)","2. md5 matches, not name (r)","3. files existing only locally (l)","4. files existing only on dv (d)","exit (e)"],keybindings = ['n','m','r','l','d','e'])  # Default is first option 
        answer = request(yes_no_menu)
        if answer == 1
            # nothing
        elseif answer == 2
            pretty_table(select(DataFrame(nt.matched), :dv_name, :local_path), header = [:dv_name, :local_path])
        elseif answer == 3
            pretty_table(select(DataFrame(nt.hash_match_name_mismatch), :dv_name, :local_name), header = [:dv_name, :local_name])
        elseif answer == 4
            run(pipeline(IOBuffer(join(nt.only_local, "\n")), `cat`, `less`))
        elseif answer == 5
            run(pipeline(IOBuffer(join(nt.only_dv, "\n")), `cat`, `less`))
        end
    end
end

function dv_get_file_report(paperID)
    # get location of local repo
    paper = db_filter_paper(paperID)
    if nrow(paper) != 1
        error("Paper ID $paperID not found or has multiple entries")
    end

    doi = get_package_doi(paperID)
    # get file list and md5 hashes from dv
    dv_meta = dv_get_dataset_metadata(doi)

    r = NamedTuple(paper[1, :])
    localloc = get_dbox_loc(r.journal, r.paper_slug, r.round, full = true)
    package_path = joinpath(localloc, "replication-package")

    file_checks = dv_check_replication_package(dv_meta,package_path)

    dv_check_report(file_checks)
end


function dv_fetch_all_datasets(; subtree::String="JPE", include_size = true)

    base_url = "$(dvserver())/api/search"
    query_params = "q=*&subtree=$(subtree)&showEntityIds=true&showDrafts=true&type=dataset&per_page=100"
    headers = ["X-Dataverse-key" => dvtoken()]

    start = 0
    all_items = []
    all_meta = []

    while true
        url = "$base_url?$query_params&start=$start"

        response = HTTP.get(url, headers)
        if response.status != 200
            error("Failed at start=$start: HTTP $(response.status)")
        end

        data = JSON.parse(String(response.body))
        items = data["data"]["items"]

        if isempty(items)
            break
        end

        if include_size
            for item in items
                doi = item["global_id"]
                size_mb = dv_get_dataset_total_size(doi)
                item["size_mb"] = size_mb
            end
        end

        append!(all_items, items)
        start += length(items)
    end

    return all_items
end

function dv_get_dataset_total_size(persistent_id::String)
    url = "$(dvserver())/api/datasets/:persistentId?persistentId=$(persistent_id)"
    headers = Dict("X-Dataverse-key" => dvtoken())

    try
        response = HTTP.get(url, headers)
        if response.status != 200
            @warn "Failed to get metadata for $persistent_id: HTTP $(response.status)"
            return missing
        end

        metadata = JSON.read(response.body)
        files = get(metadata["data"]["latestVersion"], "files", [])
        if isempty(files)
            return 0.0
        else
            total_bytes = sum(get(file["dataFile"], "filesize", 0) for file in files)
            return total_bytes / 1024^2  # MB
        end
    catch e
        @warn "Error fetching size for $persistent_id: $e"
        return missing
    end
end

function dv_is_draft(meta::Dict)
    return meta["versionState"] == "DRAFT"
end


function dv_filter_published_datasets(datasets::Vector{Any})
    published_items = filter(
        dataset -> begin
            status_list = dataset["publicationStatuses"]
            "Published" in status_list
        end, 
        datasets)

    return published_items
end

function dv_get_all_drafts()
    # Fetch all datasets
    all_datasets = dv_fetch_all_datasets()

    # Filter for Draft and In Review datasets
    draft_review_datasets = dv_filter_draft_review_datasets(all_datasets)

    if isempty(draft_review_datasets)
        println("no drafts found")
    else

        # get list of authorname and doi
        names = [split(split(first(i[:authors]),",")[1]," ")[1] for i in draft_review_datasets]
        dois = [i[:global_id] for i in draft_review_datasets]
        
        d = DataFrame(name = names,doi = dois)
        CSV.write(joinpath(@__DIR__,"..","drafts.csv"),d)
        d

    end
    
end

function dv_get_all_published()
    # Fetch all datasets
    all_datasets = dv_fetch_all_datasets()

    # Filter for Draft and In Review datasets
    published_datasets = dv_filter_published_datasets(all_datasets)

    # get list of authorname and doi
    names = [split(split(first(i[:authors]),",")[1]," ")[1] for i in published_datasets]
    dois = [i[:global_id] for i in published_datasets]
    sizes = [i[:size_mb] for i in published_datasets]
    
    d = DataFrame(name = names,doi = dois,sizeMB = sizes)
    sort!(d,:sizeMB,rev = true)
    CSV.write(joinpath(@__DIR__,"..","published.csv"),d)
    d

    
    
end

function dv_filter_recent_datasets(datasets::Vector{Any}; days_ago::Int=90)
    cutoff_date = Dates.today() - Day(days_ago)

    recent_items = []
    
    for dataset in datasets
        date_str = get(dataset, "updatedAt", nothing)
        if date_str === nothing
            println("Missing 'updatedAt' field for dataset: ", dataset["name"])  # Debugging line
            continue
        end

        # Remove 'Z' if present (Zulu time/UTC)
        date_str = replace(date_str, "Z" => "")

        # Try parsing the timestamp
        date_obj = tryparse(DateTime, date_str, dateformat"yyyy-mm-ddTHH:MM:SS")

        if date_obj === nothing
            println("Failed to parse 'updatedAt' for dataset: ", dataset["name"], " (", date_str, ")")  # Debugging line
            continue
        end

        # Compare the parsed date to the cutoff
        if Date(date_obj) >= cutoff_date
            push!(recent_items, dataset)
        end
    end

    return recent_items
end


function dv_get_dataset_by_doi(doi::String, token::String)
    # Dataverse API URL for retrieving a dataset by its DOI
    url = "$(dvserver())/api/datasets/:persistentId?persistentId=$(doi)"

    # Set the access token in the headers
    headers = Dict("X-Dataverse-key" => token)

    # Send the GET request to fetch the dataset
    response = HTTP.get(url, headers)

    # Parse the JSON response
    dataset = JSON.read(response.body)

    # Return the dataset (or nothing if not found)
    return dataset["data"]  # Dataset details
end

dv_doi_from_url(url) = replace(url, "https://doi.org/" => "doi:")

"get an entire dataset from dv"
function dv_download_dataset(doi_or_url::String)

    persistent_id = dv_doi_from_url(doi_or_url)
    println(persistent_id)

    haskey(ENV,"JPE_DV") || error("You must set ENV var JPE_DV")

    dest = joinpath((root()), "replication-package" )

    # Construct the request URL
    url = "$(dvserver())/api/access/dataset/:persistentId/?persistentId=$(persistent_id)"
    
    # Set the request headers with the Dataverse API key
    headers = Dict("X-Dataverse-key" => ENV["JPE_DV"])
    
    # Send the GET request to the API
    # d = download(url, headers = headers, output = )
    response = HTTP.get(url, headers)
    
    # Handle the response (assuming the dataset is available for download)
    if response.status == 200
        @info "Dataset downloaded successfully."
        # Optionally, save the content to a file
        filename = "dataset_download.zip"  # Adjust this based on the file type you're downloading
        open(filename, "w") do f
            write(f, response.body)
        end
        @info "Dataset saved to: $filename"
        # Now unzip the file if it is a .zip file
        run(`unzip $filename -d $dest`)
        rm(filename)

    else
        @warn "Failed to fetch dataset. Status code: ", response.status
    end
end





# for large datasets, need to download each file one by one.

function dv_get_versions(doi)
    url = "$(dvserver())/api/datasets/:persistentId/versions?persistentId=$(doi)"
    headers = Dict("X-Dataverse-key" => dvtoken())
    response = HTTP.get(url, headers)
    result = JSON.read(response.body, Dict)
    
    if result["status"] == "OK"
        return result["data"]
    else
        error("API error: $(result["message"])")
    end

end

"get list of all files in a dataset"
function dv_get_dataset_files(persistent_id::String)
    url = "$(dvserver())/api/datasets/:persistentId/versions/:latest/files?persistentId=$(persistent_id)"
    headers = Dict("X-Dataverse-key" => dvtoken())
    response = HTTP.get(url, headers)
    result = JSON.read(response.body, Dict)
    
    if result["status"] == "OK"
        return result["data"]
    else
        error("API error: $(result["message"])")
    end
end

function dv_download_file(file_id::Int, file_name::String)
    url = "$(dvserver())/api/access/datafile/$(file_id)"
    headers = Dict("X-Dataverse-key" => dvtoken())
    
    # Send the GET request to download the file
    response = HTTP.get(url, headers)

    if response.status == 200
        open(file_name, "w") do f
            write(f, response.body)
        end
        println("Downloaded file: ", file_name)
    else
        println("Failed to download file with ID $(file_id). Status code: ", response.status)
    end
end

# Main function to download all files in a dataset
function download_dataset_files(api_token::String, server_url::String, persistent_id::String)
    files = dv_get_dataset_files(persistent_id)
    
    for file in files
        file_id = file["dataFile"]["id"]
        file_name = file["dataFile"]["filename"]
        dv_download_file(file_id, file_name)
    end
end

# ─────────────────────────────────────────────────────────────────────────
# Downloads/citations report: matches JPE replication packages on Dataverse
# to their journal article (via Crossref) to compare package downloads
# against article citations, x-axis = time since article publication.
# ─────────────────────────────────────────────────────────────────────────

"""
    dv_downloads_total(package_doi; retries = 4)

Cumulative download count for a dataverse dataset (Make Data Count). Harvard
Dataverse's load balancer throttles rapid back-to-back requests with a bare
403 (no Retry-After header), so this retries with exponential backoff.
"""
function dv_downloads_total(package_doi::AbstractString; retries::Int = 4)
    url = "$(dvserver())/api/datasets/:persistentId/makeDataCount/downloadsTotal?persistentId=$(package_doi)"
    headers = Dict("X-Dataverse-key" => dvtoken())
    for attempt in 1:retries
        try
            response = HTTP.get(url, headers)
            result = JSON.parse(String(response.body))
            return result["data"]["downloadsTotal"]
        catch e
            attempt == retries && rethrow(e)
            sleep(2.0 * attempt)
        end
    end
end

"citation count for a journal article DOI, via OpenAlex"
function openalex_citations(article_doi::AbstractString)
    url = "https://api.openalex.org/works/https://doi.org/$(article_doi)?mailto=jpe.dataeditor@gmail.com"
    response = HTTP.get(url)
    result = JSON.parse(String(response.body))
    result["cited_by_count"]
end

"""
    crossref_pub_date(doi)

Single-DOI Crossref lookup for a reliable publication date. Only used as a
fallback when the DOI isn't already in the bulk-fetched `dv_jpe_journal_articles`
table — OpenAlex's own `publication_date` field has been observed to be wrong
(e.g. reporting 2009 for an article Crossref correctly dates to 2023-12-01),
so Crossref is the trusted source for dates here, not OpenAlex.
"""
function crossref_pub_date(doi::AbstractString)
    url = "https://api.crossref.org/works/$(doi)"
    response = HTTP.get(url)
    result = JSON.parse(String(response.body))
    parts = get(get(result["message"], "published", Dict()), "date-parts", [[nothing]])[1]
    isnothing(parts[1]) && return missing
    y = parts[1]
    m = length(parts) >= 2 ? parts[2] : 1
    d = length(parts) >= 3 ? parts[3] : 1
    Date(y, m, d)
end

"regex-extract a journal article DOI from a dataverse dataset's own `publications` metadata, if present"
function dv_extract_article_doi(item::Dict)
    pubs = get(item, "publications", nothing)
    (isnothing(pubs) || isempty(pubs)) && return missing
    citation = get(pubs[1], "citation", "")
    m = match(r"doi\.org/(10\.\d{4,}[^\s\"]+)", citation)
    isnothing(m) ? missing : rstrip(m.captures[1], ['.', ')', ']', '"'])
end

"""
    dv_jpe_journal_articles(; since = Date(2020,1,1))

Pull the full JPE journal table of contents from Crossref (ISSN 0022-3808),
filtered to real articles (drops Front Matter / Recent Referees noise, which
carry no author list).
"""
function dv_jpe_journal_articles(; since::Date = Date(2020, 1, 1))
    issn = "0022-3808"
    url = "https://api.crossref.org/journals/$(issn)/works?filter=from-pub-date:$(since),type:journal-article&rows=1000&select=DOI,title,published,author"
    response = HTTP.get(url)
    result = JSON.parse(String(response.body))
    items = result["message"]["items"]

    rows = NamedTuple[]
    for it in items
        authors = get(it, "author", [])
        isempty(authors) && continue
        title = get(it, "title", [""])
        isempty(title) && continue
        parts = get(get(it, "published", Dict()), "date-parts", [[nothing]])[1]
        isnothing(parts[1]) && continue
        y = parts[1]
        m = length(parts) >= 2 ? parts[2] : 1
        d = length(parts) >= 3 ? parts[3] : 1
        push!(rows, (
            doi = it["DOI"],
            title = title[1],
            pub_date = Date(y, m, d),
            authors = [lowercase(get(a, "family", "")) for a in authors]
        ))
    end
    DataFrame(rows)
end

"extract surname from an author name, handling both \"Last, First\" and \"First Last\" formats"
function _surname(a::AbstractString)
    a = strip(a)
    parts = split(a, ",")
    surname = length(parts) > 1 ? parts[1] : split(a)[end]
    lowercase(strip(surname))
end

"normalize a title for fuzzy matching: lowercase, strip accents/punctuation, token set"
function _title_tokens(s::AbstractString)
    s = Unicode.normalize(lowercase(s), stripmark = true)
    s = replace(s, r"[^a-z0-9\s]" => " ")
    Set(split(s))
end

"""
    dv_match_article(item::Dict, articles::DataFrame)

Identify which journal article a dataverse dataset belongs to: try the
dataset's own linked-publication field first, then fall back to fuzzy
title/author matching against the Crossref JPE table of contents (needed
because at posting time `item["publications"]` is usually still empty — the
paper is only "forthcoming").
"""
function dv_match_article(item::Dict, articles::DataFrame)
    direct = dv_extract_article_doi(item)
    !ismissing(direct) && return direct

    dataset_title = replace(item["name"], r"^Replication (Data|Code|Codes)( and Instructions)? for:?\s*"i => "")
    dataset_title = strip(dataset_title, ['"', '“', '”', ' '])
    dtoks = _title_tokens(dataset_title)
    isempty(dtoks) && return missing

    dataset_surnames = Set(_surname(a) for a in get(item, "authors", []))

    best_doi, best_score = missing, 0.0
    for r in eachrow(articles)
        isempty(intersect(dataset_surnames, Set(r.authors))) && continue
        atoks = _title_tokens(r.title)
        isempty(atoks) && continue
        score = length(intersect(dtoks, atoks)) / min(length(dtoks), length(atoks))
        if score > best_score
            best_score, best_doi = score, r.doi
        end
    end

    best_score >= 0.6 ? best_doi : missing
end

"""
    dv_metrics_report(; write_csv = true, out_dir = joinpath(homedir(), "git", "jpe", "Reports", "data"))

Build the downloads-vs-citations dataset for the bi-annual report: every
published JPE dataverse package, matched to its journal article (Crossref),
with cumulative downloads (Dataverse Make Data Count) and citations
(OpenAlex), plus the article's publication date to anchor "time since
publication" on the x-axis.
"""
function dv_metrics_report(; write_csv = true, out_dir = joinpath(homedir(), "git", "jpe", "Reports", "data"))
    @info "fetching all JPE datasets from dataverse..."
    all_datasets = dv_fetch_all_datasets(subtree = "JPE", include_size = false)
    published = dv_filter_published_datasets(all_datasets)
    @info "$(length(published)) published datasets found"

    @info "fetching JPE journal table of contents from Crossref..."
    articles = dv_jpe_journal_articles()
    @info "$(nrow(articles)) journal articles found"
    pub_dates = Dict(String(r.doi) => r.pub_date for r in eachrow(articles))

    rows = NamedTuple[]
    n_unmatched = 0
    for item in published
        package_doi = item["global_id"]
        article_doi = dv_match_article(item, articles)
        if ismissing(article_doi)
            n_unmatched += 1
            continue
        end
        article_doi = String(article_doi)

        downloads = try
            dv_downloads_total(package_doi)
        catch e
            @warn "downloads fetch failed for $package_doi" exception=e
            missing
        end
        sleep(0.3)

        citations = try
            openalex_citations(article_doi)
        catch e
            @warn "OpenAlex fetch failed for $article_doi" exception=e
            missing
        end

        pub_date = get(pub_dates, article_doi) do
            try
                crossref_pub_date(article_doi)
            catch e
                @warn "Crossref pub date fetch failed for $article_doi" exception=e
                missing
            end
        end

        push!(rows, (
            package_doi = package_doi,
            article_doi = article_doi,
            downloads = downloads,
            citations = citations,
            article_pub_date = pub_date
        ))
    end

    df = DataFrame(rows)
    @info "$(nrow(df)) datasets matched to an article, $n_unmatched unmatched"

    if write_csv
        mkpath(out_dir)
        path = joinpath(out_dir, "dataverse_metrics_$(Dates.format(today(), "yyyy-mm-dd")).csv")
        CSV.write(path, df)
        @info "wrote $path"
    end

    df
end

# z =JPE.dv_get_dataset_metadata("doi:10.7910/DVN/VXR3XB")



# Read your API token
# token = ENV["JPE_DV"]
# doi = "doi:10.7910/DVN/78W8M6"

# dataset = get_dataset_by_doi(doi, token)
# doi = "doi:10.7910/DVN/FJZVDK"