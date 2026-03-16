
@testset "public dropbox link: create, download via curl, revoke" begin
    test_path = "/testing/jpe_test_public_link.txt"
    content   = "hello from JPE test $(rand(UInt32))"
    token     = JPE.dbox_token
    link_url  = nothing
    tmp_file  = tempname()

    try
        # 1. Upload a small text file to /testing/
        JPE.dbox_upload_text(test_path, content, token)

        # 2. Create a public shared link
        link_url = JPE.dbox_link_at_path(test_path, token)
        @test !isempty(link_url)
        @test startswith(link_url, "https://")

        # 3. Download via plain curl — no password needed
        dl_url = replace(link_url, "dl=0" => "dl=1")
        run(`curl -L -s -f -o $tmp_file $dl_url`)

        # 4. Verify content matches
        @test String(read(tmp_file)) == content

    finally
        if !isnothing(link_url)
            try
                JPE.dbox_revoke_link(link_url, token)
            catch e
                @warn "Could not revoke test link" exception=e
            end
        end
        try
            JPE.dbox_delete_path(test_path, token)
        catch e
            @warn "Could not delete test file $test_path" exception=e
        end
        isfile(tmp_file) && rm(tmp_file)
    end
end

@testset "deleting a package folder" begin
    dir = mktempdir()
    v1 = joinpath(dir,"1")
    v2 = joinpath(dir,"2")
    mkpath(v1)
    mkpath(v2)
    JPE.make_test_package(v1)
    JPE.make_test_package(v2)

    @test folder_size(v1) > 2.9  # more than 3MB

    t1 = JPE.delete_location([v1],dryrun = false)
    @test folder_size(v1) < 2.5  # less than 2.5MB

    JPE.make_test_package(v1)
    @test folder_size(v1) > 2.9  # more than 3MB

    s1 = folder_size(v1)

    JPE.delete_location([v1,v2],dryrun = true)
    @test folder_size(v1) + folder_size(v1) == 2s1

    JPE.delete_location([v1,v2],dryrun = false)
    @test folder_size(v1) + folder_size(v2) < 4.1

    rm(dir,recursive = true, force = true)

end