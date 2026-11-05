
# Automated referee review via refine.ink (https://api.refine.ink/docs).
#
# Deliberately NOT folded into preprocess()'s runner_precheck.jl like Stage
# C/D: this call is slow (5-20+ min to process) and external, so it's kept as
# its own fire-and-forget step -- request_referee_review() uploads the PDF
# and starts processing, then returns immediately; check_referee_reviews()
# (mirroring monitor_file_requests() in actions.jl) is called later to pick
# up completed reviews and write a short digest, surfaced via ps().

const REFINE_BASE_URL = "https://api.refine.ink"
# The JPE refine.ink credits live on the "Journal of Political Economy" org,
# not the personal account behind JPE_REFINE (which has 0 paid credits) --
# every call must carry this header/query param or the API 403s with
# "no-credits" even though the org has a balance. Overridable via
# JPE_REFINE_ORG in case the org id ever changes or a different account is used.
const REFINE_ORGANIZATION = get(ENV, "JPE_REFINE_ORG", "org_36u32nIIdbgzrtFRjD4HVy64a5B")

function refine_token()
    token = get(ENV, "JPE_REFINE", nothing)
    isnothing(token) && error("JPE_REFINE environment variable not set")
    return token
end

"""
    find_pdf_in_dir(dir::String)

Look for a `.pdf` directly under `dir`. If none is found, fall back to
unzipping any `.zip` archive under `dir` (authors sometimes bundle the paper
PDF inside a zip, e.g. alongside appendices) into a temp dir and searching
that instead. Returns the full path to the first `.pdf` found, or `nothing`.
"""
function find_pdf_in_dir(dir::String)
    isdir(dir) || return nothing
    for (root, _, files) in walkdir(dir)
        for f in files
            endswith(lowercase(f), ".pdf") && return joinpath(root, f)
        end
    end
    for (root, _, files) in walkdir(dir)
        for f in files
            endswith(lowercase(f), ".zip") || continue
            zip_path = joinpath(root, f)
            tmp = mktempdir()
            try
                run(`unzip -oq $zip_path -d $tmp`)
            catch e
                @warn "could not unzip $zip_path while searching for paper PDF" exception=e
                continue
            end
            for (r2, _, files2) in walkdir(tmp)
                for f2 in files2
                    endswith(lowercase(f2), ".pdf") && return joinpath(r2, f2)
                end
            end
        end
    end
    return nothing
end

"""
    find_paper_pdf(author_dir::String, appendices_dir::String)

Pick which local Dropbox folder to search for the paper's PDF: prefer
`paper-author/`, else fall back to `paper-appendices/`. Within each folder,
checks bare `.pdf` files first, then `.pdf`s inside any `.zip` archive (see
`find_pdf_in_dir`). Returns `nothing` if neither folder yields one.
"""
function find_paper_pdf(author_dir::String, appendices_dir::String)
    pdf = find_pdf_in_dir(author_dir)
    isnothing(pdf) || return pdf
    return find_pdf_in_dir(appendices_dir)
end

"""
    refine_read_sse(url::String)

Read a refine.ink SSE progress stream and return the `result` payload of its
terminal `complete` event. Errors out on an `error` event or a stream that
ends without either.
"""
function refine_read_sse(url::String)
    result = nothing
    HTTP.open(:GET, url) do stream
        # Read in chunks via readavailable/eof rather than eachline(stream) --
        # HTTP.Stream has no internal buffering, so eachline reads one byte at
        # a time and warns about it (HTTP.Streams.jl#246).
        leftover = ""
        data_buf = ""
        while !eof(stream)
            leftover *= String(readavailable(stream))
            while (nl = findfirst('\n', leftover)) !== nothing
                line = rstrip(leftover[1:nl-1], '\r')
                leftover = leftover[nl+1:end]
                if isempty(line)
                    isempty(data_buf) && continue
                    evt = JSON.parse(data_buf)
                    data_buf = ""
                    if evt["type"] == "complete"
                        result = evt["result"]
                        return
                    elseif evt["type"] == "error"
                        error("refine.ink SSE error: $(get(evt, "error", evt))")
                    end
                elseif startswith(line, "data:")
                    data_buf *= strip(line[6:end])
                end
            end
        end
    end
    isnothing(result) && error("refine.ink SSE stream at $url ended without a complete event")
    return result
