"""
    read_stimuli(directory::AbstractString; file_extensions=["png", "jpg", "jpeg", "bmp", "gif", "wav"]) -> Dict{String, Any}

Recursively index a directory for multimedia and text stimulus files (ignoring hidden files)
and return a `Dict{String, Any}` mapping each file's basename (e.g. `"image.png"`) to its path
(or loaded text string for `.txt`/`.csv` files).

# Keyword Arguments
- `file_extensions`: Extensions to index (with or without leading `.`). Text files (`"txt"`, `"csv"`)
  are read as `String`; image and audio files store their full path for lazy loading via [`load_image`](@ref)
  or [`play_wav`](@ref). (`load_extensions` is accepted as a backwards-compatible alias.)
"""
function read_stimuli(
    directory::AbstractString;
    file_extensions::AbstractVector{<:AbstractString} = ["png", "jpg", "jpeg", "bmp", "gif", "wav"],
    load_extensions::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
)
    isdir(directory) || error("Stimulus directory not found: $directory")
    exts_in = isnothing(load_extensions) ? file_extensions : load_extensions

    stimuli = Dict{String,Any}()
    file_exts = [lowercase(lstrip(ext, '.')) for ext in exts_in]

    for (root, _, files) in walkdir(directory)
        for file in files
            startswith(file, ".") && continue

            ext = lowercase(lstrip(splitext(file)[2], '.'))
            ext in file_exts || continue

            path = joinpath(root, file)
            if haskey(stimuli, file)
                @warn "Duplicate stimulus basename '$file' in '$root' overwrites previous entry."
            end

            if ext in ("txt", "csv")
                val = read(path, String)
            else
                val = path
            end

            stimuli[file] = val
        end
    end
    return stimuli
end
