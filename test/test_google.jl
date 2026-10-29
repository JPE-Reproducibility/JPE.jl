@testset "replicator_start_date" begin

    @test ismissing(JPE.replicator_start_date("no-such-replicator@nowhere.test"))

end

@testset "retire_replicators! - not_found / already_former (JPE_TEST skip path)" begin

    # force the JPE_TEST sheet-write-skipping branch, regardless of the
    # ambient env, so this test never touches the live Google Sheet or
    # GitHub org
    old_test_env = get(ENV, "JPE_TEST", nothing)
    ENV["JPE_TEST"] = "1"

    try
        confirmed = DataFrame(
            "Name" => ["Alice", "Bob", "Carol"],
            "email" => ["alice@x.com", "bob@x.com", "carol@x.com"],
            "OS" => ["mac", "win", "linux"],
            "github username" => ["alice-gh", "bob-gh", "carol-gh"],
            "current_workload" => [0, 1, 2]
        )
        former = DataFrame(
            name = ["Dave"], email = ["dave@x.com"], os = ["mac"], github_username = ["dave-gh"],
            started = [Date(2020, 1, 1)], left = [Date(2021, 1, 1)]
        )

        r = JPE.retire_replicators!(["bob@x.com", "dave@x.com", "zzz@nowhere.com"];
            left = Date(2026, 1, 1),
            auth = () -> nothing,
            get_confirmed = () -> confirmed,
            get_former = () -> former
        )

        @test r.retired == ["bob@x.com"]
        @test r.not_found == ["zzz@nowhere.com"]
        @test r.already_former == ["dave@x.com"]
    finally
        if isnothing(old_test_env)
            delete!(ENV, "JPE_TEST")
        else
            ENV["JPE_TEST"] = old_test_env
        end
    end

end

@testset "retire_replicators! - GitHub org removal + sheet writes (stubbed)" begin

    # exercise the non-JPE_TEST branch, but with every side-effecting
    # function injected as a stub, so nothing live (Sheets or GitHub) is
    # ever touched by this test
    old_test_env = get(ENV, "JPE_TEST", nothing)
    delete!(ENV, "JPE_TEST")

    try
        confirmed = DataFrame(
            "Name" => ["Alice", "Bob", "Carol"],
            "email" => ["alice@x.com", "bob@x.com", "carol@x.com"],
            "OS" => ["mac", "win", "linux"],
            "github username" => ["alice-gh", "bob-gh", missing],
            "current_workload" => [0, 1, 2]
        )
        former = DataFrame(
            name = String[], email = String[], os = String[], github_username = String[],
            started = Union{Missing,Date}[], left = Date[]
        )

        removed_calls = String[]
        appended = Ref{Any}(nothing)
        deleted_rows = Ref{Any}(nothing)

        r = JPE.retire_replicators!(["alice@x.com", "carol@x.com"];
            left = Date(2026, 1, 1),
            auth = () -> nothing,
            get_confirmed = () -> confirmed,
            get_former = () -> former,
            remove_org_member = u -> (push!(removed_calls, u); u != "bob-gh"),
            append_former = d -> (appended[] = d),
            delete_confirmed_rows = rows -> (deleted_rows[] = rows)
        )

        @test r.retired == ["alice@x.com", "carol@x.com"]
        @test r.gh_removed == ["alice-gh"]
        @test r.no_gh_username == ["carol@x.com"]
        @test r.gh_failed == String[]
        @test removed_calls == ["alice-gh"]

        @test appended[].email == ["alice@x.com", "carol@x.com"]
        # Alice is confirmed-row 1, Carol is confirmed-row 3; +1 for the header
        # row gives their 1-indexed Sheets row numbers
        @test deleted_rows[] == [2, 4]
    finally
        if isnothing(old_test_env)
            delete!(ENV, "JPE_TEST")
        else
            ENV["JPE_TEST"] = old_test_env
        end
    end

end
