
# Replicator checklist: a deterministic (no LLM call) aggregator over
# material the automated pipeline already produced for this paper --
# Stage D's crosscheck verdicts, Stage B's README structure checklist,
# Stage R's LLM README review, and the refine.ink referee review -- into
# one short `report-replicator-checklist.md` the replicator can read first,
# instead of a bare link to `large-reports/` and "go read everything".
#
# Several of those reports already contain their own prioritized signal for
# free: Stage D's "Missing"/"Plausible" verdicts and `orphan_code_files` ARE
# an attention list; Stage B's checklist already marks missing sections with
# ❌; Stage R's rubric itself ends in "## Final Assessment" with a
# prioritized fix list. This just extracts and restates those pieces --
# no new reasoning, no new cost. A synthesizing LLM pass across all of them
# (to connect e.g. a Stage D "Missing" data-source claim to a Stage R
# citation-vagueness flag about that same source) is a possible later
# upgrade, not this.

"""
    crosscheck_checklist_section(gen_dir::String) -> String

Extract the attention-worthy bits of Stage D's `crosscheck.json` (if it
exists under `gen_dir`): overall coverage, every claim verdicted "Missing"
or "Plausible" (sorted Missing-first), and `orphan_code_files`. Returns a
placeholder note if `crosscheck.json` doesn't exist (Stage D hasn't run).
"""
function crosscheck_checklist_section(gen_dir::String)
    crosscheck_path = joinpath(gen_dir, "crosscheck.json")
    isfile(crosscheck_path) || return "_(not available -- Stage D crosscheck hasn't run yet)_"

    data = JSON.parsefile(crosscheck_path)
    verdicts = get(data, "verdicts", [])
    orphan_code_files = get(data, "orphan_code_files", [])
    coverage = get(data, "coverage", Dict())

    rank = Dict("Missing" => 1, "Plausible" => 2)
    needs_attention = filter(v -> haskey(rank, v["verdict"]), verdicts)
    sort!(needs_attention, by = v -> rank[v["verdict"]])

    io = IOBuffer()
    overall = get(coverage, "overall", missing)
    println(io, "Coverage: $(ismissing(overall) ? "n/a" : "$(overall)%") ($(length(verdicts)) claims checked).")
    println(io)
    if isempty(needs_attention)
        println(io, "No claims came back \"Missing\" or \"Plausible\" -- every claim had direct supporting evidence.")
    else
        println(io, "Claims worth a closer look:")
        println(io)
        for v in needs_attention
            println(io, "- **[$(v["verdict"])]** $(v["claim_type"]) `$(v["claim_label"])`: $(v["rationale"])")
        end
    end
    if !isempty(orphan_code_files)
        println(io)
        println(io, "Code files with no claim connected to them (worth a \"what does this actually do\" check):")
        println(io)
        for f in orphan_code_files
            println(io, "- `$f`")
        end
    end
    return String(take!(io))
end

"""
    readme_structure_checklist_section(gen_dir::String) -> String

Pull every `- ❌ ...` line (PackageScanner's own marker for a missing
required README section) out of Stage B's `report-readme-structure.md`
under `gen_dir`. Returns a placeholder note if that report doesn't exist.
"""
function readme_structure_checklist_section(gen_dir::String)
    path = joinpath(gen_dir, "report-readme-structure.md")
    isfile(path) || return "_(not available -- Stage B README structure audit hasn't run)_"

    content = read(path, String)
    missing_lines = [strip(replace(l, r"^- ❌ " => "")) for l in split(content, '\n') if occursin(r"^- ❌ ", l)]
    isempty(missing_lines) && return "All required README sections were found by the structural checklist."

    io = IOBuffer()
    println(io, "The structural checklist flagged these required sections as missing:")
    println(io)
    for l in missing_lines
        println(io, "- $l")
    end
    return String(take!(io))
end

"""
    readme_review_checklist_section(gen_dir::String) -> String

Extract the `## Final Assessment` section verbatim from Stage R's
`report-readme-review.md` under `gen_dir` (the rubric's own prompt ends
every review there, with a verdict and prioritized fix list already
written by the model). Returns a placeholder note if that report doesn't
exist, or if it exists but has no such section.
"""
function readme_review_checklist_section(gen_dir::String)
    path = joinpath(gen_dir, "report-readme-review.md")
    isfile(path) || return "_(not available -- Stage R LLM README review hasn't run)_"

    content = read(path, String)
    m = match(r"(?s)## Final Assessment.*"i, content)
    isnothing(m) && return "_(Stage R review found, but it has no \"## Final Assessment\" section)_"
    return strip(m.match)
