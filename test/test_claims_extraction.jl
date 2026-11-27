@testset "find_paper_source_dir" begin
    mktempdir() do root
        author_dir = joinpath(root, "paper-author")
        appendices_dir = joinpath(root, "paper-appendices")
        mkpath(author_dir)
        mkpath(appendices_dir)

        # neither has tex yet -> falls back to appendices
        @test JPE.find_paper_source_dir(author_dir, appendices_dir) == appendices_dir

        # appendices has tex, author doesn't -> still appendices (nothing to prefer)
        write(joinpath(appendices_dir, "paper.tex"), "\\documentclass{article}")
        @test JPE.find_paper_source_dir(author_dir, appendices_dir) == appendices_dir

        # author now has tex -> preferred over appendices
        write(joinpath(author_dir, "main.tex"), "\\documentclass{article}")
        @test JPE.find_paper_source_dir(author_dir, appendices_dir) == author_dir
    end
end

@testset "find_paper_source_dir - recurses into subfolders" begin
    mktempdir() do root
        author_dir = joinpath(root, "paper-author")
        appendices_dir = joinpath(root, "paper-appendices")
        mkpath(joinpath(appendices_dir, "paper"))
        mkpath(author_dir)

        write(joinpath(appendices_dir, "paper", "main.tex"), "\\documentclass{article}")
        @test JPE.find_paper_source_dir(author_dir, appendices_dir) == appendices_dir
    end
end

@testset "has_any_content" begin
    mktempdir() do root
        empty_dir = joinpath(root, "empty")
        mkpath(empty_dir)
        @test !JPE.has_any_content(empty_dir)
        @test !JPE.has_any_content(joinpath(root, "does-not-exist"))

        write(joinpath(empty_dir, "x.txt"), "hi")
        @test JPE.has_any_content(empty_dir)
    end
end

@testset "unzip_nested_paper_source - no zips, returns dir unchanged" begin
    mktempdir() do dir
        write(joinpath(dir, "main.tex"), "\\documentclass{article}")
        @test JPE.unzip_nested_paper_source(dir) == dir
    end
end

@testset "unzip_nested_paper_source - extracts top-level zip" begin
    mktempdir() do dir
        src = joinpath(dir, "src")
        mkpath(src)
        write(joinpath(src, "main.tex"), "\\documentclass{article}")
        zippath = joinpath(dir, "paper.zip")
        run(`zip -jq $zippath $(joinpath(src, "main.tex"))`)

        appendices_dir = joinpath(dir, "paper-appendices")
        mkpath(appendices_dir)
        cp(zippath, joinpath(appendices_dir, "paper.zip"))

        extracted = JPE.unzip_nested_paper_source(appendices_dir)
        @test extracted != appendices_dir
        @test isfile(joinpath(extracted, "main.tex"))
    end
end

@testset "resolve_main_files - absolute path passes through" begin
    mktempdir() do dir
        f = joinpath(dir, "main.tex")
        write(f, "\\documentclass{article}")
        @test JPE.resolve_main_files(dir, [f]) == [f]
    end
end

@testset "resolve_main_files - resolves bare filename against dir" begin
    mktempdir() do dir
        sub = joinpath(dir, "Paper TEX file")
        mkpath(sub)
        write(joinpath(sub, "Paper.tex"), "\\documentclass{article}")
        write(joinpath(sub, "Appendix.tex"), "\\documentclass{article}")

        resolved = JPE.resolve_main_files(dir, ["Paper.tex", "Appendix.tex"])
        @test resolved == [joinpath(sub, "Paper.tex"), joinpath(sub, "Appendix.tex")]
    end
end

@testset "resolve_main_files - errors on no match" begin
    mktempdir() do dir
        @test_throws ErrorException JPE.resolve_main_files(dir, ["Nonexistent.tex"])
    end
end

@testset "resolve_main_files - errors on ambiguous match" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "a"))
        mkpath(joinpath(dir, "b"))
        write(joinpath(dir, "a", "main.tex"), "\\documentclass{article}")
        write(joinpath(dir, "b", "main.tex"), "\\documentclass{article}")

        @test_throws ErrorException JPE.resolve_main_files(dir, ["main.tex"])
    end
