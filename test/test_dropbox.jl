

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