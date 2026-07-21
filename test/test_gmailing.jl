@testset "gmail_remote_replication" begin

    body = JPE.gmail_remote_replication_body(
        "Alice",
        "Bob",
        "TEST-CASEID",
        "https://dropbox.com/download",
        "https://github.com/org/repo",
        "https://dropbox.com/upload"
    )

    @test occursin("Alice", body)
    @test occursin("Bob", body)
    @test occursin("TEST-CASEID", body)
    @test occursin("https://dropbox.com/download", body)
    @test occursin("https://github.com/org/repo", body)
    @test occursin("https://dropbox.com/upload", body)
    @test occursin("remote-protocol.html", body)

end

@testset "gmail_file_request_body" begin

    body_no_paper = JPE.gmail_file_request_body(
        "Jane",
        "TEST-CASEID",
        "A Great Paper",
        "https://dropbox.com/request/pkg"
    )

    @test occursin("Jane", body_no_paper)
    @test occursin("TEST-CASEID", body_no_paper)
    @test occursin("https://dropbox.com/request/pkg", body_no_paper)
    @test !occursin("also share the latest version", body_no_paper)

    body_with_paper = JPE.gmail_file_request_body(
        "Jane",
        "TEST-CASEID",
        "A Great Paper",
        "https://dropbox.com/request/pkg",
        "https://dropbox.com/request/paper"
    )

    @test occursin("https://dropbox.com/request/pkg", body_with_paper)
    @test occursin("https://dropbox.com/request/paper", body_with_paper)
    @test occursin("also share the latest version", body_with_paper)

end