end

@testset "find_paper_source_round - current round has content, no fallback needed" begin
    mktempdir() do dbox
        journal, slug = "JPE", "Test-123"
        mkpath(joinpath(dbox, journal, slug, "2", "paper-author"))
        write(joinpath(dbox, journal, slug, "2", "paper-author", "main.tex"), "\\documentclass{article}")

        found = JPE.find_paper_source_round(dbox, journal, slug, 2)
        @test found.round == 2
        @test found.subfolder == "paper-author"
        @test found.dir == joinpath(dbox, journal, slug, "2", "paper-author")
    end
end

@testset "find_paper_source_round - falls back to an earlier round when current is empty" begin
    mktempdir() do dbox
        journal, slug = "JPE", "Test-456"
        # round 2: both subfolders exist but empty (the common "author didn't
        # resubmit the paper" case)
        mkpath(joinpath(dbox, journal, slug, "2", "paper-author"))
        mkpath(joinpath(dbox, journal, slug, "2", "paper-appendices"))
        # round 1: has the real paper, in paper-appendices only
        mkpath(joinpath(dbox, journal, slug, "1", "paper-appendices"))
        write(joinpath(dbox, journal, slug, "1", "paper-appendices", "paper.pdf"), "fake pdf")

        found = JPE.find_paper_source_round(dbox, journal, slug, 2)
        @test found.round == 1
        @test found.subfolder == "paper-appendices"
    end
end

@testset "find_paper_source_round - searches back past multiple empty rounds" begin
    mktempdir() do dbox
        journal, slug = "JPE", "Test-789"
        for round in 1:3
            mkpath(joinpath(dbox, journal, slug, string(round), "paper-author"))
            mkpath(joinpath(dbox, journal, slug, string(round), "paper-appendices"))
        end
        write(joinpath(dbox, journal, slug, "1", "paper-author", "main.tex"), "\\documentclass{article}")

        found = JPE.find_paper_source_round(dbox, journal, slug, 3)
        @test found.round == 1
        @test found.subfolder == "paper-author"
    end
end

@testset "find_paper_source_round - nothing anywhere returns nothing" begin
    mktempdir() do dbox
        journal, slug = "JPE", "Test-000"
        mkpath(joinpath(dbox, journal, slug, "1", "paper-author"))
        mkpath(joinpath(dbox, journal, slug, "1", "paper-appendices"))

        @test isnothing(JPE.find_paper_source_round(dbox, journal, slug, 1))
    end
end

@testset "is_journal_office_upload" begin
    @test JPE.is_journal_office_upload("/some/dir/Connie - 20200631.zip")
    @test !JPE.is_journal_office_upload("/some/dir/pablo brañas garza - revised ms.pdf")
end

@testset "find_paper_pdf - prefers author upload over journal-office upload" begin
    mktempdir() do dir
        write(joinpath(dir, "Connie - 123.pdf"), "journal office copy")
        write(joinpath(dir, "author draft.pdf"), "author copy")

        @test JPE.find_paper_pdf(dir) == joinpath(dir, "author draft.pdf")
    end
end

@testset "find_paper_pdf - falls back to journal-office upload if it's the only one" begin
    mktempdir() do dir
        write(joinpath(dir, "Connie - 123.pdf"), "journal office copy")

        @test JPE.find_paper_pdf(dir) == joinpath(dir, "Connie - 123.pdf")
    end
end

@testset "find_paper_pdf - paper.pdf wins over everything, including journal-office naming" begin
    mktempdir() do dir
        write(joinpath(dir, "Connie - 123.pdf"), "journal office copy")
        write(joinpath(dir, "paper.pdf"), "the real one")

        @test JPE.find_paper_pdf(dir) == joinpath(dir, "paper.pdf")
    end
end

@testset "find_paper_pdf" begin
    mktempdir() do dir
        @test isnothing(JPE.find_paper_pdf(dir))

        write(joinpath(dir, "notes.txt"), "not a pdf")
        @test isnothing(JPE.find_paper_pdf(dir))

        write(joinpath(dir, "appendix.pdf"), "fake pdf bytes")
        @test JPE.find_paper_pdf(dir) == joinpath(dir, "appendix.pdf")

        # paper.pdf is preferred over an alphabetically-earlier file
        write(joinpath(dir, "AAA_cover_letter.pdf"), "fake pdf bytes")
        write(joinpath(dir, "paper.pdf"), "fake pdf bytes")
        @test JPE.find_paper_pdf(dir) == joinpath(dir, "paper.pdf")
    end
