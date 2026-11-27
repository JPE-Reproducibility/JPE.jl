@testset "gmail_assign_body - no checklist_url, no checklist section at all" begin
    body = JPE.gmail_assign_body("Jane", "TEST-CASEID", "https://dropbox.com/download", "https://github.com/org/repo")
    @test occursin("Jane", body)
    @test occursin("TEST-CASEID", body)
    @test !occursin("Replicator Checklist", body)
    @test !occursin("copy-paste", body)
end

@testset "gmail_assign_body - with checklist_url, link and caveat both present" begin
    checklist_url = "https://github.com/org/repo/blob/round1/generated/report-replicator-checklist.md"
    body = JPE.gmail_assign_body("Jane", "TEST-CASEID", "https://dropbox.com/download", "https://github.com/org/repo"; checklist_url = checklist_url)
    @test occursin("Replicator Checklist", body)
    @test occursin(checklist_url, body)
    @test occursin("copy-paste", body)
    @test occursin("substitute for your own review", body)
end

@testset "gmail_assign_body - back=true still includes checklist row when given" begin
    checklist_url = "https://github.com/org/repo/blob/round2/generated/report-replicator-checklist.md"
    body = JPE.gmail_assign_body("Jane", "TEST-CASEID", "https://dropbox.com/download", "https://github.com/org/repo"; back = true, checklist_url = checklist_url)
    @test occursin("is back for the next round", body)
    @test occursin(checklist_url, body)
end

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

@testset "gmail_g2g_body" begin

    body = JPE.gmail_g2g_body(
        "Jane",
        "TEST-CASEID",
        "A Great Paper",
        "Data are available upon request."
    )

    @test occursin("Jane", body)
    @test occursin("TEST-CASEID", body)
    @test occursin("A Great Paper", body)
    @test occursin("Data are available upon request.", body)
    @test occursin("Please <b>remove</b> the following items", body)
    # inline code span stays unstyled: no CSS to be mangled by strict mail clients
    @test occursin("<code>[INSERT YOUR DOI HERE]</code>", body)
    @test !occursin("<pre>", body)
    @test !occursin("<code style", body)
    @test occursin("<ol>", body)
    @test occursin("Any letter or communication for the Data Editor.", body)
    @test occursin("Any confidential data which you do not intend to publish.", body)
    @test occursin("tex source", body)
    @test occursin("copyright rules of the JPE", body)

end
