@testset "quarter_bounds" begin
    @test JPE.quarter_bounds("2026-Q1") == (Date(2026,1,1), Date(2026,3,31))
    @test JPE.quarter_bounds("2026-Q2") == (Date(2026,4,1), Date(2026,6,30))
    @test JPE.quarter_bounds("2026-Q3") == (Date(2026,7,1), Date(2026,9,30))
    @test JPE.quarter_bounds("2026-Q4") == (Date(2026,10,1), Date(2026,12,31))
end

@testset "replicator_hours_worked / billed tracking" begin
    with_jpe_test_db(seed = false) do
        JPE.robust_db_operation() do con
            # single-replicator iteration, completed early in Q3 (before a Sept-20 cutoff)
            DBInterface.execute(con, """
                INSERT INTO iterations (
                    paper_id, journal, paper_slug, round,
                    replicator1, hours1,
                    date_assigned_repl, date_completed_repl, comments
                ) VALUES (
                    '77777701', 'JPE', 'Author-77777701', 1,
                    'rep1@example.com', 3.0,
                    '2026-09-01', '2026-09-15', NULL
                )
            """)
            # single-replicator iteration, completed late in Q3 (after the cutoff)
            DBInterface.execute(con, """
                INSERT INTO iterations (
                    paper_id, journal, paper_slug, round,
                    replicator1, hours1,
                    date_assigned_repl, date_completed_repl, comments
                ) VALUES (
                    '77777702', 'JPE', 'Author-77777702', 1,
                    'rep1@example.com', 2.0,
                    '2026-09-01', '2026-09-25', NULL
                )
            """)
            # two-replicator iteration
            DBInterface.execute(con, """
                INSERT INTO iterations (
                    paper_id, journal, paper_slug, round,
                    replicator1, hours1, replicator2, hours2,
                    date_assigned_repl, date_completed_repl, comments
                ) VALUES (
                    '77777703', 'JPE', 'Author-77777703', 1,
                    'rep1@example.com', 1.5, 'rep2@example.com', 2.5,
                    '2026-09-01', '2026-09-10', NULL
                )
            """)
        end

        h = JPE.replicator_hours_worked()
        @test nrow(h) == 4  # 2 single + 1 two-replicator split into 2 rows
        @test all(hasproperty(h, c) for c in (:paper_id, :round, :billed_at, :billed_period))
        @test all(ismissing, h.billed_at)

        early_start, early_end = Date(2026,7,1), Date(2026,9,20)
        late_start, late_end   = Date(2026,9,21), Date(2026,9,30)

        early = JPE._billable_hours(h, early_start, early_end)
        @test Set(early.paper_id) == Set(["77777701", "77777703"])

        late = JPE._billable_hours(h, late_start, late_end)
        @test Set(late.paper_id) == Set(["77777702"])

        # mark the early batch as billed and confirm it's excluded from a rerun
        for row in eachrow(early)
            JPE.db_mark_billed!(row.paper_id, row.round, "2026-Q3-early")
        end

        h2 = JPE.replicator_hours_worked()
        billed_rows = subset(h2, :paper_id => ByRow(in(["77777701", "77777703"])))
        @test all(!ismissing, billed_rows.billed_at)
        @test all(==("2026-Q3-early"), billed_rows.billed_period)

        unbilled_rows = subset(h2, :paper_id => ByRow(==("77777702")))
        @test all(ismissing, unbilled_rows.billed_at)

        # a full-quarter rerun skips the already-billed rows by default
        full_quarter = JPE._billable_hours(h2, Date(2026,7,1), Date(2026,9,30))
        @test Set(full_quarter.paper_id) == Set(["77777702"])

        # force_rebill=true brings everything back
        forced = JPE._billable_hours(h2, Date(2026,7,1), Date(2026,9,30); force_rebill = true)
        @test Set(forced.paper_id) == Set(["77777701", "77777702", "77777703"])
    end
end
