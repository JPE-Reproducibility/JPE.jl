
function create_example_DAS(; name = "Oswald", id = "12345678", journal = "JPE")

    journal == "JPE" ? (length(id) == 8 || error("id has 8 digits")) : (length(id) == 6 || error("id has 6 digits"))

    # setup folder structure

    haskey(ENV, "DROPBOX_JPE") || error("DROPBOX_JPE env var not set")

    jpe = dropbox()

    # paths
    root = joinpath(jpe, "package-arrivals", journal, join([name,id],"-"))
    mkpath(root)

    # cp dummy paper
    download("https://github.com/floswald/ReproWorkshop/blob/909557be932ddb69ef1977c02a2123ef9e83e844/paper/main.pdf",
    joinpath(root,"paper.pdf"))
    cp(joinpath(root,"paper.pdf"), joinpath(root,"appendix.pdf"))

    # add DAS from somewhere
    download("https://www.aeaweb.org/journals/forms/data-code-availability", joinpath(root, "DAS.pdf"))

    @info "done."

end

function create_example_package(; name = "Oswald", id = "12345678", journal = "JPE")

    journal == "JPE" ? (length(id) == 8 || error("id has 8 digits")) : (length(id) == 6 || error("id has 6 digits"))

    # setup folder structure

    haskey(ENV, "DROPBOX_JPE") || error("DROPBOX_JPE env var not set")

    jpe = dropbox()

    # paths
    pkg = joinpath(jpe, "test-packages", journal, join([name,id],"-"))
    mkpath(pkg)

    @info "creating example package at $pkg"

    mkpath(joinpath(pkg,"data"))
    mkpath(joinpath(pkg,"code"))
    mkpath(joinpath(pkg,"output"))
    

    # create data content
    ipath = joinpath(pkgdir(DataFrames), "docs", "src", "assets", "iris.csv")
    cp(ipath, joinpath(pkg,"data","iris.csv"), force = true)

    # create code content
    Pkg.generate(joinpath(pkg,"code","Oswald.jl"))

    # create a readme
    open(joinpath(pkg,"README.md"), "w") do io
        println(io, "# $name Replication Package - TEST PACKAGE")
        println(io, "\nIn this package you will find code, data and output for the $name package. Have fun! ✌️")
        println(io, "\nAs you can see, there is a lot of important info missing. Checkout [our readme](https://www.templatereadme.org) generator and our dedicated [website](https://jpedataeditor.github.io/) for more info.")
    end
    @info "done."

end