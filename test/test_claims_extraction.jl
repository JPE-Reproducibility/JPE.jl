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
