
# Stage D: DB-backed manual/force-rerun entry point (JPE-Reproducibility/JPE.jl#29).
#
# The functions this builds on (prompt, schema, `claude -p` invocation,
# coverage scoring, report rendering) live in crosscheck_runner_helpers.jl --
# they're self-contained there so that same source can be spliced into the
# generated runner_precheck.jl script (see write_runner_script in
# preprocess.jl) and run Stage D automatically, right after Stage C, in
# either local or gh-runner mode. `run_paper_crosscheck` here is only for a
# DE-triggered manual rerun after the fact (e.g. `force=true` to redo a
# round whose Stage D already ran, or to crosscheck a round the automatic
# pass skipped) -- it is NOT on the normal preprocess() path.

"""
    run_paper_crosscheck(paperID; round = nothing, force = false)

Stage D: match Stage C's extracted claims (`claims.json`) against Stage A/B's
findings and the package's file listing, score coverage, and write
`report-crosscheck.md` (plus the underlying `crosscheck.json`) into the paper's
`generated/` folder.

Pulls the paper's repo fresh via `gh_pull` rather than assuming a stale local
temp clone from a prior `preprocess()` call -- this is a separate,
DE-triggered rerun, run well after `preprocess()` (and its automatic Stage D
pass) already returned. `round` defaults to the paper's current round per the
`papers` table (passed through to `gh_pull`); pass it explicitly to
crosscheck an earlier round (e.g. round 1 while the paper has since moved to
round 2).

Requires `claims.json` (Stage C) to already exist in `generated/`; errors if
not -- run `extract_paper_claims` first. `report-readme-structure.md` (Stage B)
is optional and degrades gracefully if absent.

Does NOT auto-commit/push (matching `write_report`'s convention): this report
may be sent to authors/the handling editor directly, so a human reviews it
before it goes anywhere.
"""
function run_paper_crosscheck(paperID; round = nothing, force::Bool = false)
    r, repo_path = gh_pull(paperID; round = round)
    use_round = isnothing(round) ? r.round : round
    gen_dir = joinpath(repo_path, "generated")

    crosscheck_path = joinpath(gen_dir, "crosscheck.json")
    report_path = joinpath(gen_dir, "report-crosscheck.md")
    if isfile(crosscheck_path) && !force
        @info "crosscheck.json already exists at $crosscheck_path, skipping (force=true to redo)"
        return JSON.parsefile(crosscheck_path)
    end

    claims_path = joinpath(gen_dir, "claims.json")
    isfile(claims_path) || error("claims.json not found in $gen_dir -- run extract_paper_claims (Stage C) first")

    bundle_dir = mktempdir()
    cp(claims_path, joinpath(bundle_dir, "claims.json"))
    write(joinpath(bundle_dir, "data_dependencies.md"),
          read_or_placeholder(joinpath(gen_dir, "report-data-dependencies.md"), "(not available)"))
    write(joinpath(bundle_dir, "readme_structure.md"),
          read_or_placeholder(joinpath(gen_dir, "report-readme-structure.md"), "(not available)"))
    write(joinpath(bundle_dir, "code_manifest.txt"),
          read_or_placeholder(joinpath(gen_dir, "program-files-manifest.csv"),
                               read_or_placeholder(joinpath(gen_dir, "program-files.txt"), "(not available)")))
    write(joinpath(bundle_dir, "data_manifest.txt"),
          read_or_placeholder(joinpath(gen_dir, "data-files-manifest.csv"), "(not available)"))

    extraction = run_claude_crosscheck(bundle_dir)
    @info "crosscheck cost for $paperID round $use_round: \$$(extraction.cost_usd)"

    verdicts = extraction.result["verdicts"]
    orphan_code_files = extraction.result["orphan_code_files"]
    coverage = compute_coverage(verdicts)

    mkpath(gen_dir)
    open(crosscheck_path, "w") do io
        JSON.print(io, Dict("verdicts" => verdicts, "coverage" => coverage, "orphan_code_files" => orphan_code_files), 2)
    end
    write(report_path, render_crosscheck_report(verdicts, coverage, orphan_code_files))

    rm(bundle_dir, recursive = true, force = true)

    @info """
    Crosscheck complete for $paperID round $use_round: $(coverage["overall"])% overall coverage.
    Report at: $report_path

    Review it, then commit and push yourself:
      cd $repo_path && git add generated/crosscheck.json generated/report-crosscheck.md
      git commit -m "Stage D crosscheck" && git push
    """

    return (verdicts = verdicts, coverage = coverage, orphan_code_files = orphan_code_files)
end
