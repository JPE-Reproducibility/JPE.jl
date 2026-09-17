@testset "dv_replace_files (demo.dataverse.org)" begin
    if !haskey(ENV, "DV_DEMO_API")
        @info "Skipping dv_replace_files integration test — set DV_DEMO_API to enable."
    else
        base_url = JPE.dvdemoserver()
        api_token = JPE.dvdemotoken()
        headers = Dict("X-Dataverse-key" => api_token)

        # create a throwaway dataset with one file in a subfolder
        dataset_metadata = Dict(
            "datasetVersion" => Dict("metadataBlocks" => Dict("citation" => Dict("fields" => [
                Dict("typeName" => "title", "typeClass" => "primitive", "multiple" => false, "value" => "JPE.jl test dataset"),
                Dict("typeName" => "author", "typeClass" => "compound", "multiple" => true,
                    "value" => [Dict("authorName" => Dict("typeName" => "authorName", "typeClass" => "primitive", "multiple" => false, "value" => "JPE.jl CI"))]),
                Dict("typeName" => "datasetContact", "typeClass" => "compound", "multiple" => true,
                    "value" => [Dict(
                        "datasetContactName" => Dict("typeName" => "datasetContactName", "typeClass" => "primitive", "multiple" => false, "value" => "JPE.jl CI"),
                        "datasetContactEmail" => Dict("typeName" => "datasetContactEmail", "typeClass" => "primitive", "multiple" => false, "value" => "jpe.dataeditor@gmail.com"),
                    )]),
                Dict("typeName" => "dsDescription", "typeClass" => "compound", "multiple" => true,
                    "value" => [Dict("dsDescriptionValue" => Dict("typeName" => "dsDescriptionValue", "typeClass" => "primitive", "multiple" => false, "value" => "Ephemeral test fixture for dv_replace_files."))]),
                Dict("typeName" => "subject", "typeClass" => "controlledVocabulary", "multiple" => true, "value" => ["Other"]),
            ])))
        )
        resp = HTTP.post("$base_url/api/dataverses/demo/datasets", headers, JSON.json(dataset_metadata); status_exception = false)
        @test resp.status == 201
        doi = JSON.parse(String(resp.body))["data"]["persistentId"]

        form = HTTP.Form(Dict(
            "file" => HTTP.Multipart("original.txt", IOBuffer("original\n"), "text/plain"),
            "jsonData" => JSON.json(Dict("description" => "original", "directoryLabel" => "code/subdir", "categories" => ["Data"])),
        ))
        upload = HTTP.post("$base_url/api/datasets/:persistentId/add?persistentId=$doi", headers, form; status_exception = false, retry = false)
        @test upload.status == 200

        tmpfile = joinpath(mktempdir(), "replacement.txt")
        write(tmpfile, "replaced by test\n")

        # dry run resolves correctly and writes nothing
        plan = JPE.dv_replace_files(doi, Dict("original.txt" => tmpfile); dry_run = true, base_url = base_url, api_token = api_token)
        @test plan[1, :status] == "ok"
        @test plan[1, :directory_label] == "code/subdir"

        # real replace preserves directoryLabel/description/categories and verifies md5
        plan2 = JPE.dv_replace_files(doi, Dict("original.txt" => tmpfile); dry_run = false, base_url = base_url, api_token = api_token)
        @test plan2[1, :result] == "ok"
        @test plan2[1, :directory_label_verified] === true
        @test plan2[1, :md5_verified] === true

        # unresolvable filename is reported, not attempted
        bad = JPE.dv_replace_files(doi, Dict("does_not_exist.txt" => tmpfile); base_url = base_url, api_token = api_token)
        @test bad[1, :status] == "not found in dataset"
    end
end