end

"""
    refine_upload_document(filepath::String)

Upload a PDF to refine.ink and wait (via SSE) for conversion to finish.
Returns the resulting `document_id`.
"""
function refine_upload_document(filepath::String)
    isfile(filepath) || error("file not found: $filepath")
    token = refine_token()

    form = HTTP.Form(Dict("file" => HTTP.Multipart(basename(filepath), open(filepath), "application/pdf")))
    resp = HTTP.post("$REFINE_BASE_URL/documents/upload",
                      ["Authorization" => "Bearer $token", "X-Refine-Organization" => REFINE_ORGANIZATION],
                      form)
    data = JSON.parse(String(resp.body))

    events_url = "$REFINE_BASE_URL/documents/upload/events/$(data["task_id"])?token=$token&organization=$REFINE_ORGANIZATION"
    result = refine_read_sse(events_url)
    return result["document_id"]
end

"""
    refine_start_processing(document_id::String)

Start full proofreading (1 paid credit) for an already-uploaded document.
Returns the `review_id`; does NOT wait for the review to finish (that can
take 5-20+ min) -- see `check_referee_reviews()`.
"""
function refine_start_processing(document_id::String)
    token = refine_token()
    resp = HTTP.post("$REFINE_BASE_URL/documents/$document_id/process",
                      ["Authorization" => "Bearer $token", "Content-Type" => "application/json",
                       "X-Refine-Organization" => REFINE_ORGANIZATION],
                      JSON.json(Dict("preview" => false)))
    data = JSON.parse(String(resp.body))
    return data["review_id"]
end

"""
    refine_get_review(review_id::String)

Fetch the current state of a review (still-processing or completed).
"""
function refine_get_review(review_id::String)
    token = refine_token()
    resp = HTTP.get("$REFINE_BASE_URL/reviews/$review_id",
                     ["Authorization" => "Bearer $token", "X-Refine-Organization" => REFINE_ORGANIZATION])
    return JSON.parse(String(resp.body))
end

"""
    refine_build_digest(review::Dict)

Collapse a completed review into a one-line digest (comment count by
severity + the overall-feedback blurb) -- the full review stays on
refine.ink, this is just enough to glance at in `ps()`.
"""
function refine_build_digest(review::Dict)
    comments = review["feedback"]["detailed"]["comments"]
    by_sev = Dict{String,Int}()
    for c in comments
        sev = get(c, "severity", "unknown")
        by_sev[sev] = get(by_sev, sev, 0) + 1
    end
    sev_str = join(("$k:$v" for (k, v) in sort(collect(by_sev))), ", ")
    overall = get(get(review["feedback"], "overall", Dict()), "content", "")
    overall_short = length(overall) > 200 ? overall[1:200] * "…" : overall
    return "$(length(comments)) comment(s) [$sev_str] — $overall_short"
end

"""
    refine_build_report(review::Dict)

Render a completed review's full overall feedback and every comment
(sorted by severity) as markdown, for upload to Dropbox -- the DB digest
is just a glance, this is the thing to actually read.
"""
function refine_build_report(review::Dict)
    comments = review["feedback"]["detailed"]["comments"]
    overall = get(get(review["feedback"], "overall", Dict()), "content", "")
    sev_rank = Dict("critical" => 1, "major" => 2, "minor" => 3, "suggestion" => 4)
    sorted_comments = sort(comments, by = c -> get(sev_rank, get(c, "severity", "unknown"), 99))

    io = IOBuffer()
    println(io, "# Referee Review (refine.ink)")
    println(io)
    println(io, "- review_id: `$(get(review, "review_id", "?"))`")
    println(io, "- completed_at: $(get(review, "completed_at", "?"))")
    println(io, "- comments: $(length(comments))")
    println(io)
    println(io, "## Overall feedback")
    println(io)
    println(io, overall)
    for c in sorted_comments
        println(io)
        println(io, "## [$(uppercase(get(c, "severity", "unknown")))] $(get(c, "title", ""))")
        q = get(c, "quote", "")
        if !isempty(q)
            println(io)
            println(io, "> $q")
        end
        println(io)
        println(io, get(c, "message", ""))
    end
    return String(take!(io))
