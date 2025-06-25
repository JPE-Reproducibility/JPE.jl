using Test
using DataFrames
using DuckDB  

const DB_LOCK = ReentrantLock()
const DB_CONNECTION = Ref{Union{Nothing, Any}}(nothing)

const DB_PATH = "testduck.duckdb"

function with_db(f::Function)
    lock(DB_LOCK) do
        if DB_CONNECTION[] === nothing || !isopen(DB_CONNECTION[])
            DB_CONNECTION[] = DBInterface.connect(DuckDB.DB, DB_PATH)
            # DBInterface.execute(DB_CONNECTION[], "PRAGMA journal_mode=WAL")
        end
        f(DB_CONNECTION[])
    end
end


@testset "DuckDB Connection Stress Tests" begin
    
    @testset "Rapid Operations Test" begin
        @test_nowarn begin
            println("Creating base table...")
            with_db() do con
                DBInterface.execute(con, "DROP TABLE IF EXISTS stress_test")
                DBInterface.execute(con, "CREATE TABLE stress_test (id INTEGER, iteration INTEGER, timestamp TIMESTAMP)")
            end
            
            println("Running rapid operations...")
            for i in 1:50
                with_db() do con
                    DBInterface.execute(con, "INSERT INTO stress_test VALUES ($i, $i, NOW())")
                end
                
                with_db() do con
                    result = DBInterface.execute(con, "SELECT COUNT(*) as count FROM stress_test") |> DataFrame
                    @test result.count[1] == i  # Verify count matches iteration
                    println("Iteration $i: $(result.count[1]) rows")
                end
                
                # Simulate some work
                sleep(0.01)
            end
        end
        
        # Final verification
        final_result = with_db() do con
            DBInterface.execute(con, "SELECT COUNT(*) as total, MAX(id) as max_id FROM stress_test") |> DataFrame
        end
        
        @test final_result.total[1] == 50
        @test final_result.max_id[1] == 50
        println("✓ Rapid operations test passed: $(final_result.total[1]) rows inserted")
    end
    
    @testset "Simulated Concurrent Access Test" begin
        @test_nowarn begin
            println("Setting up concurrent access simulation...")
            
            # Create table
            with_db() do con
                DBInterface.execute(con, "DROP TABLE IF EXISTS concurrent_test")
                DBInterface.execute(con, "CREATE TABLE concurrent_test (process_id INTEGER, operation_id INTEGER, data TEXT)")
            end
            
            # Simulate multiple "processes" by rapidly switching between different operations
            tasks = []
            
            for process_id in 1:3
                task = @async begin
                    for op_id in 1:20
                        try
                            with_db() do con
                                DBInterface.execute(con, "INSERT INTO concurrent_test VALUES ($process_id, $op_id, 'data_$(process_id)_$(op_id)')")
                            end
                            
                            # Random small delay
                            sleep(rand() * 0.05)
                            
                            with_db() do con
                                result = DBInterface.execute(con, "SELECT COUNT(*) as count FROM concurrent_test WHERE process_id = $process_id") |> DataFrame
                                println("Process $process_id: $(result.count[1]) rows")
                            end
                        catch e
                            println("Error in process $process_id, operation $op_id: $e")
                            rethrow(e)
                        end
                    end
                end
                push!(tasks, task)
            end
            
            # Wait for all tasks
            for task in tasks
                wait(task)
            end
        end
        
        # Final verification
        result = with_db() do con
            DBInterface.execute(con, "SELECT process_id, COUNT(*) as count FROM concurrent_test GROUP BY process_id ORDER BY process_id") |> DataFrame
        end
        
        println("Final counts by process:")
        println(result)
        
        @test nrow(result) == 3  # Should have 3 processes
        @test all(result.count .== 20)  # Each process should have 20 operations
        @test sum(result.count) == 60  # Total should be 60
        println("✓ Concurrent access test passed: $(sum(result.count)) total operations")
    end
    
    @testset "Large Transaction Test" begin
        @test_nowarn begin
            println("Testing large transaction...")
            
            with_db() do con
                DBInterface.execute(con, "DROP TABLE IF EXISTS large_test")
                DBInterface.execute(con, "CREATE TABLE large_test (id INTEGER, data TEXT, random_num FLOAT)")
            end
            
            # Insert a lot of data in one go
            with_db() do con
                DBInterface.execute(con, "BEGIN TRANSACTION")
                try
                    for i in 1:1000
                        data = "long_string_" * "x"^100 * "_$i"  # Make it somewhat large
                        random_num = rand()
                        DBInterface.execute(con, "INSERT INTO large_test VALUES ($i, '$data', $random_num)")
                        
                        if i % 100 == 0
                            println("Inserted $i rows...")
                        end
                    end
                    DBInterface.execute(con, "COMMIT")
                    println("Transaction committed successfully")
                catch e
                    DBInterface.execute(con, "ROLLBACK")
                    println("Transaction rolled back due to error: $e")
                    rethrow(e)
                end
            end
        end
        
        # Verify the data
        result = with_db() do con
            DBInterface.execute(con, "SELECT COUNT(*) as count, AVG(random_num) as avg_random FROM large_test") |> DataFrame
        end
        
        @test result.count[1] == 1000
        @test 0.0 <= result.avg_random[1] <= 1.0  # Random average should be reasonable
        println("✓ Large transaction test passed: $(result.count[1]) rows, avg random: $(result.avg_random[1])")
    end
    
    @testset "Corruption Scenarios Test" begin
        @test_nowarn begin
            println("Testing scenarios that previously caused corruption...")
            
            # Rapid table creation/dropping
            for i in 1:10
                with_db() do con
                    DBInterface.execute(con, "DROP TABLE IF EXISTS temp_table_$i")
                    DBInterface.execute(con, "CREATE TABLE temp_table_$i (id INTEGER)")
                    DBInterface.execute(con, "INSERT INTO temp_table_$i VALUES ($i)")
                end
                
                with_db() do con
                    result = DBInterface.execute(con, "SELECT * FROM temp_table_$i") |> DataFrame
                    @test result.id[1] == i
                    println("Table $i: $(result.id[1])")
                end
            end
            
            # Clean up
            with_db() do con
                for i in 1:10
                    DBInterface.execute(con, "DROP TABLE IF EXISTS temp_table_$i")
                end
            end
        end
        
        println("✓ Corruption scenarios test passed!")
    end
    
    @testset "Cleanup Test Tables" begin
        @test_nowarn begin
            with_db() do con
                DBInterface.execute(con, "DROP TABLE IF EXISTS stress_test")
                DBInterface.execute(con, "DROP TABLE IF EXISTS concurrent_test") 
                DBInterface.execute(con, "DROP TABLE IF EXISTS large_test")
            end
        end
        println("✓ Test cleanup completed")
    end
end
