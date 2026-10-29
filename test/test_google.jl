@testset "replicator_start_date" begin

    @test ismissing(JPE.replicator_start_date("no-such-replicator@nowhere.test"))

end

@testset "retire_replicators!" begin

    # force the JPE_TEST sheet-write-skipping branch, regardless of the
    # ambient env, so this test never touches the live Google Sheet
    old_test_env = get(ENV, "JPE_TEST", nothing)
    ENV["JPE_TEST"] = "1"

    try
        confirmed = DataFrame(
            name = ["Alice", "Bob", "Carol"],
            email = ["alice@x.com", "bob@x.com", "carol@x.com"],
            os = ["mac", "win", "linux"],
            current_workload = [0, 1, 2]
        )
        former = DataFrame(
            name = ["Dave"], email = ["dave@x.com"], os = ["mac"],
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
