@testset "url_encode_path" begin
    @test JPE.url_encode_path("report.md") == "report.md"
    @test JPE.url_encode_path("report with spaces.md") == "report%20with%20spaces.md"
    @test JPE.url_encode_path("sub/report.md") == "sub/report.md"
end

@testset "dbox_folder_file_link" begin
    @test JPE.dbox_folder_file_link("https://dropbox.example/large-reports", "report-pii-appendix.md") ==
          "https://dropbox.example/large-reports?preview=report-pii-appendix.md"
    @test JPE.dbox_folder_file_link("https://dropbox.example/large-reports?rlkey=abc&dl=0", "report-pii-appendix.md") ==
          "https://dropbox.example/large-reports?rlkey=abc&dl=0&preview=report-pii-appendix.md"
end

@testset "cap_and_route_reports! - never touches REPORTS_NEVER_CAPPED, even when oversized" begin
    mktempdir() do gen_dir
        mktempdir() do dest_dir
            oversized = join(["line $i" for i in 1:30], "\n") * "\n"
            for fname in JPE.REPORTS_NEVER_CAPPED
                write(joinpath(gen_dir, fname), oversized)
            end
            write(joinpath(gen_dir, "report-pii.md"), oversized)

            routed = JPE.cap_and_route_reports!(gen_dir, dest_dir, "https://dropbox.example/large-reports")

            @test routed == ["report-pii.md"]
            for fname in JPE.REPORTS_NEVER_CAPPED
                @test read(joinpath(gen_dir, fname), String) == oversized
                @test !isfile(joinpath(dest_dir, fname))
            end
            @test countlines(joinpath(gen_dir, "report-pii.md")) < 30
        end
    end
end

@testset "is_appendix_file" begin
    @test JPE.is_appendix_file("report-pii-appendix.md")
    @test JPE.is_appendix_file("/some/path/generated/report-code-quality-appendix.md")
    @test !JPE.is_appendix_file("report-pii.md")
    @test !JPE.is_appendix_file("report-large-files.md")
end

@testset "cap_report_file! - appendix files always routed, regardless of size" begin
    mktempdir() do gen_dir
        mktempdir() do dest_dir
            p = joinpath(gen_dir, "report-pii-appendix.md")
            write(p, "one line only\n")
            fname = JPE.cap_report_file!(p, dest_dir, "https://dropbox.example/large-reports")
            @test fname == "report-pii-appendix.md"
            @test isfile(joinpath(dest_dir, "report-pii-appendix.md"))
            @test read(joinpath(dest_dir, "report-pii-appendix.md"), String) == "one line only\n"
            local_content = read(p, String)
            @test occursin("https://dropbox.example/large-reports?preview=report-pii-appendix.md", local_content)
            @test !occursin("one line only", local_content)
        end
    end
end

@testset "cap_report_file! - small main file left untouched" begin
    mktempdir() do gen_dir
        mktempdir() do dest_dir
            p = joinpath(gen_dir, "report-small.md")
            content = join(["line $i" for i in 1:5], "\n") * "\n"
            write(p, content)
            fname = JPE.cap_report_file!(p, dest_dir, "https://dropbox.example/large-reports")
            @test isnothing(fname)
            @test !isdir(dest_dir) || isempty(readdir(dest_dir))
            @test read(p, String) == content
        end
    end
end

@testset "cap_report_file! - oversized main file truncated to max_lines" begin
    mktempdir() do gen_dir
        mktempdir() do dest_dir
            p = joinpath(gen_dir, "report-large-files.md")
            content = join(["line $i" for i in 1:30], "\n") * "\n"
            write(p, content)
            fname = JPE.cap_report_file!(p, dest_dir, "https://dropbox.example/large-reports"; max_lines=20)
            @test fname == "report-large-files.md"
            @test read(joinpath(dest_dir, "report-large-files.md"), String) == content

            local_lines = readlines(p)
            @test local_lines[1:20] == ["line $i" for i in 1:20]
            @test !any(occursin("line 21", l) for l in local_lines)
            @test any(occursin("https://dropbox.example/large-reports?preview=report-large-files.md", l) for l in local_lines)
        end
    end
end

@testset "rewrite_appendix_links! - dead local link becomes a live Dropbox link" begin
    mktempdir() do gen_dir
        p = joinpath(gen_dir, "report-pii.md")
        write(p, "summary\n\n*See [Appendix](report-pii-appendix.md) for details.*\n")
        JPE.rewrite_appendix_links!(gen_dir, ["report-pii-appendix.md"], "https://dropbox.example/large-reports")
        @test occursin("[Appendix](<https://dropbox.example/large-reports?preview=report-pii-appendix.md>)", read(p, String))
    end
end

@testset "cap_and_route_reports! - end to end on a realistic PII-style generated/ dir" begin
    mktempdir() do gen_dir
        mktempdir() do dest_dir
            write(joinpath(gen_dir, "report-pii.md"),
                  "## PII\n\nsummary\n\n*See [Appendix](report-pii-appendix.md) for details.*\n")
            write(joinpath(gen_dir, "report-pii-appendix.md"), "full detail\nmore detail\n")
            write(joinpath(gen_dir, "report-small.md"), "nothing to see here\n")
            write(joinpath(gen_dir, "report-large-files.md"),
                  join(["line $i" for i in 1:30], "\n") * "\n")

            routed = JPE.cap_and_route_reports!(gen_dir, dest_dir, "https://dropbox.example/large-reports"; max_lines=20)

            @test Set(routed) == Set(["report-pii-appendix.md", "report-large-files.md"])
            @test Set(readdir(dest_dir)) == Set(["report-pii-appendix.md", "report-large-files.md"])

            # main PII file: appendix link rewritten to a live Dropbox deep link
            pii_content = read(joinpath(gen_dir, "report-pii.md"), String)
            @test occursin("[Appendix](<https://dropbox.example/large-reports?preview=report-pii-appendix.md>)", pii_content)

            # small main file untouched
            @test read(joinpath(gen_dir, "report-small.md"), String) == "nothing to see here\n"

            # oversized main file truncated, full copy preserved in dest_dir
            @test countlines(joinpath(gen_dir, "report-large-files.md")) <= 23  # 20 kept + blank + 2-line note
            @test read(joinpath(dest_dir, "report-large-files.md"), String) ==
                  join(["line $i" for i in 1:30], "\n") * "\n"
        end
    end
end
