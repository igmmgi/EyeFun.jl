"""
    write_et_ascii(path::AbstractString, out_path::Union{String,Nothing}=nothing; kwargs...)

Read a single eye-tracking file (e.g. .edf, .idf) and write it as ASCII text.
If `out_path` is not provided, it saves the file with an `_exported.asc` or `.txt` suffix next to the original.
"""
function write_et_ascii(
    path::AbstractString,
    out_path::Union{String,Nothing} = nothing;
    include_samples::Bool = true,
    include_events::Bool = true,
    include_messages::Bool = true,
    verbose::Bool = false,
    kwargs...,
)
    isfile(path) || isdir(path) || error("Path not found: $path")

    if isdir(path)
        !isnothing(out_path) &&
            throw(ArgumentError("out_path cannot be specified when path is a directory."))
        return _write_et_ascii_dir(
            path;
            include_samples = include_samples,
            include_events = include_events,
            include_messages = include_messages,
            verbose = verbose,
            kwargs...,
        )
    end

    fmt = detect_format(path)

    raw = if fmt == EDFFile
        read_eyelink(String(path); verbose = verbose, kwargs...)
    elseif fmt == SMIFile
        read_smi(String(path); verbose = verbose, kwargs...)
    else
        error(
            "ASCII export is not supported for Tobii (.tsv) files (already tab-delimited text).",
        )
    end

    if fmt == EDFFile
        if isnothing(out_path)
            write_et_ascii(
                raw;
                include_samples = include_samples,
                include_events = include_events,
                include_messages = include_messages,
                verbose = verbose,
            )
        else
            write_et_ascii(
                raw,
                out_path;
                include_samples = include_samples,
                include_events = include_events,
                include_messages = include_messages,
                verbose = verbose,
            )
        end
    else
        if isnothing(out_path)
            write_et_ascii(raw; verbose = verbose)
        else
            write_et_ascii(raw, out_path; verbose = verbose)
        end
    end

    return nothing
end

"""
    write_et_ascii(files::AbstractVector{<:AbstractString}; verbose=false, kwargs...)

Batch write a list of files to ASCII format.
"""
function write_et_ascii(
    files::AbstractVector{<:AbstractString};
    verbose::Bool = false,
    kwargs...,
)
    for (i, file) in enumerate(files)
        verbose && @info "Exporting file $i/$(length(files)): $file"
        write_et_ascii(file; verbose = verbose, kwargs...)
    end
    return nothing
end

function _write_et_ascii_dir(
    dir::AbstractString;
    ext::Union{String,Nothing} = nothing,
    recursive::Bool = false,
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
    if isempty(files)
        label = isnothing(ext) ? "(.edf / .idf)" : "($ext)"
        @warn "No eye-tracking $label files found in $dir"
        return nothing
    end

    write_et_ascii(files; kwargs...)
    return nothing
end
