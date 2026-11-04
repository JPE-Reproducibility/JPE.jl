
# Stage D: matching + coverage scoring (JPE-Reproducibility/JPE.jl#29).
#
# Reads Stage A (report-data-dependencies.md), Stage B (report-readme-structure.md
# -- optional, degrades gracefully if absent: JPE-Reproducibility/PackageScanner.jl#17
# not yet merged at the time this was written), and Stage C (claims.json) outputs
# from the paper's generated/ folder, and runs a single headless `claude -p` call
# (same budget discipline as Stage C: --safe-mode, single turn, no agentic Read/Grep
# loop) to produce a per-claim verdict (Matched/Plausible/Missing) with file-level
# supporting evidence.
#
# Coverage percentages are computed in Julia from the verdicts, not asked of the
# model -- deterministic and auditable. The denominator is the claims Stage C
# extracted; if Stage C missed something, it is invisible to this score (documented
# in the report's caveats section, not silently papered over).
#
# SCOPE DEVIATION from issue #29: without raw code file *content* in the prompt
# (deliberately excluded to keep this single-turn/cheap, consistent with the
# "static plausibility, not line-level verification" scope), the model cannot
# produce honest file:line citations as the issue describes. Verdicts cite
# supporting *files* only, never line numbers -- flagged here and in the report's
# caveats rather than having the model fabricate a line it never saw.

const CROSSCHECK_JSON_SCHEMA = """
{"type":"object","properties":{
"verdicts":{"type":"array","items":{"type":"object","properties":{
  "claim_type":{"type":"string","enum":["data_source","table","figure"]},
  "claim_label":{"type":"string"},
  "verdict":{"type":"string","enum":["Matched","Plausible","Missing"]},
  "rationale":{"type":"string"},
  "supporting_files":{"type":"array","items":{"type":"string"}}
},"required":["claim_type","claim_label","verdict","rationale","supporting_files"]}},
"orphan_code_files":{"type":"array","items":{"type":"string"}}
},"required":["verdicts","orphan_code_files"]}
"""

"""
    PLAUSIBLE_CREDIT

Weight given to a "Plausible" verdict when computing coverage percentages:
`Matched` = 1.0, `Plausible` = `PLAUSIBLE_CREDIT`, `Missing` = 0.0. This single
constant determines the headline coverage number more than any prompt wording
-- change it here if the scoring convention should differ.
"""
const PLAUSIBLE_CREDIT = 0.5

"""
    read_or_placeholder(path::String, placeholder::String)

`read(path, String)` if `path` exists, else `placeholder`. Used so a missing
optional input (e.g. Stage B's report, if that package's precheck predates
PackageScanner.jl#17) degrades gracefully instead of erroring.
"""
read_or_placeholder(path::String, placeholder::String) = isfile(path) ? read(path, String) : placeholder

"""
    crosscheck_prompt(bundle_dir::String)

The prompt for the Stage D matching call. Points at the input bundle by
directory (read via the `Read` tool) rather than embedding content inline.
Deliberately excludes raw replication-package code content -- only Stage
A/B/C's already-computed findings and file manifests -- to keep this a
single turn, no agentic exploration loop.
"""
function crosscheck_prompt(bundle_dir::String)
    """
    Read the files in $bundle_dir:
    - claims.json: structured claims extracted from the paper (Stage C).
    - data_dependencies.md: which data files are referenced by which code files (Stage A).
    - readme_structure.md: README section checklist and data citation coverage (Stage B).
      If this says "(not available)", Stage B wasn't run for this package -- proceed
      without it, don't penalize claims for its absence.
    - code_manifest.txt / data_manifest.txt: file listings of the replication package.

    For each claim in claims.json (each data source, table, and figure), assess
    whether the package's code/data could plausibly implement it, based ONLY on the
    evidence in these files -- you do not have the code's actual content, only file
    listings and Stage A/B's findings. Assign one of:
    - "Matched": Stage A/B's findings directly support the claim (e.g. a data source
      the claim names is referenced by a specific code file per data_dependencies.md).
    - "Plausible": no direct evidence, but nothing contradicts it and the package's
      file listing is consistent with the claim (e.g. a plausibly-named script exists
      but Stage A didn't trace a direct reference).
    - "Missing": no file in the package is plausibly connected to the claim at all.

    Cite supporting files by name in `supporting_files` -- you cannot see line
    numbers, so never invent them or claim line-level evidence.

    Also list `orphan_code_files`: code files in code_manifest.txt that have no
    plausible connection to any claim in claims.json (candidates for "what is this
    code actually doing" follow-up by the human replicator).

    This is a static plausibility check, not a reproducibility check -- you are not
    running any code, and should not speculate about whether the code runs correctly
    or produces correct numbers.
    """
end

"""
    build_crosscheck_cmd(bundle_dir::String; effort = "medium")

Same budget-conscious shape as `build_claude_claims_cmd` (Stage C): `--safe-mode`
(not `--bare`, which would require an API key and break the Pro-subscription
OAuth auth this relies on), `Read`-only tools, single turn, `--json-schema`
forcing `CROSSCHECK_JSON_SCHEMA`. Split out from `run_claude_crosscheck` so the
flags are testable without actually invoking `claude`.
"""
function build_crosscheck_cmd(bundle_dir::String; effort::String = "medium")
    bin = claude_binary()
    isnothing(bin) && error("claude CLI not found on PATH")

    setenv(
        `$bin -p $(crosscheck_prompt(bundle_dir))
         --output-format json --tools Read --safe-mode --effort $effort
         --json-schema $CROSSCHECK_JSON_SCHEMA`,
        "CLAUDE_CONFIG_DIR" => claude_jpe_config_dir(),
    )
end

