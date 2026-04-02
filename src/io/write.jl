"""
    write_et_ascii(path::AbstractString, out_path::Union{String,Nothing}=nothing; kwargs...)

Read a single eye-tracking file (e.g. .edf, .idf) and write it as ASCII text.
If `out_path` is not provided, it saves the file with an `_exported.asc` or `.txt` suffix next to the original.
"""
function write_et_ascii(path::AbstractString, out_path::Union{String,Nothing}=nothing; kwargs...)
    isfile(path) || isdir(path) || error("Path not found: $path")

    # If it's a directory, delegate to the directory dispatcher
    if isdir(path)
        return _write_et_ascii_dir(path; kwargs...)
    end

    # Otherwise, read as raw EyeFile
    fmt = detect_format(path)

    # Read the file to get its internal struct bypassing create_eyefun_data
    raw = if fmt == EDFFile
        EyeFun.read_eyelink(path; kwargs...)
    elseif fmt == SMIFile
        EyeFun.read_smi(path; kwargs...)
    elseif fmt == TobiiFile
        error("Formatting to ASCII for Tobii files (.tsv) is strictly redundant and thus not supported.")
    else
        error("Formatting to ASCII for $fmt is not supported")
    end

    if isnothing(out_path)
        write_et_ascii(raw)
    else
        write_et_ascii(raw, out_path)
    end

    return nothing
end

"""
    write_et_ascii(files::AbstractVector{<:AbstractString}; kwargs...)

Batch write a list of files to ASCII format.
"""
function write_et_ascii(files::AbstractVector{<:AbstractString}; kwargs...)
    for (i, file) in enumerate(files)
        @info "Exporting file $i/$(length(files)): $file"
        write_et_ascii(file; kwargs...)
    end
    return nothing
end

function _write_et_ascii_dir(
    dir::AbstractString;
    ext::Union{String,Nothing}=nothing,
    recursive::Bool=false,
    kwargs...,
)
    isdir(dir) || error("Not a directory: $dir")

    # If no ext specified, default to identifying EDF and IDF binary files
    if isnothing(ext)
        @warn "No extension provided to write_et_ascii directory batch. Detecting .edf and .idf files..."
        files = String[]
        for (root, _, fs) in walkdir(dir)
            for f in fs
                ext_l = lowercase(splitext(f)[2])
                if ext_l == ".edf" || ext_l == ".idf"
                    push!(files, joinpath(root, f))
                end
            end
            !recursive && break
        end
    else
        ext_lower = lowercase(ext)
        files = if recursive
            [
                joinpath(root, f) for (root, _, fs) in walkdir(dir) for
                f in fs if endswith(lowercase(f), ext_lower)
            ]
        else
            [joinpath(dir, f) for f in readdir(dir) if endswith(lowercase(f), ext_lower)]
        end
    end

    sort!(files)
    isempty(files) && @warn "No eye-tracking binary (.edf / .idf) files found in $dir"

    write_et_ascii(files; kwargs...)
    return nothing
end