end

"""
    refine_checklist_section(refine_status, refine_digest, refine_report_link) -> String

Build the referee-review section from already-fetched values (no DB/network
access here, for testability -- the caller, `build_replicator_checklist`,
is responsible for reading `refine_status`/`refine_digest` off the
`iterations` row and minting `refine_report_link` via
`dbox_folder_file_link`). Returns a placeholder note unless
`refine_status == "done"`.
"""
function refine_checklist_section(refine_status, refine_digest, refine_report_link)
    status_str = ismissing(refine_status) ? "not started" : string(refine_status)
    (!ismissing(refine_status) && refine_status == "done") ||
        return "_(not available -- referee review via refine.ink: $status_str)_"

    io = IOBuffer()
    println(io, ismissing(refine_digest) ? "(done, but no digest recorded)" : refine_digest)
    if !isnothing(refine_report_link)
        println(io)
        println(io, "Full referee review: <$refine_report_link>")
    end
    return String(take!(io))
end

"""
    build_replicator_checklist(paperID; round = nothing, force = false)

Deterministic replicator-facing triage note: aggregates Stage D's crosscheck
verdicts, Stage B's README structure checklist, Stage R's LLM README
review, and the refine.ink referee digest into one short
`report-replicator-checklist.md`, written into the paper's `generated/`
folder -- no new `claude` call, just extraction of signal those steps
already produced (see module header for why).

Pulls the paper's repo fresh via `gh_pull` (same convention as
`run_paper_crosscheck`/`review_paper_readme`). If `report-replicator-
checklist.md` already exists and `force = false`, returns its cached
content without rebuilding.

Does NOT auto-commit/push: review it before it goes anywhere.
"""
function build_replicator_checklist(paperID; round = nothing, force::Bool = false)
    r, repo_path = gh_pull(paperID; round = round)
    use_round = isnothing(round) ? r.round : round
    gen_dir = joinpath(repo_path, "generated")
    checklist_path = joinpath(gen_dir, "report-replicator-checklist.md")

    if isfile(checklist_path) && !force
        @info "report-replicator-checklist.md already exists at $checklist_path, skipping (force=true to redo)"
        return read(checklist_path, String)
    end

    it = db_filter_iteration(paperID, use_round)
    nrow(it) == 1 || error("no iteration found for $paperID round $use_round")
    row = it[1, :]
    refine_status = hasproperty(row, :refine_status) ? row.refine_status : missing
    refine_digest = hasproperty(row, :refine_digest) ? row.refine_digest : missing

    refine_link = nothing
    if !ismissing(refine_status) && refine_status == "done"
        large_reports_dbox_path = "/" * joinpath(r.journal, r.paper_slug, string(use_round), "large-reports")
        folder_url = dbox_link_at_path(large_reports_dbox_path, dbox_token)
        isnothing(folder_url) || (refine_link = dbox_folder_file_link(folder_url, "refine-referee-report.md"))
    end

    mkpath(gen_dir)
    open(checklist_path, "w") do io
        println(io, "# Replicator Checklist")
        println(io)
        println(io, "_Generated $(Dates.now()) -- a deterministic summary of what the automated checks ",
                     "flagged. This doesn't replace reading the full reports in `generated/`; it's a ",
                     "starting point for where to look first._")
        println(io)
        println(io, "## Crosscheck: claims vs. package (Stage D)")
        println(io)
        println(io, crosscheck_checklist_section(gen_dir))
        println(io)
        println(io, "## README structure (Stage B)")
        println(io)
        println(io, readme_structure_checklist_section(gen_dir))
        println(io)
        println(io, "## README review (Stage R)")
        println(io)
        println(io, readme_review_checklist_section(gen_dir))
        println(io)
        println(io, "## Referee review (refine.ink)")
        println(io)
        println(io, refine_checklist_section(refine_status, refine_digest, refine_link))
    end

    @info "Replicator checklist written to $checklist_path"
    return read(checklist_path, String)
end
