

# create an empty database
# this has three tables.

# papers             | iterations           | reports
# ---------          |--------------        |---------
# paperID            | paperID              | case_id
# contact1           | round                | replicator1
# contact2           | case_id              | replicator2
# editor             | replicator1          | time1
# first_arrival_date | replicator2          | time2
# title              | time1                | their_comments
# status             | time2                | data_statement
# round              | their_comments       | software
# date_with_authors  | data_statement       | is_success
# is_remote          | software             | is_remote
# is_HPC             | is_success                | is_HPC
# data_statement     | date_with_authors          | running_time_of_code
# DOI                | date_arrived_from_authors         | 
#  github URL        | date_assigned_repl        | 
#  dataverse URL     | date_completed_repl       | 
#  dataverse label   | date_decision_de           | 
#   is_confidential  | file_request_id            | 
#                    | decision_de                | 
#                    | is_remote                  | 
#                    | is_HPC                     | 
#                    | running_time_of_code       | 




"open DB connection"
# oc() = DBInterface.connect(DuckDB.DB, "$(ENV["JPE_DUCKDB"])")
function oc() 
    con = DBInterface.connect(DuckDB.DB, "/Users/floswald/JPE/jpe.duckdb")
    DBInterface.execute(con, "load gsheets")
    DBInterface.execute(con, """
        CREATE SECRET (
        TYPE gsheet, 
        PROVIDER key_file, 
        FILEPATH '$(ENV["JPE_GOOGLE_KEY"])'
        );
        """)
    return con
end

"close DB connection"
cc(con) = DuckDB.close(con)

function db_df(table::String)
    DataFrame(DBInterface.execute(con,"SELECT * FROM $(table)"))
end

function db_show()
    # con = oc()
    d = DataFrame(DBInterface.execute(con,"SELECT * FROM duckdb_tables()"))
    # cc(con)
    
    select(d, :database_name, :table_name,:temporary, :estimated_size, :column_count)
end

function db_show(table::String)
    
    d = DataFrame(DBInterface.execute(con,"DESCRIBE $table"))
    
    return d
    # select(d, :database_name, :table_name,:temporary, :estimated_size, :column_count)
end

function db_drop_col(table::String,col::String)
    con = oc()
    DBInterface.execute(con,"ALTER TABLE $table DROP COLUMN $col")
    cc(con)
end

function db_drop(table)
    @warn "this will delete table $table. You sure?"
    choice = ask(DefaultPrompt(["y", "no"], 1, "Are you sure?"))
    if choice == "y"
        con = oc()
        DBInterface.execute(con,"DROP TABLE $table")
        cc(con)
        println("Table $table dropped")
    else
        println("Table $table not dropped")
    end
end

function db_types()
    DataFrame(
        string = ["INTEGER","VARCHAR","DATE","BOOLEAN","NUMERIC"],
        dtype = [Int,String,Date,Bool,Float64])
end

function db_empty_df(table::String)
    d = DataFrame(
        DBInterface.execute(con, 
            "PRAGMA table_info($table)"
        )
    )
    d = innerjoin(d,db_types(), on = :type => :string)

    # create an empty dataframe of column types in d.type, with 
    # colnames in d.name
    DataFrame([T[] for T in d.dtype], d.name)
end

function db_create()
    DBInterface.execute(con, """
        CREATE TABLE IF NOT EXISTS papers (
            paper_id INTEGER PRIMARY KEY,
            round INTEGER,
            status VARCHAR,
            journal VARCHAR,
            firstname_of_author VARCHAR,
            surname_of_author VARCHAR,
            email_of_author VARCHAR,
            email_of_second_author VARCHAR,
            handling_editor VARCHAR,
            first_arrival_date DATE,
            title VARCHAR,
            date_with_authors DATE,
            is_remote BOOLEAN,
            is_HPC BOOLEAN,
            data_statement VARCHAR,
            github_url VARCHAR,
            dataverse_doi VARCHAR,
            dataverse_label VARCHAR,
            is_confidential BOOLEAN,
            file_request_id  VARCHAR,
            software VARCHAR,
            comments VARCHAR
        )
        """)
    DBInterface.execute(con, """
        CREATE TABLE IF NOT EXISTS iterations (
            paper_id INTEGER,
            round INTEGER,
            journal VARCHAR,
            replicator1 VARCHAR,
            replicator2 VARCHAR,
            hours1 NUMERIC,
            hours2 NUMERIC,
            is_success BOOLEAN,
            software VARCHAR,
            is_confidential BOOLEAN,
            is_confidential_shared BOOLEAN,
            is_remote  BOOLEAN,
            is_HPC BOOLEAN,
            runtime_code_hours NUMERIC,
            data_statement VARCHAR,
            quality INTEGER,
            complexity INTEGER,
            repl_comments VARCHAR,
            date_with_authors         DATE,
            date_arrived_from_authors DATE,
            date_assigned_repl        DATE,
            date_completed_repl       DATE,
            date_decision_de          DATE,
            file_request_id           VARCHAR,
            decision_de               VARCHAR,
            PRIMARY KEY (paper_id, round)
            );
        """)
    DBInterface.execute(con, """
        CREATE TABLE IF NOT EXISTS reports (
            paper_id INTEGER,
            round INTEGER,
            journal VARCHAR,
            date_completed_repl DATE,
            replicator1 VARCHAR,
            replicator2 VARCHAR,
            hours1 NUMERIC,
            hours2 NUMERIC,
            is_success BOOLEAN,
            software VARCHAR,
            is_confidential BOOLEAN,
            is_confidential_shared BOOLEAN,
            is_remote  BOOLEAN,
            is_HPC BOOLEAN,
            runtime_code_hours NUMERIC,
            data_statement VARCHAR,
            quality INTEGER,
            complexity INTEGER,
            repl_comments VARCHAR,
            PRIMARY KEY (paper_id, round)
        );
        """)
end



"""
get a connection to local db and load the gsheets extension
"""
function getcon()
    con = DBInterface.connect(DuckDB.DB, "$(ENV["JPE_DUCKDB"])")
    DBInterface.execute(con, "load gsheets")
    DBInterface.execute(con, """
        CREATE SECRET (
        TYPE gsheet, 
        PROVIDER key_file, 
        FILEPATH '$(ENV["JPE_GOOGLE_KEY"])'
        );
        """)
    return con
end