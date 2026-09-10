
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
    free_disk_space_gb(path::String)

Available disk space (GB) on the filesystem containing `path`, via `df -Pk`.
"""
function free_disk_space_gb(path::String)
    out = read(`df -Pk $path`, String)
    lines = split(strip(out), '\n')
    length(lines) < 2 && error("free_disk_space_gb: unexpected `df` output for $path")
    fields = split(lines[2])
    length(fields) < 4 && error("free_disk_space_gb: could not parse `df` output for $path")
    avail_kb = parse(Int, fields[4])
    avail_kb / 1024^2
end

"pure/testable: is `avail_gb` enough to extract something needing `needed_gb`, with a safety margin?"
_enough_scratch_space(needed_gb::Real, avail_gb::Real; margin::Real = 1.05) = avail_gb >= needed_gb * margin

"""
    zip_extract_to_scratch(zip_path::String; exclude = String[])

Extract `zip_path` in full to a fresh local scratch directory using `ditto`,
then immediately delete any `exclude`d paths (relative to the archive root)
before returning — excluded content is never hashed and sits on disk only for
the duration of the extraction itself.

`ditto` is used instead of `unzip` because Apple's bundled UnZip 6.00 cannot
write filenames containing legacy (non-UTF8, e.g. CP850) byte sequences and
aborts the *entire archive* rather than skipping the offending entry —
confirmed against a real replication package where two accented-Spanish
filenames caused `unzip` to fail with a misleading "disk full?" prompt on a
machine that had 259GB genuinely free. `ditto` writes these files fine (it
just displays the accented characters differently, which doesn't matter —
file *content*, not display name, is what gets hashed).

`ditto` has no exclude mechanism, which is why everything is extracted before
trimming: this needs enough LOCAL scratch disk for the archive's full
uncompressed size even when most of it will be deleted immediately after —
checked up front against `free_disk_space_gb` so a huge confidential-only
folder can't run the disk out of space here either.

# Returns
- `String`: path to the scratch directory. Caller owns cleanup, e.g.
  `rm(scratch; recursive=true, force=true)`.
"""
function zip_extract_to_scratch(zip_path::String; exclude::Vector{String} = String[])
    needed_gb = sum(e.size for e in zip_entry_sizes(zip_path)) / 1024^3

    scratch = mktempdir()
    avail_gb = free_disk_space_gb(scratch)
    if !_enough_scratch_space(needed_gb, avail_gb)
        rm(scratch, recursive = true, force = true)
        error("zip_extract_to_scratch: need ~$(round(needed_gb, digits=2)) GB of local scratch disk to extract $zip_path, only $(round(avail_gb, digits=2)) GB free. Free up disk space before retrying.")
    end

    println("Extracting (via ditto): $(basename(zip_path))")
    run(pipeline(`ditto -x -k $zip_path $scratch`, devnull))

    rm_git(scratch)

    for e in exclude
        target = joinpath(scratch, e)
        if ispath(target)
            @info "Deleting excluded folder from scratch extraction: $e"
            rm(target, recursive = true, force = true)
        end
    end

    scratch
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