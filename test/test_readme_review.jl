@testset "readme_review_prompt - loads the vendored rubric file" begin
    prompt = JPE.readme_review_prompt()
    @test occursin("README review (SSDE Template)", prompt)
    @test occursin("Data Availability and Provenance Statements", prompt)
    @test occursin("Appendix: references/package-checks.md", prompt)
    @test occursin("Appendix: references/style-guide.md", prompt)
end

@testset "find_readme_in_dir - no README anywhere returns nothing" begin
    mktempdir() do dir
        @test isnothing(JPE.find_readme_in_dir(dir))
    end
end

@testset "find_readme_in_dir - finds a markdown README" begin
    mktempdir() do dir
        sub = joinpath(dir, "replication package for some paper")
        mkpath(sub)
        write(joinpath(sub, "README.md"), "# Replication package")
        @test JPE.find_readme_in_dir(dir) == (joinpath(sub, "README.md"), :md)
    end
end

@testset "find_readme_in_dir - falls back to .txt when no .md exists" begin
    mktempdir() do dir
        write(joinpath(dir, "README.txt"), "plain text readme")
        @test JPE.find_readme_in_dir(dir) == (joinpath(dir, "README.txt"), :txt)
    end
end

@testset "find_readme_in_dir - falls back to .pdf when no .md or .txt exists" begin
    mktempdir() do dir
        write(joinpath(dir, "README.pdf"), "not really a pdf but doesn't matter for this test")
        @test JPE.find_readme_in_dir(dir) == (joinpath(dir, "README.pdf"), :pdf)
    end
end

@testset "find_readme_in_dir - prefers .md over .txt and .pdf when multiple exist" begin
    mktempdir() do dir
        write(joinpath(dir, "README.pdf"), "pdf")
        write(joinpath(dir, "README.txt"), "txt")
        write(joinpath(dir, "README.md"), "md")
        @test JPE.find_readme_in_dir(dir) == (joinpath(dir, "README.md"), :md)
    end
end

@testset "find_readme_in_dir - prefers .txt over .pdf when no .md exists" begin
    mktempdir() do dir
        write(joinpath(dir, "README.pdf"), "pdf")
        write(joinpath(dir, "README.txt"), "txt")
        @test JPE.find_readme_in_dir(dir) == (joinpath(dir, "README.txt"), :txt)
    end
end

@testset "find_readme_in_dir - skips __MACOSX junk" begin
    mktempdir() do dir
        junk = joinpath(dir, "__MACOSX")
        mkpath(junk)
        write(joinpath(junk, "README.md"), "junk")
        @test isnothing(JPE.find_readme_in_dir(dir))

        write(joinpath(dir, "README.md"), "# real one")
        @test JPE.find_readme_in_dir(dir) == (joinpath(dir, "README.md"), :md)
    end
end

@testset "readme_review_source_text_path - md/txt pass through unchanged" begin
    mktempdir() do dir
        md_path = joinpath(dir, "README.md")
        write(md_path, "# hi")
        @test JPE.readme_review_source_text_path(md_path, :md) == md_path

        txt_path = joinpath(dir, "README.txt")
        write(txt_path, "hi")
        @test JPE.readme_review_source_text_path(txt_path, :txt) == txt_path
    end
end

@testset "build_claude_readme_review_cmd - flags, env, states README and package paths verbatim" begin
    withenv("CLAUDE_CONFIG_DIR" => "/custom/claude-config") do
        mktempdir() do dir
            readme_path = joinpath(dir, "README.md")
            write(readme_path, "# hi")
            cmd = JPE.build_claude_readme_review_cmd(readme_path, dir; effort = "high")
            cmd_str = string(cmd)
            @test occursin("--safe-mode", cmd_str)
            @test occursin("Read", cmd_str)
            @test occursin("Glob", cmd_str)
            @test occursin("Grep", cmd_str)
            @test occursin("--json-schema", cmd_str)
            @test occursin("review_markdown", cmd_str)
            @test occursin("edited_readme_markdown", cmd_str)
            @test occursin("CLAUDE_CONFIG_DIR=/custom/claude-config", cmd_str)
            @test occursin("--add-dir", cmd_str)
            @test occursin(readme_path, cmd_str)
            @test occursin(dir, cmd_str)
            @test occursin("--effort", cmd_str)

            # the vendored rubric must still be present under the JPE-specific
            # override preamble, not replaced by it
            @test occursin("README review (SSDE Template)", cmd_str)
            @test occursin("You do not have a", cmd_str) && occursin("Write", cmd_str)
        end
    end
end
