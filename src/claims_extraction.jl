
# Stage C LLM claims extraction (JPE-Reproducibility/JPE.jl#29).
#
# Flattening the paper's LaTeX source is deterministic and lives in
# PackageScanner.jl (extract_latex_text); that package is not a direct JPE.jl
# dependency (same reason as the PackageScanner precheck step: it only runs
# inside JULIA_RUNNER_ENV, see write_runner_script), so we shell out to that
# environment for the flattening step too, then shell out separately to the
# `claude` CLI (the JPE Claude Pro account, via CLAUDE_CONFIG_DIR -- there is
# no ANTHROPIC_API_KEY) for the actual extraction call.

"""
    claude_binary()

Path to the `claude` CLI, resolved via `PATH`.
"""
claude_binary() = Sys.which("claude")

"""
    claude_jpe_config_dir()

The `CLAUDE_CONFIG_DIR` used by the `claude-jpe` shell alias (the JPE Claude
Pro account, distinct from the user's personal one -- see
`~/.config/fish/functions/claude-jpe.fish`). Falls back to `~/.claude-jpe` if
`CLAUDE_CONFIG_DIR` isn't already set in the environment (e.g. when this is
called from a session that isn't itself a nested claude-jpe invocation).
"""
claude_jpe_config_dir() = get(ENV, "CLAUDE_CONFIG_DIR", joinpath(homedir(), ".claude-jpe"))

"""
    CLAIMS_JSON_SCHEMA

JSON schema passed to `claude -p --json-schema` to force structured claims
output: data sources (with access date / URL/DOI if the paper gives one),
general data processing steps (file loading/merging/cleaning/filtering
applied before any specific table -- the part Stage D cross-references
against Stage A's "which code loads which data" findings), and per-table
specs (estimator, outcome variable, key regressors, controls, fixed effects,
clustering, sample restriction, data source) plus per-figure descriptions.
Unknown/unstated fields must be `null`, not guessed.

Schema shape informed by benjamin-kohler/social_science_replicability's
PaperSummary/TableSpec/RegressionSpec (src/models/schemas.py) -- notably its
`data_processing_steps` (general vs. per-table) and `controls` distinct from
the regressor(s) of interest. Not adopted from there: PDF-page vision input
(irrelevant -- we use tex, not PDF) and its no-results-leakage validation
(irrelevant -- that guards against their blind-replication agent seeing the
answer; we have no such agent to protect, Stage D is allowed to see
everything).
"""
const CLAIMS_JSON_SCHEMA = """
{"type":"object","properties":{
"data_sources":{"type":"array","items":{"type":"object","properties":{
  "name":{"type":"string"},"access_date":{"type":["string","null"]},"url_or_doi":{"type":["string","null"]}
},"required":["name","access_date","url_or_doi"]}},
"data_processing_steps":{"type":"array","items":{"type":"object","properties":{
  "description":{"type":"string"},"variables_involved":{"type":"array","items":{"type":"string"}}
},"required":["description","variables_involved"]}},
"tables":{"type":"array","items":{"type":"object","properties":{
  "label":{"type":"string"},"title":{"type":["string","null"]},"estimator":{"type":["string","null"]},
  "outcome_var":{"type":["string","null"]},"key_regressors":{"type":"array","items":{"type":"string"}},
  "controls":{"type":"array","items":{"type":"string"}},
  "fixed_effects":{"type":"array","items":{"type":"string"}},"clustering":{"type":["string","null"]},
  "sample_restriction":{"type":["string","null"]},"data_source":{"type":["string","null"]}
},"required":["label","title","estimator","outcome_var","key_regressors","controls","fixed_effects","clustering","sample_restriction","data_source"]}},
"figures":{"type":"array","items":{"type":"object","properties":{
  "label":{"type":"string"},"description":{"type":"string"}
},"required":["label","description"]}}
},"required":["data_sources","data_processing_steps","tables","figures"]}
"""

