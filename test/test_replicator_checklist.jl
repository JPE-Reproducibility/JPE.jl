@testset "crosscheck_checklist_section - not available when crosscheck.json missing" begin
    mktempdir() do gen_dir
        @test occursin("not available", JPE.crosscheck_checklist_section(gen_dir))
    end
end

@testset "crosscheck_checklist_section - lists Missing before Plausible, includes orphans" begin
    mktempdir() do gen_dir
        data = Dict(
            "verdicts" => [
                Dict("claim_type" => "table", "claim_label" => "tab:a", "verdict" => "Matched", "rationale" => "fine", "supporting_files" => []),
                Dict("claim_type" => "data_source", "claim_label" => "Census", "verdict" => "Plausible", "rationale" => "weak link", "supporting_files" => []),
                Dict("claim_type" => "figure", "claim_label" => "fig:b", "verdict" => "Missing", "rationale" => "no file", "supporting_files" => []),
            ],
            "coverage" => Dict("overall" => 66.7),
            "orphan_code_files" => ["scripts/unused.R"],
        )
        write(joinpath(gen_dir, "crosscheck.json"), JSON.json(data))

        section = JPE.crosscheck_checklist_section(gen_dir)
        @test occursin("66.7%", section)
        @test occursin("fig:b", section)
        @test occursin("Census", section)
        @test !occursin("tab:a", section)
        @test occursin("scripts/unused.R", section)

        missing_pos = findfirst("fig:b", section)
        plausible_pos = findfirst("Census", section)
        @test first(missing_pos) < first(plausible_pos)
    end
end

@testset "crosscheck_checklist_section - all matched, no orphans" begin
    mktempdir() do gen_dir
        data = Dict(
            "verdicts" => [Dict("claim_type" => "table", "claim_label" => "tab:a", "verdict" => "Matched", "rationale" => "fine", "supporting_files" => [])],
            "coverage" => Dict("overall" => 100.0),
            "orphan_code_files" => [],
        )
        write(joinpath(gen_dir, "crosscheck.json"), JSON.json(data))
        section = JPE.crosscheck_checklist_section(gen_dir)
        @test occursin("No claims came back", section)
        @test !occursin("worth a \"what does this actually do\"", section)
    end
end

@testset "readme_structure_checklist_section - not available when report missing" begin
    mktempdir() do gen_dir
        @test occursin("not available", JPE.readme_structure_checklist_section(gen_dir))
    end
end

@testset "readme_structure_checklist_section - extracts missing sections only" begin
    mktempdir() do gen_dir
        write(joinpath(gen_dir, "report-readme-structure.md"), """
        ### README Structure Audit

        #### Required Section Checklist

        - ✅ Data availability / sources: mentioned on line 4
        - ❌ Software requirements: not found
        - ❌ License / terms of use: not found
        """)
        section = JPE.readme_structure_checklist_section(gen_dir)
        @test occursin("Software requirements: not found", section)
        @test occursin("License / terms of use: not found", section)
        @test !occursin("Data availability", section)
    end
end

@testset "readme_structure_checklist_section - nothing missing" begin
    mktempdir() do gen_dir
        write(joinpath(gen_dir, "report-readme-structure.md"), "- ✅ Software requirements: mentioned on line 3\n")
        @test occursin("All required README sections were found", JPE.readme_structure_checklist_section(gen_dir))
    end
end

@testset "readme_review_checklist_section - not available when report missing" begin
    mktempdir() do gen_dir
        @test occursin("not available", JPE.readme_review_checklist_section(gen_dir))
    end
end

@testset "readme_review_checklist_section - extracts Final Assessment section" begin
    mktempdir() do gen_dir
        write(joinpath(gen_dir, "report-readme-review.md"), """
        # README Review (LLM)

        ## 1. Title and Overview

        Yes, addressed fully.

        ## Final Assessment

        - Verdict: Needs minor revision
        - Fix the license section first
        """)
        section = JPE.readme_review_checklist_section(gen_dir)
        @test occursin("Needs minor revision", section)
        @test occursin("Fix the license section first", section)
        @test !occursin("Title and Overview", section)
    end
end

@testset "readme_review_checklist_section - no Final Assessment heading present" begin
    mktempdir() do gen_dir
        write(joinpath(gen_dir, "report-readme-review.md"), "# README Review\n\nsome content, no final section\n")
        @test occursin("no \"## Final Assessment\" section", JPE.readme_review_checklist_section(gen_dir))
    end
end

@testset "refine_checklist_section - not started / not done" begin
    @test occursin("not available", JPE.refine_checklist_section(missing, missing, nothing))
    @test occursin("not available", JPE.refine_checklist_section("processing", missing, nothing))
end

@testset "refine_checklist_section - done, with digest and link" begin
    section = JPE.refine_checklist_section("done", "72 comment(s) [major:10, minor:35, suggestion:27] — summary here",
                                            "https://dropbox.example/large-reports?preview=refine-referee-report.md")
    @test occursin("72 comment(s)", section)
    @test occursin("https://dropbox.example/large-reports?preview=refine-referee-report.md", section)
end

@testset "refine_checklist_section - done, no digest recorded" begin
    section = JPE.refine_checklist_section("done", missing, nothing)
    @test occursin("no digest recorded", section)
end