"""
    run_claude_crosscheck(bundle_dir::String; effort = "medium")

Run the headless crosscheck call and return
`(result = <parsed structured_output>, cost_usd = <reported cost>)`.
"""
function run_claude_crosscheck(bundle_dir::String; effort::String = "medium")
    cmd = build_crosscheck_cmd(bundle_dir; effort = effort)
    out = read(cmd, String)
    parsed = JSON.parse(out)

    get(parsed, "is_error", true) == false || error("claude -p failed: $(get(parsed, "result", "unknown error"))")

    return (result = parsed["structured_output"], cost_usd = get(parsed, "total_cost_usd", missing))
end

"""
    compute_coverage(verdicts::Vector)

Deterministic coverage percentages from the per-claim verdicts: `Matched` = full
credit, `Plausible` = `PLAUSIBLE_CREDIT`, `Missing` = zero credit. Computed in
Julia (never asked of the model) so the number is auditable directly from the
verdicts list, not a free-floating model claim. Returns overall coverage plus a
breakdown by `claim_type` (`data_source`/`table`/`figure`).
"""
function compute_coverage(verdicts::Vector)
    credit(v) = v["verdict"] == "Matched" ? 1.0 : (v["verdict"] == "Plausible" ? PLAUSIBLE_CREDIT : 0.0)

    function pct(vs)
        isempty(vs) && return missing
        round(100 * sum(credit, vs) / length(vs), digits = 1)
    end

    by_type = Dict{String,Any}()
    for t in unique(v["claim_type"] for v in verdicts)
        by_type[t] = pct(filter(v -> v["claim_type"] == t, verdicts))
    end

    return Dict("overall" => pct(verdicts), "by_claim_type" => by_type, "n_claims" => length(verdicts))
end

"""
    render_crosscheck_report(verdicts, coverage, orphan_code_files)

Render `report-crosscheck.md`: a mandatory caveats section (static plausibility
only -- no code execution, file-level not line-level citations, coverage is
relative to what Stage C extracted), a coverage summary table, per-claim verdict
detail, and orphan code files.
"""
function render_crosscheck_report(verdicts::Vector, coverage::Dict, orphan_code_files::Vector)
    io = IOBuffer()
    println(io, "### Paper vs. Code/Data Crosscheck\n")
    println(io, "_Generated on $(Dates.now())_\n")
    println(io, """
    **Caveats (read before using this report):**
    - **Static plausibility only, not a reproducibility check.** No code was executed.
      This cannot catch logic bugs, wrong coefficients, or silently incorrect results.
    - **File-level citations only, not line-level.** The model did not see code file
      contents -- only Stage A/B's pre-computed findings and file listings. Any
      "supporting file" below is a plausibility signal, not a verified line reference.
    - **Coverage is relative to what Stage C extracted from the paper**, not to the
      paper's true full content. A claim Stage C missed is invisible to this score.
    """)

    println(io, "#### Coverage\n")
    println(io, "| Category | Coverage | n claims |")
    println(io, "|----------|----------|----------|")
    for (t, p) in coverage["by_claim_type"]
        n = count(v -> v["claim_type"] == t, verdicts)
        println(io, "| $t | $(p)% | $n |")
    end
    println(io, "| **Overall** | **$(coverage["overall"])%** | $(coverage["n_claims"]) |\n")

    println(io, "#### Per-Claim Detail\n")
    for v in verdicts
        icon = v["verdict"] == "Matched" ? "✅" : (v["verdict"] == "Plausible" ? "🟡" : "❌")
        println(io, "$icon **$(v["claim_type"]): $(v["claim_label"])** — $(v["verdict"])")
        println(io, "- $(v["rationale"])")
        if !isempty(v["supporting_files"])
            println(io, "- supporting files: ", join("`" .* v["supporting_files"] .* "`", ", "))
        end
        println(io)
    end

    println(io, "#### Orphan Code (no traceable connection to any claim)\n")
    if isempty(orphan_code_files)
        println(io, "None found.")
    else
        for f in orphan_code_files
            println(io, "- `$f`")
        end
    end

    return String(take!(io))
end

"""
    run_paper_crosscheck(paperID; force = false)

Stage D: match Stage C's extracted claims (`claims.json`) against Stage A/B's
findings and the package's file listing, score coverage, and write
`report-crosscheck.md` (plus the underlying `crosscheck.json`) into the paper's
`generated/` folder.

Pulls the paper's repo fresh via `gh_pull` rather than assuming a stale local
temp clone from a prior `preprocess()` call -- this runs well after
`preprocess()` returns (locally, or in gh-runner mode only after the remote
workflow has pushed its results back), as a separate DE-triggered step. (Note:
`gh_pull` always operates on the paper's current round per the `papers` table;
it has no round override, matching the existing convention used by
`write_report`.)

Requires `claims.json` (Stage C) to already exist in `generated/`; errors if
not -- run `extract_paper_claims` first. `report-readme-structure.md` (Stage B)
is optional and degrades gracefully if absent.

Does NOT auto-commit/push (matching `write_report`'s convention): this report
may be sent to authors/the handling editor directly, so a human reviews it
before it goes anywhere.
"""
function run_paper_crosscheck(paperID; force::Bool = false)
    r, repo_path = gh_pull(paperID)
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
    @info "crosscheck cost for $paperID round $(r.round): \$$(extraction.cost_usd)"

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
    Crosscheck complete for $paperID round $(r.round): $(coverage["overall"])% overall coverage.
    Report at: $report_path

    Review it, then commit and push yourself:
      cd $repo_path && git add generated/crosscheck.json generated/report-crosscheck.md
      git commit -m "Stage D crosscheck" && git push
    """

    return (verdicts = verdicts, coverage = coverage, orphan_code_files = orphan_code_files)
end
