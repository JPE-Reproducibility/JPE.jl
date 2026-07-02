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
