"""
    read_stimuli(directory::String; load_extensions=...) -> Dict{String, Any}

Recursively index a directory for multimedia files (ignoring hidden files)
and return a standard Julia `Dict` that maps basenames (e.g. `image.png`) 
to their automatically loaded data using FileIO.

# Keyword Arguments
- `file_extensions`: Extensions to load (e.g. `["png", "jpg", "wav"]`). Images/audio use `FileIO`, text uses raw strings. Non-matching files are skipped.
"""
function read_stimuli(
    directory::String;
    file_extensions::Vector{String} = ["png", "jpg", "jpeg", "bmp", "gif", "wav"],
)

    stimuli = Dict{String,Any}()
    # Normalize extensions so users can pass with or without the leading dot
    file_exts = [lowercase(lstrip(ext, '.')) for ext in file_extensions]

    for (root, dirs, files) in walkdir(directory)
        for file in files
            startswith(file, ".") && continue

            ext = lowercase(lstrip(splitext(file)[2], '.'))

            ext in file_exts || continue

            path = joinpath(root, file)

            if ext in ("txt", "csv")
                # Read sentences as raw strings
                val = read(path, String)
            elseif ext == "wav"
                val = path
            else
                val = try
                    load_image(path)
                catch
                    path # fallback if load fails
                end
            end

            stimuli[file] = val
        end
    end
    return stimuli
end
