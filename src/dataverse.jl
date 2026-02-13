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
        4. files existing only on dev: $(length(nt.only_dv))
        """
        println("want to see?")
        yes_no_menu = RadioMenu(["no (n)","fully matched (f)","md5 matches, not name (r)","only local (missing on dv) (m)","only dv (missing local) (l)","exit (e)"],keybindings = ['n','f','r','m','l','e'])  # Default is first option 
        answer = request(yes_no_menu)
        if answer == 1
            # nothing
        elseif answer == 2
            println(nt.matched)
        elseif answer == 3
            println(nt.hash_match_name_mismatch)
        elseif answer == 4
            println(nt.only_local)
        elseif answer == 5
            println(nt.only_dv)
        end
    end
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

        data = JSON.read(response.body)
        items = data["data"]["items"]
        return items
        
        
        if isempty(items) 
            # finish!(prog)
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

# z =JPE.dv_get_dataset_metadata("doi:10.7910/DVN/VXR3XB")



# Read your API token
# token = ENV["JPE_DV"]
# doi = "doi:10.7910/DVN/78W8M6"

# dataset = get_dataset_by_doi(doi, token)
# doi = "doi:10.7910/DVN/FJZVDK"