end

"""
    request_referee_review(paperID, round)

Upload the paper's PDF (from `paper-author/`, else `paper-appendices/`) to
refine.ink and kick off proofreading. Stores `refine_document_id`,
`refine_review_id`, and `refine_status = "processing"` on the iteration row
and returns immediately -- call `check_referee_reviews()` later to pick up
the result.
"""
function request_referee_review(paperID, round)
    rt = db_filter_iteration(paperID, round)
    nrow(rt) == 1 || error("can only get a single row here")
    r = rt[1, :]

    base_dir = get_dbox_loc(r.journal, r.paper_slug, round, full = true)
    pdf_path = find_paper_pdf(joinpath(base_dir, "paper-author"), joinpath(base_dir, "paper-appendices"))
    isnothing(pdf_path) && error("no PDF found under paper-author/ or paper-appendices/ for $paperID round $round")

    @info "uploading $pdf_path to refine.ink for referee review"
    document_id = refine_upload_document(pdf_path)
    review_id = refine_start_processing(document_id)

    cond = "paper_id = '$paperID' AND round = $round"
    db_update_cell("iterations", cond, "refine_document_id", document_id)
    db_update_cell("iterations", cond, "refine_review_id", review_id)
    db_update_cell("iterations", cond, "refine_status", "processing")
    @info "✓ referee review requested for $paperID round $round (review_id=$review_id) — check back with check_referee_reviews()"
    return review_id
end

"""
    check_referee_reviews()

Poll refine.ink for every iteration row currently `refine_status ==
"processing"`. For any that have completed: write a short digest, flip
status to `"done"`, and upload the full report to the paper's Dropbox
`large-reports/refine-referee-report.md` -- the same permanent, no-expiry
per-round Dropbox folder `preprocess()` already uses for oversized Stage
A-D reports (chosen over committing to the paper's git repo: no clone/push
round-trip, and this is DE-only anyway, same as those). Mirrors
`monitor_file_requests()`'s shape: best-effort per row, a failure on one
paper doesn't stop the rest.
"""
function check_referee_reviews()
    i = subset(db_df("iterations"), :refine_status => ByRow(x -> !ismissing(x) && x == "processing"))

    for r in eachrow(i)
        try
            review = refine_get_review(r.refine_review_id)
            cond = "paper_id = '$(r.paper_id)' AND round = $(r.round)"
            if review["processing_status"] == "completed"
                digest = refine_build_digest(review)
                db_update_cell("iterations", cond, "refine_digest", digest)
                db_update_cell("iterations", cond, "refine_status", "done")

                report_path = "/" * joinpath(r.journal, r.paper_slug, string(r.round), "large-reports", "refine-referee-report.md")
                try
                    dbox_upload_text(report_path, refine_build_report(review), dbox_token)
                    @info "✓ full referee report uploaded to Dropbox at $report_path"
                catch e
                    @warn "Could not upload referee report to Dropbox for $(r.paper_id) round $(r.round)" exception=e
                end

                @info "✓ referee review done for $(r.paper_id) round $(r.round): $digest"
            else
                @info "$(r.paper_id) round $(r.round): still processing ($(get(review, "progress_percentage", "?"))%)"
            end
        catch e
            @warn "Error checking refine review for $(r.paper_id) round $(r.round): $e"
        end
    end
end
