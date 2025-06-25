using JPE
using Test
using DataFrames
using DuckDB

# Test database configuration
const TEST_DB_PATH = "/Users/floswald/JPE/jpe_test.duckdb"  # Separate test database

# Test database connection function
function with_test_db(f::Function)
    con = DBInterface.connect(DuckDB.DB, TEST_DB_PATH)
    try
        return f(con)
    finally
        DBInterface.close(con)
    end
end


@testset "JPE.jl" begin
    # Write your tests here.

    include("test_duck.jl")
end
