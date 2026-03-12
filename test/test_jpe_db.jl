
# ---------------------------------------------------------------------------
# with_jpe_test_db — functional test harness for JPE business logic
#
# Creates a fresh, empty DuckDB in a temp directory whose schema exactly
# matches the *live* column set (derived from backup CSVs, not just
# db_get_table_schema() which has drifted).  Swaps JPE.DB_CONNECTION[]
# to point at the test DB so every JPE function (with_db, robust_db_operation,
# update_paper_status, …) operates on the isolated copy.  Restores the
# original connection on exit, even if the test throws.
#
# Usage:
#   with_jpe_test_db() do
#       @test nrow(db_filter_paper("99999999")) == 1
#       # call any JPE workflow function here
#   end
# ---------------------------------------------------------------------------

"""
    with_jpe_test_db(f; seed=true)

Run `f()` against a fresh temporary DuckDB that mirrors the live schema.
JPE.DB_CONNECTION[] is swapped for the duration of the call and restored
(or released) on return.

# Keyword arguments
- `seed::Bool=true`: insert one fixture paper + iteration in `author_back_de`
  status (paper_id `"99999999"`) so workflow functions have something to work on.
"""
function with_jpe_test_db(f::Function; seed::Bool = true)
    tmpdir = mktempdir()
    test_db_path = joinpath(tmpdir, "jpe_test.duckdb")

    test_con = DBInterface.connect(DuckDB.DB, test_db_path)

    # ── 1. Build tables that match the live column set ───────────────────────
    DBInterface.execute(test_con, """
        CREATE TABLE papers (
            paper_id              VARCHAR,
            journal               VARCHAR,
            title                 VARCHAR,
            firstname_of_author   VARCHAR,
            surname_of_author     VARCHAR,
            email_of_author       VARCHAR,
            email_of_second_author VARCHAR,
            handling_editor       VARCHAR,
            comments              VARCHAR,
            paper_slug            VARCHAR,
            status                VARCHAR,
            round                 INTEGER,
            gh_org_repo           VARCHAR,
            github_url            VARCHAR,
            software              VARCHAR,
            data_statement        VARCHAR,
            is_confidential       BOOLEAN,
            share_confidential    BOOLEAN,
            is_remote             BOOLEAN,
            is_HPC                BOOLEAN,
            file_request_id_pkg   VARCHAR,
            file_request_id_paper VARCHAR,
            file_request_url_pkg  VARCHAR,
            file_request_url_paper VARCHAR,
            file_request_path     VARCHAR,
            paper_path            VARCHAR,
            repl_package_path     VARCHAR,
            file_request_path_full VARCHAR,
            doi                   VARCHAR,
            doi_paper             VARCHAR,
            first_arrival_date    DATE,
            date_with_authors     DATE,
            date_published        DATE,
            timestamp             TIMESTAMP
        )
    """)

    DBInterface.execute(test_con, """
        CREATE TABLE iterations (
            paper_id                VARCHAR,
            journal                 VARCHAR,
            title                   VARCHAR,
            firstname_of_author     VARCHAR,
            surname_of_author       VARCHAR,
            email_of_author         VARCHAR,
            email_of_second_author  VARCHAR,
            handling_editor         VARCHAR,
            comments                VARCHAR,
            paper_slug              VARCHAR,
            round                   INTEGER,
            gh_org_repo             VARCHAR,
            github_url              VARCHAR,
            replicator1             VARCHAR,
            replicator2             VARCHAR,
            software                VARCHAR,
            data_statement          VARCHAR,
            decision_de             VARCHAR,
            repl_comments           VARCHAR,
            is_confidential         BOOLEAN,
            share_confidential      BOOLEAN,
            is_remote               BOOLEAN,
            is_HPC                  BOOLEAN,
            is_success              BOOLEAN,
            is_confidential_shared  BOOLEAN,
            hours1                  NUMERIC,
            hours2                  NUMERIC,
            runtime_code_hours      NUMERIC,
            file_request_id_pkg     VARCHAR,
            file_request_id_paper   VARCHAR,
            file_request_url        VARCHAR,
            file_request_url_pkg    VARCHAR,
            file_request_url_paper  VARCHAR,
            file_request_path       VARCHAR,
            paper_path              VARCHAR,
            repl_package_path       VARCHAR,
            file_request_path_full  VARCHAR,
            fr_path_full            VARCHAR,
            fr_path_apps            VARCHAR,
            dropbox_password        VARCHAR,
            first_arrival_date      DATE,
            date_with_authors       DATE,
            date_arrived_from_authors DATE,
            date_assigned_repl      DATE,
            date_completed_repl     DATE,
            date_decision_de        DATE,
            timestamp               TIMESTAMP
        )
    """)

    # Minimal staging tables so functions that reference them don't error.
    DBInterface.execute(test_con, """
        CREATE TABLE form_arrivals (
            paper_id  VARCHAR,
            journal   VARCHAR,
            comments  VARCHAR,
            processed BOOLEAN
        )
    """)
    DBInterface.execute(test_con, """
        CREATE TABLE reports (
            paper_id  VARCHAR,
            round     INTEGER,
            journal   VARCHAR,
            comments  VARCHAR
        )
    """)

    # ── 2. Seed one fixture paper in author_back_de status ───────────────────
    if seed
        today_str = string(Dates.today())
        DBInterface.execute(test_con, """
            INSERT INTO papers (
                paper_id, journal, title,
                firstname_of_author, surname_of_author,
                email_of_author, paper_slug, status, round,
                gh_org_repo, github_url,
                file_request_id_pkg, file_request_id_paper,
                file_request_url_pkg, file_request_url_paper,
                file_request_path, file_request_path_full,
                is_confidential, share_confidential,
                first_arrival_date, date_with_authors,
                comments
            ) VALUES (
                '99999999', 'JPE', 'Test Replication Paper',
                'Testa', 'Author',
                'testa.author@example.com', 'Author-99999999',
                'author_back_de', 1,
                'JPE-Reproducibility/JPE-Author-99999999',
                'https://github.com/JPE-Reproducibility/JPE-Author-99999999',
                'test_fr_pkg_id', 'test_fr_paper_id',
                'https://www.dropbox.com/request/testpkg',
                'https://www.dropbox.com/request/testpaper',
                '/JPE/Author-99999999/1',
                '/Users/floswald/Dropbox/Apps/JPE-packages/JPE/Author-99999999/1',
                false, false,
                '$today_str', '$today_str',
                '[TEST]'
            )
        """)
        DBInterface.execute(test_con, """
            INSERT INTO iterations (
                paper_id, journal, title,
                firstname_of_author, surname_of_author,
                email_of_author, paper_slug, round,
                gh_org_repo, github_url,
                file_request_id_pkg, file_request_id_paper,
                file_request_url_pkg, file_request_url_paper,
                file_request_path, file_request_path_full,
                is_confidential, share_confidential,
                first_arrival_date, date_with_authors,
                comments
            ) VALUES (
                '99999999', 'JPE', 'Test Replication Paper',
                'Testa', 'Author',
                'testa.author@example.com', 'Author-99999999', 1,
                'JPE-Reproducibility/JPE-Author-99999999',
                'https://github.com/JPE-Reproducibility/JPE-Author-99999999',
                'test_fr_pkg_id', 'test_fr_paper_id',
                'https://www.dropbox.com/request/testpkg',
                'https://www.dropbox.com/request/testpaper',
                '/JPE/Author-99999999/1',
                '/Users/floswald/Dropbox/Apps/JPE-packages/JPE/Author-99999999/1',
                false, false,
                '$today_str', '$today_str',
                '[TEST]'
            )
        """)
    end

    # ── 3. Swap JPE's global connection to the test DB ───────────────────────
    # db_release_connection() cleanly closes any open real connection.
    # We then park our test_con in DB_CONNECTION[] so every with_db() call
    # hits the test DB transparently.
    JPE.db_release_connection()
    lock(JPE.DB_LOCK) do
        JPE.DB_CONNECTION[] = test_con
    end

    try
        f()
    finally
        # ── 4. Restore: close test connection, release slot ───────────────────
        # Setting DB_CONNECTION[] = nothing means the next real with_db() call
        # will lazy-reconnect to DB_PATH as normal.
        lock(JPE.DB_LOCK) do
            try
                DBInterface.close(test_con)
            catch
            end
            JPE.DB_CONNECTION[] = nothing
        end
        rm(tmpdir; recursive = true, force = true)
    end
