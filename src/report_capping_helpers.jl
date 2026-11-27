# report_capping_helpers.jl -- shared between JPE.jl (included into the module,
# so directly testable as JPE.foo(...)) and runner_precheck.jl (spliced in
# verbatim as text by write_runner_script, since that script runs standalone
# in the paper repo's own Julia env -- same dual-use pattern as
# claims_runner_helpers.jl / crosscheck_runner_helpers.jl).
#
# PackageScanner.jl writes several checks as a report-<check>.md (short,
# included in the compiled report via Quarto) + report-<check>-appendix.md
# (full detail, never included) pair -- see e.g. write_pii_report in
# PackageScanner.jl's reporting.jl. Nothing short of this routes the
# appendix file anywhere the author can reach it. This file generalizes that:
# any *-appendix.md is always routed to Dropbox large-reports/ regardless of
# size, and any main report-*.md over DEFAULT_REPORT_MAX_LINES is truncated
# the same way, so no overflow content ever ends up embedded in the compiled
# report.

const DEFAULT_REPORT_MAX_LINES = 20
const DEFAULT_REPORT_MAX_BYTES = 5 * 1024 * 1024

"""
    REPORTS_NEVER_CAPPED

Filenames `cap_and_route_reports!` must never touch, even if `preprocess()`
runs again later and re-sweeps `generated/`. These are produced by Stage
C/D/R and the replicator checklist -- none of them are ever
`{{< include >}}`'d into the compiled Quarto report (only PackageScanner's
own checks are, e.g. `report-pii.md`), so there's no compiled-report-size
reason to cap them, and each already has its own deliberate full-content
design (full copy in the repo, sometimes also mirrored to Dropbox by its
own code path -- see `review_paper_readme`, `build_replicator_checklist`).
Before this existed, a `preprocess()` re-run after Stage C/D/R had already
produced these files would blindly truncate them to
`DEFAULT_REPORT_MAX_LINES` lines on its next "commit and push results" step,
discarding content those stages specifically chose not to cap.
"""
const REPORTS_NEVER_CAPPED = Set([
    "report-crosscheck.md",
    "report-readme-review.md",
    "report-replicator-checklist.md",
])

