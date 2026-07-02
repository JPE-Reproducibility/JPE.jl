@testset "dispatch_remote_replication" begin

    token = JPE.dbox_token
    tag = "dispatch-rr-$(rand(UInt32))"
    pkg_path = "/testing/$tag/1/replication-package"

    upload_id = nothing
    download_url = nothing

    old_test_env = get(ENV, "JPE_TEST", nothing)
    ENV["JPE_TEST"] = "1"  # redirect any email sends to the DE's own address

    try
        # seed a fake but shareable dropbox folder for the "download" link
        JPE.dbox_upload_text(joinpath(pkg_path, "dummy.txt"), "hello from $tag", token)

        with_jpe_test_db(seed = false) do
            today_str = string(Dates.today())
            JPE.robust_db_operation() do con
                DBInterface.execute(con, """
                    INSERT INTO papers (
                        paper_id, journal, title,
                        firstname_of_author, surname_of_author,
                        email_of_author, paper_slug, status, round,
                        gh_org_repo, github_url,
                        file_request_path,
                        is_confidential, share_confidential,
                        first_arrival_date, date_with_authors,
                        comments
                    ) VALUES (
                        '88888888', 'JPE-TEST', 'Dispatch Remote Replication Test',
                        'Testa', 'Author',
                        'testa.author@example.com', '$tag', 'with_replicator', 1,
                        'JPE-Reproducibility/JPE-Test-88888888',
                        'https://github.com/org/repo',
                        '$pkg_path',
                        false, false,
                        '$today_str', '$today_str',
                        '[TEST]'
                    )
                """)
                DBInterface.execute(con, """
                    INSERT INTO iterations (
                        paper_id, journal, title,
                        firstname_of_author, surname_of_author,
                        email_of_author, paper_slug, round,
                        gh_org_repo, github_url,
                        replicator1,
                        file_request_path,
                        is_confidential, share_confidential,
                        first_arrival_date, date_with_authors,
                        comments
                    ) VALUES (
                        '88888888', 'JPE-TEST', 'Dispatch Remote Replication Test',
                        'Testa', 'Author',
                        'testa.author@example.com', '$tag', 1,
                        'JPE-Reproducibility/JPE-Test-88888888',
                        'https://github.com/org/repo',
                        'repl_dispatch_test@example.com',
                        '$pkg_path',
                        false, false,
                        '$today_str', '$today_str',
                        '[TEST]'
                    )
                """)
            end

            # --- first dispatch: creates a new upload file request ---
            res1 = JPE.dispatch_remote_replication("88888888"; deadline_days = 5)
            @test startswith(res1.upload_url, "https://")
            @test startswith(res1.download_url, "https://")

            it1 = JPE.db_filter_iteration("88888888", 1)
            @test !ismissing(it1[1, :replicator_upload_id])
            @test it1[1, :replicator_upload_url] == res1.upload_url
            upload_id = it1[1, :replicator_upload_id]

            # --- second dispatch: reuses the same upload link, just resets deadline ---
            # note: download link is revoked + recreated on every dispatch, so
            # res1.download_url is dead after this call — only res2's is live.
            res2 = JPE.dispatch_remote_replication("88888888"; deadline_days = 7)
            @test res2.upload_url == res1.upload_url
            download_url = res2.download_url

            it2 = JPE.db_filter_iteration("88888888", 1)
            @test it2[1, :replicator_upload_id] == upload_id
        end

    finally
        if !isnothing(upload_id)
            try
                JPE.dbox_delete_file_request(upload_id, token)
            catch e
                @warn "Could not delete test file request" exception=e
            end
        end
        if !isnothing(download_url)
            try
                JPE.dbox_revoke_link(download_url, token)
            catch e
                @warn "Could not revoke test download link" exception=e
            end
        end
        try
            JPE.dbox_delete_path("/testing/$tag", token)
        catch e
            @warn "Could not delete test dropbox folder" exception=e
        end
        if isnothing(old_test_env)
            delete!(ENV, "JPE_TEST")
        else
            ENV["JPE_TEST"] = old_test_env
        end
    end

end