end

@testset "find_paper_pdf - recurses into subfolders" begin
    mktempdir() do dir
        subdir = joinpath(dir, "paper-source")
        mkpath(subdir)
        write(joinpath(subdir, "main.pdf"), "fake pdf bytes")
        @test JPE.find_paper_pdf(dir) == joinpath(subdir, "main.pdf")
    end
end

@testset "build_extract_pdf_text_script" begin
    script = JPE.build_extract_pdf_text_script("/some/dir/paper.pdf", "/tmp/out.json")
    @test occursin("PackageScanner.extract_pdf_text(\"/some/dir/paper.pdf\")", script)
    @test occursin("/tmp/out.json", script)
end

@testset "build_extract_paper_text_script" begin
    script_nothing = JPE.build_extract_paper_text_script("/some/dir", "/tmp/out.json")
    @test occursin("PackageScanner.extract_latex_text(\"/some/dir\"; main_files = nothing)", script_nothing)

    script_main_files = JPE.build_extract_paper_text_script("/some/dir", "/tmp/out.json";
                                                              main_files = ["/some/dir/a.tex", "/some/dir/b.tex"])
    @test occursin("main_files = [\"/some/dir/a.tex\",\"/some/dir/b.tex\"]", script_main_files)
end

@testset "claims_extraction_prompt - references the given path" begin
    prompt = JPE.claims_extraction_prompt("/tmp/flattened.tex")
    @test occursin("/tmp/flattened.tex", prompt)
    @test occursin("no code execution", prompt)
    @test occursin("Resolve cross-references", prompt)
    @test occursin("Skip purely conceptual figures", prompt)
end

@testset "CLAIMS_JSON_SCHEMA - parses and has the expected fields" begin
    schema = JSON.parse(JPE.CLAIMS_JSON_SCHEMA)
    @test Set(keys(schema["properties"])) == Set(["data_sources", "data_processing_steps", "tables", "figures"])

    table_props = schema["properties"]["tables"]["items"]["properties"]
    @test haskey(table_props, "controls")
    @test haskey(table_props, "key_regressors")

    dps_props = schema["properties"]["data_processing_steps"]["items"]["properties"]
    @test Set(keys(dps_props)) == Set(["description", "variables_involved"])
end

@testset "claude_jpe_config_dir - respects env, falls back to ~/.claude-jpe" begin
    withenv("CLAUDE_CONFIG_DIR" => nothing) do
        @test JPE.claude_jpe_config_dir() == joinpath(homedir(), ".claude-jpe")
    end
    withenv("CLAUDE_CONFIG_DIR" => "/custom/dir") do
        @test JPE.claude_jpe_config_dir() == "/custom/dir"
    end
end

@testset "build_claude_claims_cmd - flags and env" begin
    withenv("CLAUDE_CONFIG_DIR" => "/custom/claude-config") do
        cmd = JPE.build_claude_claims_cmd("/tmp/flattened.tex"; effort = "medium")
        cmd_str = string(cmd)
        @test occursin("--safe-mode", cmd_str)
        @test occursin("--tools", cmd_str)
        @test occursin("Read", cmd_str)
        @test occursin("--json-schema", cmd_str)
        @test occursin("--effort", cmd_str)
        @test occursin("medium", cmd_str)
        @test occursin("CLAUDE_CONFIG_DIR=/custom/claude-config", cmd_str)
        @test occursin("--add-dir", cmd_str)
        @test occursin("/tmp", cmd_str)
    end
end

@testset "extract_paper_claims - cache hit returns parsed claims.json without re-running" begin
    mktempdir() do out_dir
        cached = Dict("data_sources" => [], "tables" => [], "figures" => [])
        open(joinpath(out_dir, "claims.json"), "w") do io
            JSON.print(io, cached)
        end

        # cache check happens before any DB/subprocess call, so this must not
        # error even though paperID doesn't exist in the test db.
        result = JPE.extract_paper_claims("NO-SUCH-PAPER"; out_dir = out_dir)
        @test result == cached
    end