"""
    find_paper_source_dir(author_dir::String, appendices_dir::String)

Pick which local Dropbox folder to search for the paper's LaTeX source:
prefer `paper-author/` (clean author upload, JPE-Reproducibility/JPE.jl#30)
if it contains any `.tex` file at all, else fall back to `paper-appendices/`
(the legacy/mixed dump -- still the only option for in-flight papers that
predate #30).
"""
function find_paper_source_dir(author_dir::String, appendices_dir::String)
    has_tex(dir) = isdir(dir) && any(endswith(lowercase(f), ".tex") for (_, _, files) in walkdir(dir) for f in files)
    has_tex(author_dir) && return author_dir
    return appendices_dir
end

"""
    build_extract_paper_text_script(dir, out_json; main_files = nothing)

The Julia source run inside `JULIA_RUNNER_ENV` to call
`PackageScanner.extract_latex_text(dir; main_files)` and write its result as
JSON to `out_json`. Split out from `extract_paper_text` so the generated
script text is testable without actually running Julia/PackageScanner.
"""
function build_extract_paper_text_script(dir::String, out_json::String; main_files::Union{Nothing,Vector{String}} = nothing)
    main_files_expr = isnothing(main_files) ? "nothing" : "[" * join(repr.(main_files), ",") * "]"
    """
    using PackageScanner, JSON
    r = PackageScanner.extract_latex_text($(repr(dir)); main_files = $main_files_expr)
    open($(repr(out_json)), "w") do io
        JSON.print(io, Dict(
            "text" => r.text,
            "roots" => r.roots,
            "unresolved" => [collect(u) for u in r.unresolved],
            "ambiguous" => r.ambiguous,
        ))
    end
    """
end

"""
    extract_paper_text(dir::String; main_files = nothing)

Shell out to `JULIA_RUNNER_ENV` to flatten the paper's LaTeX source at `dir`
(see `PackageScanner.extract_latex_text`). Returns the same named tuple shape:
`(text, roots, unresolved, ambiguous)`.
"""
function extract_paper_text(dir::String; main_files::Union{Nothing,Vector{String}} = nothing)
    haskey(ENV, "JULIA_RUNNER_ENV") || error("JULIA_RUNNER_ENV not set")

    out_json = tempname() * ".json"
    script = build_extract_paper_text_script(dir, out_json; main_files = main_files)

    run(`julia --project=$(ENV["JULIA_RUNNER_ENV"]) -e $script`)

    result = JSON.parsefile(out_json)
    rm(out_json, force = true)

    return (
        text = result["text"],
        roots = result["roots"],
        unresolved = [Tuple(u) for u in result["unresolved"]],
        ambiguous = result["ambiguous"],
    )
end

"""
    claims_extraction_prompt(paper_text_path::String)

The prompt given to `claude -p` for the claims-extraction call. Points at the
flattened paper text by path (read via the `Read` tool) rather than embedding
it inline, so the shell command itself stays short regardless of paper size.
"""
function claims_extraction_prompt(paper_text_path::String)
    """
    Read the flattened LaTeX paper source at $paper_text_path and extract a
    structured summary of its empirical claims, for a static plausibility
    cross-check against the paper's replication package (no code execution
    involved -- this is not a reproducibility check). Follow the provided
    JSON schema exactly. For each table, fill in as many structured fields as
    the text actually supports; use null for anything the paper doesn't
    specify. Do not invent or guess values that aren't in the text.

    Resolve cross-references before extracting: when the text says "see
    Appendix H" or "controls listed in Table A3" or "as defined in Section
    2", go find that content elsewhere in the flattened text (it has already
    been inlined) and extract the actual content there -- do not leave a
    reference unresolved. For `controls`, enumerate every control variable
    individually rather than writing an aggregate description like
    "socio-demographic controls".

    Skip purely conceptual figures that have no replicable data behind them
    (flow diagrams, conceptual frameworks, schematics, screenshots, photos,
    maps) -- only extract figures that plot actual data or model output.
    """
end

"""
    build_claude_claims_cmd(paper_text_path::String; effort = "medium")

The `Cmd` for the headless claims-extraction call. Split out from
`run_claude_claims_extraction` so the flags are testable without actually
invoking `claude` (no live API/CLI calls in tests).

Uses `--safe-mode` (not `--bare`, which strictly requires `ANTHROPIC_API_KEY`
and would break the Pro-subscription OAuth auth this relies on) to drop
CLAUDE.md/memory/hooks overhead, and restricts tools to `Read` only --
a single turn, no agentic loop, to keep this cheap under a Pro quota.
"""
function build_claude_claims_cmd(paper_text_path::String; effort::String = "medium")
    bin = claude_binary()
    isnothing(bin) && error("claude CLI not found on PATH")

    setenv(
        `$bin -p $(claims_extraction_prompt(paper_text_path))
         --output-format json --tools Read --safe-mode --effort $effort
         --json-schema $CLAIMS_JSON_SCHEMA`,
        "CLAUDE_CONFIG_DIR" => claude_jpe_config_dir(),
    )