end


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@testset "with_jpe_test_db: schema and fixture" begin

    with_jpe_test_db() do
        # Fixture paper is present
        p = db_filter_paper("99999999")
        @test nrow(p) == 1
        @test p[1, :status] == "author_back_de"
        @test p[1, :round]  == 1
        @test p[1, :paper_slug] == "Author-99999999"

        # Fixture iteration is present
        it = JPE.db_filter_iteration("99999999", 1)
        @test nrow(it) == 1
        @test it[1, :paper_id] == "99999999"

        # dropbox_password column exists and starts as missing
        @test hasproperty(it, :dropbox_password)
        @test ismissing(it[1, :dropbox_password])
    end

end

@testset "with_jpe_test_db: DB_CONNECTION restored after block" begin

    # Run a no-op test block and confirm the real connection is released cleanly.
    with_jpe_test_db() do
        @test nrow(db_filter_paper("99999999")) == 1
    end

    # After the block DB_CONNECTION[] should be nothing (will lazy-reconnect to
    # the real DB on the next with_db() call — we don't trigger that here to
    # avoid touching the real DB in CI).
    @test JPE.DB_CONNECTION[] === nothing

end

@testset "with_jpe_test_db: status transition recorded correctly" begin

    with_jpe_test_db() do
        # update_paper_status is the canonical way to move status.
        # We verify it works on the test DB without touching the real one.
        JPE.update_paper_status("99999999", "author_back_de", "with_replicator") do con
            DBInterface.execute(con, """
                UPDATE iterations
                SET date_assigned_repl = ?, replicator1 = ?
                WHERE paper_id = '99999999' AND round = 1
            """, [Dates.today(), "repl@example.com"])
        end

        p = db_filter_paper("99999999")
        @test p[1, :status] == "with_replicator"

        it = JPE.db_filter_iteration("99999999", 1)
        @test it[1, :replicator1] == "repl@example.com"
        @test !ismissing(it[1, :date_assigned_repl])
    end

end

@testset "with_jpe_test_db: dropbox_password round-trip" begin

    with_jpe_test_db() do
        # Simulate what preprocess2() does: store a password in iterations.
        test_password = "AbCd1234EfGh5678"
        JPE.robust_db_operation() do con
            DBInterface.execute(con, """
                UPDATE iterations
                SET dropbox_password = ?
                WHERE paper_id = '99999999' AND round = 1
            """, [test_password])
        end

        it = JPE.db_filter_iteration("99999999", 1)
        @test it[1, :dropbox_password] == test_password
    end

end

@testset "with_jpe_test_db: display slack message works" begin
    with_jpe_test_db() do
        # Simulate what preprocess2() does: store a password in iterations.
        test_password = "AbCd1234EfGh5678"
        JPE.robust_db_operation() do con
            DBInterface.execute(con, """
                UPDATE iterations
                SET dropbox_password = ?
                WHERE paper_id = '99999999' AND round = 1
            """, [test_password])
        end

        it = JPE.db_filter_iteration("99999999", 1)
        @test it[1, :dropbox_password] == test_password

        JPE._show_dropbox_password_for_assignment("99999999",1,"repl@example.com")
    end
    
end
