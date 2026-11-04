
# Stage C LLM claims extraction (JPE-Reproducibility/JPE.jl#29).
#
# Flattening the paper's LaTeX source is deterministic and lives in
# PackageScanner.jl (extract_latex_text); that package is not a direct JPE.jl
# dependency (same reason as the PackageScanner precheck step: it only runs
# inside JULIA_RUNNER_ENV, see write_runner_script), so we shell out to that
# environment for the flattening step too, then shell out separately to the
# `claude` CLI (the JPE Claude Pro account, via CLAUDE_CONFIG_DIR -- there is
# no ANTHROPIC_API_KEY) for the actual extraction call.
#
# The actual claude-CLI-calling helpers (schema, prompt, cmd builder, runner)
# live in claims_runner_helpers.jl, included separately: that file's source
# is also spliced verbatim into the generated runner_precheck.jl script (see
# write_runner_script in preprocess.jl, JPE-Reproducibility/JPE.jl#34) so
# Stage C can run wherever that script executes, not just from a JPE.jl
# session. Everything below is JPE.jl-local only (DB access, interactive
# disambiguation) and is not part of that splice.

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