end

"""
    run_claude_claims_extraction(paper_text_path::String; effort = "medium")

Run the headless claims-extraction call and return
`(claims = <parsed structured_output>, cost_usd = <reported cost>)`.
"""
function run_claude_claims_extraction(paper_text_path::String; effort::String = "medium")
    cmd = build_claude_claims_cmd(paper_text_path; effort = effort)
    out = read(cmd, String)
    parsed = JSON.parse(out)

    get(parsed, "is_error", true) == false || error("claude -p failed: $(get(parsed, "result", "unknown error"))")

    return (claims = parsed["structured_output"], cost_usd = get(parsed, "total_cost_usd", missing))
end

"""
    extract_paper_claims(paperID; round = nothing, out_dir, force = false, main_files = nothing)

Stage C claims extraction: locate the paper's LaTeX source (preferring
`paper-author/`, falling back to `paper-appendices/`), flatten it, and run
the headless claims-extraction call. Writes `claims.json` into `out_dir`;
if it already exists there and `force = false`, returns the cached content
without re-running anything (this is the cache check `preprocess` relies on
to avoid re-spending on an unchanged paper).

If LaTeX source discovery is ambiguous (multiple candidate main files),
prompts interactively for which to use, re-resolves, and proceeds. If no
`.tex` source is found at all, warns and returns `nothing` (the PDF fallback
is not implemented here).
"""
function extract_paper_claims(paperID; round = nothing, out_dir::String, force::Bool = false,
                               main_files::Union{Nothing,Vector{String}} = nothing)
    claims_path = joinpath(out_dir, "claims.json")
    if isfile(claims_path) && !force
        @info "claims.json already exists at $claims_path, skipping (force=true to redo)"
        return JSON.parsefile(claims_path)
    end

    p = db_filter_paper(paperID)
    nrow(p) == 1 || error("paper $paperID not found or ambiguous")
    round = isnothing(round) ? p[1, :round] : round

    it = db_filter_iteration(paperID, round)
    nrow(it) == 1 || error("no iteration found for $paperID round $round")
    r = it[1, :]

    author_dir = string(ENV["JPE_DBOX_APPS"], r.paper_source_path)
    appendices_dir = string(ENV["JPE_DBOX_APPS"], r.paper_path)
    dir = find_paper_source_dir(author_dir, appendices_dir)

    result = extract_paper_text(dir; main_files = main_files)

    if result.ambiguous
        println(">>> Multiple candidate main .tex files found for $paperID round $round:")
        for (i, root) in enumerate(result.roots)
            println("  $i) $root")
        end
        menu = RadioMenu(vcat(["use ALL of the above (main + appendix)"], result.roots,
                               ["skip -- ambiguous, decide manually later"]))
        choice = request(menu)
        if choice == 1
            main_files = result.roots
        elseif choice == length(result.roots) + 2
            @warn "skipped claims extraction for $paperID round $round -- ambiguous tex roots, not disambiguated"
            return nothing
        else
            main_files = [result.roots[choice - 1]]
        end
        result = extract_paper_text(dir; main_files = main_files)
    end

    if isempty(result.roots)
        @warn "no .tex source found for $paperID round $round under $dir -- PDF fallback not implemented, skipping claims extraction"
        return nothing
    end

    mkpath(out_dir)
    text_path = joinpath(tempdir(), "$(paperID)-$(round)-flattened.tex")
    write(text_path, result.text)

    extraction = run_claude_claims_extraction(text_path)
    @info "claims extraction cost for $paperID round $round: \$$(extraction.cost_usd)"

    open(claims_path, "w") do io
        JSON.print(io, extraction.claims, 2)
    end

    rm(text_path, force = true)

    return extraction.claims
end