"""
    url_encode_path(s::AbstractString) -> String

Percent-encode `s` for use as a URL query value, leaving `/` unescaped (it's
a path separator within the value, not a query delimiter). No external
dependency (no HTTP.jl/URIs.jl) since this file is spliced verbatim into the
generated runner script, which doesn't load those.
"""
function url_encode_path(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(s)
        if (b >= UInt8('A') && b <= UInt8('Z')) || (b >= UInt8('a') && b <= UInt8('z')) ||
           (b >= UInt8('0') && b <= UInt8('9')) || b in (UInt8('-'), UInt8('_'), UInt8('.'), UInt8('~'), UInt8('/'))
            write(io, Char(b))
        else
            print(io, "%", uppercase(string(b, base=16, pad=2)))
        end
    end
    return String(take!(io))
end

"""
    dbox_folder_file_link(folder_url::AbstractString, relative_path::AbstractString) -> String

One Dropbox shared-folder link (`large_reports_url`, minted once per paper
round) covers every report routed into that folder -- no need to mint a
separate per-file shared link (hundreds of API calls/round for a paper with
many appendices). Dropbox's folder-link web viewer supports a `preview=`
query param that deep-links straight to a specific file inside the shared
folder, so this just appends that rather than handing the author the bare
folder link and making them hunt for the right file.
"""
function dbox_folder_file_link(folder_url::AbstractString, relative_path::AbstractString)
    sep = occursin('?', folder_url) ? "&" : "?"
    return "$folder_url$(sep)preview=$(url_encode_path(relative_path))"
end

"""
    is_appendix_file(path) -> Bool

True for any `*-appendix.md` file, PackageScanner.jl's own naming convention
for the full-detail companion to a short `report-<check>.md`.
"""
is_appendix_file(path::AbstractString) = occursin(r"-appendix\.md$", basename(path))

"""
    cap_report_file!(path, dest_dir, large_reports_url;
                      max_lines=DEFAULT_REPORT_MAX_LINES,
                      max_bytes=DEFAULT_REPORT_MAX_BYTES) -> Union{String,Nothing}

Route `path` to `dest_dir` (a local Dropbox-synced folder) and overwrite it
in place with a short pointer note, when either:
- it's an appendix file (`is_appendix_file`) -- unconditional, any size; or
- it's a main report file over `max_lines` lines or `max_bytes` bytes.

The pointer note links to this specific file via `dbox_folder_file_link`,
not the bare `large_reports_url` -- one shared folder link covers every
routed file this way, no per-file Dropbox API call needed.

Returns `basename(path)` if routed, else `nothing` (file left untouched).
"""
function cap_report_file!(path::AbstractString, dest_dir::AbstractString, large_reports_url::AbstractString;
                           max_lines::Int=DEFAULT_REPORT_MAX_LINES,
                           max_bytes::Int=DEFAULT_REPORT_MAX_BYTES)
    isfile(path) || return nothing
    fname = basename(path)
    appendix = is_appendix_file(path)
    lines = countlines(path)
    sz = filesize(path)

    appendix || (lines > max_lines || sz > max_bytes) || return nothing

    mkpath(dest_dir)
    cp(path, joinpath(dest_dir, fname); force=true)
    size_mb = round(sz / 1024^2, digits=1)
    file_link = dbox_folder_file_link(large_reports_url, fname)

    if appendix
        open(path, "w") do io
            println(io, "> **Note**: This appendix ($lines lines, $size_mb MB) is not included in the compiled report.")
            println(io, "> The full version is available here: <$file_link>")
        end
    else
        kept = readlines(path)[1:min(max_lines, lines)]
        open(path, "w") do io
            for l in kept
                println(io, l)
            end
            println(io)
            println(io, "> **Note**: This list contains $lines entries ($size_mb MB) — too large to embed in the report.")
            println(io, "> The full list is available here: <$file_link>")
        end
    end
    return fname
end

"""
    rewrite_appendix_links!(gen_dir, routed_basenames, large_reports_url)

After routing, any remaining `generated/*.md` file may still contain a
markdown link literally naming a routed file, e.g.
`[Appendix](report-pii-appendix.md)` -- dead for the author, since they have
no repo access. Rewrite every such reference to a `dbox_folder_file_link`
deep link into the shared `large_reports_url` folder instead, so it's a live
link in the compiled report, and lands the author on that specific file.
"""
function rewrite_appendix_links!(gen_dir::AbstractString, routed_basenames, large_reports_url::AbstractString)
    for f in readdir(gen_dir; join=true)
        (isfile(f) && endswith(f, ".md")) || continue
        content = read(f, String)
        new_content = content
        for fname in routed_basenames
            new_content = replace(new_content, "($fname)" => "(<$(dbox_folder_file_link(large_reports_url, fname))>)")
        end
        new_content == content || write(f, new_content)
    end
end

"""
    cap_and_route_reports!(gen_dir, dest_dir, large_reports_url;
                            max_lines=DEFAULT_REPORT_MAX_LINES,
                            max_bytes=DEFAULT_REPORT_MAX_BYTES)

Orchestrator: routes every oversized or appendix `generated/*.md` file to
`dest_dir` (see `cap_report_file!`), then rewrites any surviving in-text
references to those files into live Dropbox links (see
`rewrite_appendix_links!`). Skips anything in `REPORTS_NEVER_CAPPED`.
"""
function cap_and_route_reports!(gen_dir::AbstractString, dest_dir::AbstractString, large_reports_url::AbstractString;
                                 max_lines::Int=DEFAULT_REPORT_MAX_LINES,
                                 max_bytes::Int=DEFAULT_REPORT_MAX_BYTES)
    isdir(gen_dir) || return String[]
    routed = String[]
    for f in readdir(gen_dir; join=true)
        (isfile(f) && endswith(f, ".md")) || continue
        basename(f) in REPORTS_NEVER_CAPPED && continue
        fname = cap_report_file!(f, dest_dir, large_reports_url; max_lines=max_lines, max_bytes=max_bytes)
        isnothing(fname) || push!(routed, fname)
    end
    isempty(routed) || rewrite_appendix_links!(gen_dir, routed, large_reports_url)
    return routed
end
