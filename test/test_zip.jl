@testset "aggregate_dir_sizes" begin
    # a single wrapper dir containing one large buried folder — the wrapper
    # should be suppressed in favor of the specific folder that carries the bulk
    entries = [
        (size = 0, path = "PackageName/"),
        (size = 0, path = "PackageName/confidential-data-do-not-publish/"),
        (size = 5_242_880, path = "PackageName/confidential-data-do-not-publish/big.dat"),
        (size = 0, path = "PackageName/code/"),
        (size = 3, path = "PackageName/code/main.R"),
    ]
    flagged = JPE.aggregate_dir_sizes(entries; threshold_gb = 0.001)
    @test length(flagged) == 1
    @test flagged[1].path == "PackageName/confidential-data-do-not-publish"

    # nothing exceeds a high threshold
    @test isempty(JPE.aggregate_dir_sizes(entries; threshold_gb = 1.0))

    # two independent large folders under the same wrapper: both should surface
    entries2 = [
        (size = 3_000_000_000, path = "Pkg/data-A/big1.dat"),
        (size = 3_000_000_000, path = "Pkg/data-B/big2.dat"),
        (size = 10, path = "Pkg/code/main.R"),
    ]
    flagged2 = JPE.aggregate_dir_sizes(entries2; threshold_gb = 1.0)
    paths2 = Set(f.path for f in flagged2)
    @test "Pkg/data-A" in paths2
    @test "Pkg/data-B" in paths2
    # "Pkg" itself is also flagged and NOT suppressed: neither single child
    # dominates it (each is ~50% of the total), so the suppression rule
    # (descendant carrying ~all of an ancestor's bytes) correctly doesn't fire.
    @test "Pkg" in paths2
end

@testset "zip_entry_sizes + read_and_unzip_directory + local_file_md5s exclude" begin
    workdir = mktempdir()
    src = joinpath(workdir, "src")
    mkpath(joinpath(src, "PackageName", "confidential-data-do-not-publish"))
    mkpath(joinpath(src, "PackageName", "code"))
    write(joinpath(src, "PackageName", "code", "main.R"), "print('hi')")
    write(joinpath(src, "PackageName", "confidential-data-do-not-publish", "big.dat"), rand(UInt8, 1_000_000))

    zip_path = joinpath(workdir, "pkg.zip")
    run(Cmd(`zip -rq $zip_path PackageName`, dir = src))

    entries = JPE.zip_entry_sizes(zip_path)
    @test any(e -> e.path == "PackageName/code/main.R", entries)
    flagged = JPE.aggregate_dir_sizes(entries; threshold_gb = 0.0001)
    @test any(f -> f.path == "PackageName/confidential-data-do-not-publish", flagged)

    root = joinpath(workdir, "replication-package")
    mkdir(root)
    cp(zip_path, joinpath(root, "pkg.zip"))

    hashes = JPE.local_file_md5s(root; exclude = ["PackageName/confidential-data-do-not-publish"])
    paths = Set(v.path for v in values(hashes))
    @test "PackageName/code/main.R" in paths
    @test !any(p -> occursin("confidential-data-do-not-publish", p), paths)
end
