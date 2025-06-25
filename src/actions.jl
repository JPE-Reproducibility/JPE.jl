
function assign(paperID,rep1; rep2 = nothing)
    # assign paper_id to rep1, optionally also rep2

    # get row paper_id from papers, call it r

    # add new row to "iterations" table, filling in date_assigned_repl and date_arrived_from_authors via `dbox_fr_submit_time(token, r.file_request_path_current)`

    # set r.status = with_replicator

    # send email to replicators

end

# list all papers that have been invited to submit
function list_arrivals_waiting()
    # 1. read papers table
    papers = db_df("papers")

    # 2. find papers with status "new_arrival" and round 1

    # 3. return those IDs

end

function collect_reports()
    # First, read any new reports from the Google form
    read_google_reports(; append = true)
    
    # Now get all reports from the reports table
    all_reports = db_df("reports")

    # make a backup of iterations
    db_write_backup("iterations", db_df("iterations"))

    
    if nrow(all_reports) > 0
        # Find reports that need to be processed
        # We'll identify these by checking which reports have data that hasn't been copied to iterations
        
        # Get the iterations table
        iterations = db_df("iterations")
        
        # Find reports that need processing by checking a key field that would indicate processing
        to_process = robust_db_operation() do con
            # This query finds reports that haven't been fully processed in iterations
            # It joins reports with iterations and finds where key fields haven't been updated
            DataFrame(DBInterface.execute(con, """
                SELECT r.*
                FROM reports r
                LEFT JOIN iterations i ON r.paper_id = i.paper_id AND r.round = i.round
                WHERE i.date_completed_repl IS NULL 
                   OR i.replicator1 IS NULL
                   OR i.replicator1 <> r.email_of_replicator_1
            """))
        end
        
        if nrow(to_process) > 0
            @info "Found $(nrow(to_process)) reports to process"
            
            # Register the reports dataframe as a temporary table in DuckDB
            robust_db_operation() do con
                # Register the reports to process
                DuckDB.register_data_frame(con, to_process, "temp_reports")
                
                # Use UPDATE with JOIN to update the iterations table
                out = DBInterface.execute(con, """
                    UPDATE iterations
                    SET 
                        replicator1 = tr.email_of_replicator_1,
                        replicator2 = tr.email_of_replicator_2,
                        hours1 = tr.hours_replicator_1,
                        hours2 = tr.hours_replicator_2,
                        is_success = tr.is_success,
                        software = tr.software_used_in_package,
                        is_confidential = tr.is_confidential,
                        is_confidential_shared = tr.shared_confidential,
                        is_remote = tr.is_remote,
                        is_HPC = tr.is_HPC,
                        runtime_code_hours = tr.running_time_of_code,
                        data_statement = tr.data_statement,
                        repl_comments = tr.comments,
                        date_completed_repl = CAST(tr.timestamp AS DATE)
                    FROM temp_reports tr
                    WHERE 
                        iterations.paper_id = tr.paper_id AND
                        iterations.round = tr.round
                    RETURNING iterations.*
                """) |> DataFrame
                rows_updated = nrow(out)

                
                # Update the status in the papers table
                DBInterface.execute(con, """
                    UPDATE papers
                    SET status = 'replicator_back_de'
                    FROM temp_reports tr
                    WHERE papers.paper_id = tr.paper_id
                """)
                
                @info "We had $(nrow(to_process)) reports to process"
                @info "We updated $(rows_updated) rows in iterations"
            end
            
            return to_process
        else
            @info "No reports need processing"
            return nothing
        end
    else
        @info "No reports found in the reports table"
        return nothing
    end
end

function prepare_rnrs()
    # filter papers table for status "replicator_back_de"

    # for each, print summary on screen

    # report needs to be compiled and edited (manually) in github repo

    # pdf with correct name needs to be saved in

    # set in "iterations": date_decision_de = today, file_request_id = fr_id, decision_de = "rnr", file_request_url = fr_url

    # create the next iteration for this paper, i.e. add a row in "iterations" by copying journal,paper_id,firstname_of_author,surname_of_author,round,but modifying round from previous to round + 1

    # call setup_dropbox_structure!(r) on that new row of the "iterations" dataframe

    # prepare email draft of reply to author using
    
    gmail_rnr(r.firstname_of_author,r.paper_id,r.title,r.fr_url,r.email_of_author, email2 = ismissing(r.email_of_second_author) : nothing : r.email_of_second_author)


    # set status of paper_id in papers to "with_author", set date_with_authors to today()
end

function collect_resubmissions()
    # filter papers for status "with_author"

    # get file_requ



end
