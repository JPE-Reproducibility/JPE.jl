
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
- `exclude::Vector{String}`: relative paths (from the zip root) to skip during
  extraction, e.g. `["PackageName/confidential-data-do-not-publish"]`. Each is
  passed to `unzip -x` as `"<path>/*"`. Has no effect when the zip was already
  extracted by a prior run — `local_file_md5s` is what guards against that case.

# Returns
- `Vector{String}`: All file paths in the directory (after unzipping)
"""
function read_and_unzip_directory(dir_path::String; rm_zip = true, exclude::Vector{String} = String[])
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

    exclude_patterns = [rstrip(e, '/') * "/*" for e in exclude]

    # Unzip each zip file
    for zip_file in zip_files
        println("Unzipping: $(basename(zip_file))")

        # Run system unzip command
        # -o: overwrite files without prompting
        # -d: extract to directory (same as zip file location)
        # -x: exclude matching entries (only passed when non-empty; unzip errors on a bare -x)
        extract_dir = joinpath(dirname(dirname(zip_file)), "replication-package")
        if isempty(exclude_patterns)
            run(pipeline(`unzip -oq $zip_file -d $extract_dir`, devnull))
        else
            @info "Excluding from extraction: $(exclude)"
            run(pipeline(`unzip -oq $zip_file -d $extract_dir -x $exclude_patterns`, devnull))
        end

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

"""
    zip_entry_sizes(zip_path::String)

List every entry in `zip_path` via `unzip -l` without extracting anything.
Parses between the two `----`-style separator lines that bound the listing
(unzip's date/time column format is not stable across builds, so this reads
size from field 1 and treats everything after field 3 as the name — the only
way to survive names containing spaces).

# Returns
- `Vector{@NamedTuple{size::Int, path::String}}`: byte size and archive-relative
  path for every entry (directories included, at size 0).
"""
function zip_entry_sizes(zip_path::String)
    out = read(`unzip -l $zip_path`, String)
    lines = split(out, '\n')

    sep_idxs = findall(l -> occursin(r"^-+\s+-+", l), lines)
    length(sep_idxs) < 2 && error("zip_entry_sizes: could not parse `unzip -l` output for $zip_path")

    entries = @NamedTuple{size::Int, path::String}[]
    for line in lines[(sep_idxs[1]+1):(sep_idxs[2]-1)]
        isempty(strip(line)) && continue
        fields = split(line)
        length(fields) < 4 && continue
        sz = tryparse(Int, fields[1])
        isnothing(sz) && continue
        # name is everything after the first 3 whitespace-delimited fields (size, date, time)
        name = strip(line)
        for _ in 1:3
            name = lstrip(name)
            sp = findfirst(isspace, name)
            isnothing(sp) && break
            name = name[nextind(name, sp-1)+1:end]
        end
        push!(entries, (size = sz, path = strip(name)))
    end
    entries
end

"""
    aggregate_dir_sizes(entries; threshold_gb = 1.0)

Pure function (no shell-out) computing cumulative size for every directory
prefix implied by `entries` (as returned by [`zip_entry_sizes`](@ref) or an
equivalent on-disk listing), and flagging those at or above `threshold_gb`.

Suppresses a flagged directory when a flagged descendant already accounts for
essentially the same bytes (ratio > 0.98) — so a single wrapper directory that
contains the whole archive doesn't drown out the specific buried folder that
is actually large.

# Returns
- `Vector{@NamedTuple{path::String, size_gb::Float64}}`, largest first.
"""
function aggregate_dir_sizes(entries; threshold_gb::Real = 1.0)
    totals = Dict{String, Int}()
    for e in entries
        parts = splitpath(e.path)
        # every proper ancestor directory of this entry accrues its bytes
        for depth in 1:(length(parts) - 1)
            dir = joinpath(parts[1:depth]...)
            totals[dir] = get(totals, dir, 0) + e.size
        end
    end

    threshold_bytes = threshold_gb * 1024^3
    flagged = [dir for (dir, sz) in totals if sz >= threshold_bytes]

    # drop an ancestor if some flagged descendant already carries ~all its bytes
    keep = String[]
    for dir in flagged
        has_dominant_descendant = any(flagged) do other
            other != dir &&
            startswith(other, dir * "/") &&
            totals[other] / totals[dir] > 0.98
        end
        has_dominant_descendant || push!(keep, dir)
    end

    result = [(path = dir, size_gb = totals[dir] / 1024^3) for dir in keep]
    sort(result, by = r -> r.size_gb, rev = true)
end

"""
    dir_sizes_on_disk(root::String; threshold_gb = 1.0)

Like [`aggregate_dir_sizes`](@ref) but for a package that is already unzipped
on disk (no zip file present — either delivered that way or left over from a
prior run) — walks `root` with `walkdir`/`filesize` instead of shelling out to
`unzip -l`.
"""
function dir_sizes_on_disk(root::String; threshold_gb::Real = 1.0)
    entries = @NamedTuple{size::Int, path::String}[]
    for (dirpath, _, files) in walkdir(root)
        for file in files
            fullpath = joinpath(dirpath, file)
            sz = try
                filesize(fullpath)
            catch
                0
            end
            push!(entries, (size = sz, path = relpath(fullpath, root)))
        end
    end
    aggregate_dir_sizes(entries; threshold_gb = threshold_gb)
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