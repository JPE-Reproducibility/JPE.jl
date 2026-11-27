
# Stage R: DE-triggered manual entry point for the LLM README review (see
# readme_review_runner_helpers.jl for the `claude -p` call itself and why it
# isn't folded into preprocess()'s automatic runner script). Mirrors
# `run_paper_crosscheck` in crosscheck.jl: pulls the repo fresh via
# `gh_pull`, writes its report into the repo's own `generated/` folder, does
# NOT auto-commit/push (a human reviews a review before it goes anywhere).

"""
    README_FORMAT_PRIORITY

Preference order when more than one README format exists under the same
replication package: markdown is the most LLM-friendly (no extraction
needed, preserves tables/headers losslessly), plain text needs no
extraction either but loses markdown structure, PDF needs a lossy text
extraction pass (see `extract_paper_pdf_text`) before it can be reviewed.
"""
const README_FORMAT_PRIORITY = [:md => ".md", :txt => ".txt", :pdf => ".pdf"]

"""
    find_readme_in_dir(dir::String) -> Union{Tuple{String,Symbol},Nothing}

Find the author's replication-package README under `dir`. Walks the tree
for any file named `README` (case-insensitive), skipping `__MACOSX` junk,
and returns `(path, format)` for the highest-priority format present (see
`README_FORMAT_PRIORITY`: `.md` over `.txt` over `.pdf`) -- ties within a
format broken by sorted path, for determinism. Returns `nothing` if no
README of any of these three formats exists.
"""
function find_readme_in_dir(dir::String)
    isdir(dir) || return nothing
    candidates = Dict{Symbol,Vector{String}}(:md => String[], :txt => String[], :pdf => String[])
    for (root, _, files) in walkdir(dir)
        occursin("__MACOSX", root) && continue
        for f in files
            occursin(r"^readme"i, f) || continue
            lf = lowercase(f)
            for (kind, ext) in README_FORMAT_PRIORITY
                endswith(lf, ext) && push!(candidates[kind], joinpath(root, f))
            end
        end
    end
    for (kind, _) in README_FORMAT_PRIORITY
        isempty(candidates[kind]) || return (sort(candidates[kind])[1], kind)
    end
    return nothing
end

"""
    readme_review_source_text_path(readme_path::String, kind::Symbol) -> String

Returns a path `run_claude_readme_review` can point `claude`'s `Read` tool
at. For `:md`/`:txt`, that's just `readme_path` unchanged. For `:pdf`,
extracts the text first via `extract_paper_pdf_text` (the same
PackageScanner-backed PDF fallback Stage C uses for the paper itself) and
writes it to a temp `.txt` file -- `claude`'s `Read` tool is not asked to
parse PDF bytes directly, consistent with how this codebase always goes
through an explicit extraction step for PDFs rather than relying on the
model's own document-reading capability.
"""
function readme_review_source_text_path(readme_path::String, kind::Symbol)
    kind in (:md, :txt) && return readme_path
    pdf_result = extract_paper_pdf_text(readme_path)
    text_path = tempname() * ".txt"
    write(text_path, pdf_result.text)
    return text_path
end

