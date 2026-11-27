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

@testset "write_runner_script - Stage C splice parses and wires in PackageScanner calls" begin
    mktempdir() do repoloc
        JPE.write_runner_script(repoloc, ["__MACOSX", "renv"]; run_checks = true, do_claims = true)
        content = read(joinpath(repoloc, "runner_precheck.jl"), String)

        # must be valid, complete Julia (a rename in PackageScanner.jl's
        # claims_extraction.jl that leaves a stale call site here would
        # otherwise only be caught on the runner, mid-run)
        parsed = Meta.parseall(content)
        @test !(parsed isa Expr && parsed.head == :incomplete)

        @test occursin("using PackageScanner", content)

        # the PackageScanner functions this block calls must actually be
        # referenced by their qualified name -- catches a rename in
        # PackageScanner.jl that forgets to update the orchestration block
        # below it (JPE-Reproducibility/PackageScanner.jl#21, this repo's #54:
        # these used to be spliced-in source text, now real package calls)
        @test occursin("PackageScanner.run_claude_claims_extraction", content)
        @test occursin("PackageScanner.find_paper_pdf(paper_dest_path)", content)

        @test occursin("PackageScanner.extract_latex_text(paper_dest_path)", content)
        # PDF fallback (JPE-Reproducibility/PackageScanner.jl extract_pdf_text):
        # catches a future edit that drops this branch and silently reverts to
        # "PDF fallback not implemented"
        @test occursin("PackageScanner.extract_pdf_text(pdf_path)", content)
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

@testset "write_runner_script - Stage D splice parses and wires in PackageScanner calls" begin
    mktempdir() do repoloc
        JPE.write_runner_script(repoloc, ["__MACOSX", "renv"]; run_checks = true, do_claims = true, do_crosscheck = true)
        content = read(joinpath(repoloc, "runner_precheck.jl"), String)

        parsed = Meta.parseall(content)
        @test !(parsed isa Expr && parsed.head == :incomplete)

        for name in ("PackageScanner.run_claude_crosscheck", "PackageScanner.compute_coverage",
                     "PackageScanner.render_crosscheck_report", "PackageScanner.read_or_placeholder")
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
        # the orchestration block itself must be gated off by default.
        @test occursin("if false", content)
    end
end
