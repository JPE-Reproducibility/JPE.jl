"""
    read_and_unzip_directory(dir_path::String)

Read contents of a directory and unzip any .zip files using system unzip command.
Extracts zip files to the same directory where they reside.

# Arguments
- `dir_path::String`: Path to the directory to read

# Returns
- `Vector{String}`: All file paths in the directory (after unzipping)
"""
function read_and_unzip_directory(dir_path::String)
    # Check if directory exists
    if !isdir(dir_path)
        throw(ArgumentError("Directory does not exist: $dir_path"))
    end
    
    # Get all files in directory
    files = filter(isfile, readdir(dir_path, join=true))
    
    # Find zip files
    zip_files = filter(f -> endswith(lowercase(f), ".zip"), files)
    
    # Unzip each zip file
    for zip_file in zip_files
        println("Unzipping: $(basename(zip_file))")
        
        # Run system unzip command
        # -o: overwrite files without prompting
        # -d: extract to directory (same as zip file location)
        extract_dir = joinpath(dirname(dirname(zip_file)), "replication-package")
        run(pipeline(`unzip -oq $zip_file -d $extract_dir`, devnull))
    end

    rm.(zip_files, force = true)
    
    # Return all files in directory after unzipping
    return filter(isfile, readdir(dir_path, join=true))
end