end

@testset "write_runner_script - Stage C splice parses and wires in the helpers" begin
    mktempdir() do repoloc
        JPE.write_runner_script(repoloc, ["__MACOSX", "renv"]; run_checks = true, do_claims = true)
        content = read(joinpath(repoloc, "runner_precheck.jl"), String)

        # must be valid, complete Julia (a rename in claims_runner_helpers.jl
        # that leaves a stale call site here would otherwise only be caught
        # on the runner, mid-run)
        parsed = Meta.parseall(content)
        @test !(parsed isa Expr && parsed.head == :incomplete)

        # the helper functions this block calls must actually be present --
        # catches a rename in claims_runner_helpers.jl that forgets to update
        # the orchestration block below it
        for name in ("claude_binary", "claude_jpe_config_dir", "CLAIMS_JSON_SCHEMA",
                     "claims_extraction_prompt", "build_claude_claims_cmd", "run_claude_claims_extraction",
                     "find_paper_pdf")
            @test occursin(name, content)
        end

        @test occursin("PackageScanner.extract_latex_text(paper_dest_path)", content)
        # PDF fallback (JPE-Reproducibility/PackageScanner.jl extract_pdf_text):
        # catches a future edit that drops this branch and silently reverts to
        # "PDF fallback not implemented"
        @test occursin("PackageScanner.extract_pdf_text(pdf_path)", content)
        @test occursin("find_paper_pdf(paper_dest_path)", content)
        @test occursin("report-claims-extraction.md", content)
        @test occursin("if true", content)  # do_claims baked in

        # Nested-zip handling for the paper-source fetch (JPE-Reproducibility/
        # JPE.jl's paper-source-round-fallback fix): catches a future edit
        # that reverts to a flat copy and silently drops .tex files locked
        # inside e.g. "Paper + figs + bib.zip".
        @test occursin("nested paper-source ZIP", content)
        @test occursin("vars[\"paper_source_dropbox_rel_path\"]", content)
        # ... and not the old (wrong-round) key for this specific lookup
        @test !occursin("vars[\"dropbox_rel_path\"], vars[\"paper_source_subfolder\"]", content)
    end
end

@testset "write_runner_script - do_claims=false skips Stage C at runtime" begin
    mktempdir() do repoloc
        JPE.write_runner_script(repoloc, ["__MACOSX", "renv"]; run_checks = true, do_claims = false)
        content = read(joinpath(repoloc, "runner_precheck.jl"), String)
        parsed = Meta.parseall(content)
        @test !(parsed isa Expr && parsed.head == :incomplete)
        @test occursin("if false", content)
    end
end

@testset "write_runner_script - Stage D splice parses and wires in the helpers" begin
    mktempdir() do repoloc
        JPE.write_runner_script(repoloc, ["__MACOSX", "renv"]; run_checks = true, do_claims = true, do_crosscheck = true)
        content = read(joinpath(repoloc, "runner_precheck.jl"), String)

        parsed = Meta.parseall(content)
        @test !(parsed isa Expr && parsed.head == :incomplete)

        for name in ("CROSSCHECK_JSON_SCHEMA", "crosscheck_prompt", "build_crosscheck_cmd",
                     "run_claude_crosscheck", "compute_coverage", "render_crosscheck_report",
                     "read_or_placeholder")
            @test occursin(name, content)
        end

        @test occursin("report-crosscheck.md", content)
        @test occursin("crosscheck.json", content)
    end
end

@testset "write_runner_script - do_crosscheck=false (default) skips Stage D at runtime" begin
    mktempdir() do repoloc
        JPE.write_runner_script(repoloc, ["__MACOSX", "renv"]; run_checks = true, do_claims = true)
        content = read(joinpath(repoloc, "runner_precheck.jl"), String)
        parsed = Meta.parseall(content)
        @test !(parsed isa Expr && parsed.head == :incomplete)
        # Stage D helpers are always spliced in (harmless if unused), but the
        # orchestration block itself must be gated off by default.
        @test occursin("if false", content)
    end
end