"""
    review_paper_readme(paperID; round = nothing, force = false)

Stage R: run the LLM README review (see readme_review_runner_helpers.jl) and
write `report-readme-review.md` into the paper's `generated/` folder.

Pulls the paper's repo fresh via `gh_pull` (same convention as
`run_paper_crosscheck`), finds the author's README under
`replication-package/` in whichever of `.md`/`.txt`/`.pdf` is available
(see `find_readme_in_dir`), and errors if none is found rather than
silently skipping -- this is a DE-triggered call, not an unattended one, so
a missing README is worth surfacing immediately rather than a report that
quietly says "skipped".

If `report-readme-review.md` already exists and `force = false`, returns
its cached content without re-running the (paid) `claude` call.

Logs `claude`'s reported token usage alongside cost, so repeated runs make
the actual cost/verbosity tradeoff of `effort="high"` visible rather than
just a single opaque dollar figure.

Writes the FULL review to both `generated/report-readme-review.md` (so
Stage D's crosscheck bundle, see `run_paper_crosscheck`, can actually read
it rather than a truncated pointer note) and the paper's Dropbox
`large-reports/` folder (so it can be linked to the author directly,
without touching the repo) -- NOT routed through `cap_report_file!`'s
truncate-and-link behavior like PackageScanner's own checks: unlike those,
`report-readme-review.md` is never `{{< include >}}`'d into the compiled
Quarto report, so there is no compiled-report-size reason to cap it.
Mirrors `refine_check_referee_reviews`'s pattern (another qualitative LLM
review report, same "full copy in both places" shape) more closely than
`cap_and_route_reports!`'s.

Also writes `generated/README-ai-edited.md` (and its own Dropbox copy)
alongside the review -- the rubric's "edit mode" output (see
`readme_review_runner_helpers.jl`): the original README restructured into
Template sections and filled with facts found in the package, gaps marked
`[AUTHOR TO VERIFY: ...]`/`[AUTHOR TO PROVIDE: ...]` rather than invented.
The original README under `replication-package/` is never touched.

Does NOT auto-commit/push: this report may be sent to authors/the handling
editor directly, so a human reviews it before it goes anywhere.
"""
function review_paper_readme(paperID; round = nothing, force::Bool = false)
    r, repo_path = gh_pull(paperID; round = round)
    use_round = isnothing(round) ? r.round : round
    gen_dir = joinpath(repo_path, "generated")
    report_path = joinpath(gen_dir, "report-readme-review.md")
    edited_path = joinpath(gen_dir, "README-ai-edited.md")

    if isfile(report_path) && !force
        @info "report-readme-review.md already exists at $report_path, skipping (force=true to redo)"
        return read(report_path, String)
    end

    package_dir = joinpath(repo_path, "replication-package")
    found = find_readme_in_dir(package_dir)
    isnothing(found) && error("no README (.md/.txt/.pdf) found under $package_dir -- cannot run LLM README review")
    readme_path, kind = found
    source_path = readme_review_source_text_path(readme_path, kind)

    review = run_claude_readme_review(source_path, package_dir)
    kind == :pdf && rm(source_path, force = true)

    usage_str = ismissing(review.usage) ? "" : " ($(join(("$k=$v" for (k, v) in review.usage), ", ")))"
    @info "README review cost for $paperID round $use_round: \$$(review.cost_usd)$usage_str"

    mkpath(gen_dir)
    open(report_path, "w") do io
        println(io, "# README Review (LLM)")
        println(io)
        println(io, "_Generated $(Dates.now()), reviewed `$readme_path`_")
        println(io)
        println(io, review.review_markdown)
    end
    write(edited_path, review.edited_readme_markdown)

    dbox_rel = (name) -> "/" * joinpath(r.journal, r.paper_slug, string(use_round), "large-reports", name)
    upload_to_large_reports = (local_path, name) -> begin
        dbox_path = dbox_rel(name)
        try
            dbox_upload_text(dbox_path, read(local_path, String), dbox_token)
            @info "✓ $name also uploaded to Dropbox at $dbox_path"
            return dbox_folder_file_link(dbox_link_at_path(dirname(dbox_path), dbox_token), name)
        catch e
            @warn "could not upload $name to Dropbox large-reports/" exception = e
            return nothing
        end
    end

    large_reports_url = upload_to_large_reports(report_path, "report-readme-review.md")
    edited_url = upload_to_large_reports(edited_path, "README-ai-edited.md")

    @info """
    README review complete for $paperID round $use_round.
    Report at: $report_path$(isnothing(large_reports_url) ? "" : "\nDropbox link (for the author): $large_reports_url")
    Edited README at: $edited_path$(isnothing(edited_url) ? "" : "\nDropbox link (for the author): $edited_url")

    Review both, then commit and push yourself:
      cd $repo_path && git add generated/report-readme-review.md generated/README-ai-edited.md
      git commit -m "LLM README review" && git push
    """

    return review.review
end
