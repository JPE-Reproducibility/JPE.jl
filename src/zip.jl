
function disk_size_gb(path::String)
    if isfile(path)
        # For a file, just return its size
        return filesize(path)
    elseif isdir(path)
        # For a directory, sum all file sizes recursively
        total = 0
        for (root, dirs, files) in walkdir(path)
            for file in files
                filepath = joinpath(root, file)
                try
                    total += filesize(filepath)
                catch e
                    @warn "Could not get size of file" filepath exception=e
                end
            end
        end
        return total / 1024^3
    else
        error("Path does not exist: $path")
    end
end



"""
    read_and_unzip_directory(dir_path::String)

Read contents of a directory and unzip any .zip files using system unzip command.
Extracts zip files to the same directory where they reside.

# Arguments
- `dir_path::String`: Path to the directory to read

# Returns
- `Vector{String}`: All file paths in the directory (after unzipping)
"""
function read_and_unzip_directory(dir_path::String; rm_zip = true)
    # Check if directory exists
    if !isdir(dir_path)
        throw(ArgumentError("Directory does not exist: $dir_path"))
    end
    
    # Get all files in directory
    files = filter(isfile, readdir(dir_path, join=true))
    
    # Find zip files
    zip_files = filter(f -> endswith(lowercase(f), ".zip"), files)

    if length(zip_files) == 0
        @warn "There are no zip files in this location."

    end
    
    # Unzip each zip file
    for zip_file in zip_files
        println("Unzipping: $(basename(zip_file))")
        
        # Run system unzip command
        # -o: overwrite files without prompting
        # -d: extract to directory (same as zip file location)
        extract_dir = joinpath(dirname(dirname(zip_file)), "replication-package")
        run(pipeline(`unzip -oq $zip_file -d $extract_dir`, devnull))
        
        # Remove any .git directories from extracted contents
        if isdir(extract_dir)
            rm_git(extract_dir)
        end
    end

    if rm_zip
        rm.(zip_files, force = true)
    end


    
    # Return all files in directory after unzipping
    return filter(isfile, readdir(dir_path, join=true))
end

"""
    browse_package_contents(path::String)

Display the contents of a replication package (directory or zip archive) sorted
by file size descending, with sizes in GB, paginated through `less`.

- If `path` is a `.zip` file: runs `unzip -l | sort -k1 -rn | awk (→GB) | less`
- If `path` is a directory containing exactly one `.zip`: same as above on that zip
- Otherwise: runs `du -ak path | sort -rn | awk (→GB) | less` for a plain directory tree

Intended to be called interactively when a package exceeds `max_pkg_size_gb`.
"""
function browse_package_contents(path::String)
    # awk programs stored as raw strings to prevent Julia from interpolating $1, $2, etc.
    # unzip -l columns: bytes  date  time  name  — convert bytes→GB for data lines only.
    # Use sub() to strip the first three fields so the full path (including spaces) is preserved.
    unzip_awk = raw"""/^[[:space:]]*[0-9]/ && NF>=4 {sz=$1; dt=$2; tm=$3; name=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9-]+[[:space:]]+[0-9:]+[[:space:]]+/,"",name); printf "%10.4f GB  %s %s   %s\n", sz/1073741824, dt, tm, name; next} {print}"""
    # du -ak columns: KB  path — strip leading "KB<whitespace>" so the full path is preserved.
    du_awk    = raw"""{sz=$1; sub(/^[0-9]+[[:space:]]+/,"",$0); printf "%10.4f GB\t%s\n", sz/1048576, $0}"""

    if isfile(path) && endswith(lowercase(path), ".zip")
        run(pipeline(`unzip -l $path`, `sort -k1 -rn`, `awk $unzip_awk`, `less`))
    elseif isdir(path)
        zips = filter(f -> isfile(f) && endswith(lowercase(f), ".zip"),
                      readdir(path, join = true))
        if length(zips) == 1
            run(pipeline(`unzip -l $(zips[1])`, `sort -k1 -rn`, `awk $unzip_awk`, `less`))
        else
            run(pipeline(`du -ak $path`, `sort -rn`, `awk $du_awk`, `less`))
        end
    else
        error("browse_package_contents: not a directory or .zip file: $path")
    end
end

function rm_git(extract_dir)
    for (root, dirs, files) in walkdir(extract_dir)
        if ".git" in dirs
            git_path = joinpath(root, ".git")
            @info "Removing git repository: $git_path"
            rm(git_path, recursive=true, force=true)
            # Remove from dirs to prevent walkdir from trying to enter it
            filter!(d -> d != ".git", dirs)
            # stop immediately after deleting the .git
            return 0
        end
    end
end