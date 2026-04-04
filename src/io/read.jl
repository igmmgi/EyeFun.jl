# ── Unified I/O Reading Pattern ──────────────────────────────────────────────── #

"""
    detect_format(path::AbstractString)

Detect the correct `EyeFile` type based on file extension.
Returns `EDFFile`, `SMIFile`, or `TobiiFile`.
"""
function detect_format(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    if ext == ".edf" || ext == ".asc"
        return EDFFile
    elseif ext == ".idf" || ext == ".csv"
        return SMIFile
    elseif ext == ".tsv"
        return TobiiFile
    else
        error(
            "Unsupported eye-tracking data format for extension: `\$ext`. Please use a supported format (.edf, .asc, .idf, .tsv)",
        )
    end
end

"""
    read_et_data(T::Type{<:EyeFile}, path::String; kwargs...)

Internal format-specific dispatchers returning `EyeData`.
"""
function read_et_data(
    ::Type{EDFFile},
    path::AbstractString;
    trial_time_zero = nothing,
    kwargs...,
)
    return create_eyefun_data(
        EyeFun.read_eyelink(path; kwargs...);
        trial_time_zero = trial_time_zero,
    )
end

function read_et_data(::Type{SMIFile}, path::AbstractString; kwargs...)
    return create_eyefun_data(EyeFun.read_smi(path; kwargs...))
end

function read_et_data(::Type{TobiiFile}, path::AbstractString; kwargs...)
    return create_eyefun_data(EyeFun.read_tobii(path; kwargs...))
end



"""
    read_et_data(path::String; kwargs...) -> EyeData

Read a single eye-tracking file. Format is auto-detected from extension. 

By default, this will wrap the raw data in an `EyeData` object 
(which you can then safely filter, manipulate, and plot).
"""
function read_et_data(path::AbstractString; kwargs...)
    isfile(path) || isdir(path) || error("Path not found: \$path")

    # If it's a directory, delegate to the directory dispatcher
    if isdir(path)
        return _read_et_data_dir(path; kwargs...)
    end

    # Otherwise, it's a single file
    fmt = detect_format(path)
    return read_et_data(fmt, path; kwargs...)
end

"""
    read_et_data(files::AbstractVector{<:AbstractString}; participant_labels=nothing, kwargs...) -> EyeData

Read a batch of files and combine them into a single `EyeData` object. 
Format is auto-detected from the first file.
"""
function read_et_data(
    files::AbstractVector{<:AbstractString};
    participant_labels = nothing,
    kwargs...,
)
    length(files) == 0 && error("No files provided.")

    if !isnothing(participant_labels)
        length(participant_labels) == length(files) ||
            error("participant_labels must have same length as files.")
        labels = String.(participant_labels)
    else
        labels = [splitext(basename(f))[1] for f in files]
    end

    eds = EyeData[]
    fmt = detect_format(files[1]) # Assume homogeneous batch

    for (i, file) in enumerate(files)
        @info "Reading $(file) ($(labels[i]))"
        ed_i = read_et_data(fmt, file; kwargs...)
        ed_i.df.participant .= labels[i]
        push!(eds, ed_i)
    end

    # Warn if sample rates differ across files
    rates = unique(ed.sample_rate for ed in eds)
    if length(rates) > 1
        @warn "Files have different sample rates: $(rates). Using $(eds[1].sample_rate) Hz from first file."
    end

    combined = reduce(vcat, [ed.df for ed in eds]; cols = :union)
    return EyeData(
        combined;
        source = eds[1].source,
        sample_rate = eds[1].sample_rate,
        screen_res = eds[1].screen_res,
        screen_width_cm = eds[1].screen_width_cm,
        viewing_distance_cm = eds[1].viewing_distance_cm,
    )
end

function _read_et_data_dir(
    dir::AbstractString;
    ext::Union{String,Nothing} = nothing,
    recursive::Bool = false,
    kwargs...,
)
    isnothing(ext) && error(
        "When providing a directory path to `read_et_data`, you must specify the file extension via the `ext` keyword argument (e.g., ext=\".edf\").",
    )

    ext_lower = lowercase(ext)
    files = if recursive
        [
            joinpath(root, f) for (root, _, fs) in walkdir(dir) for
            f in fs if endswith(lowercase(f), ext_lower)
        ]
    else
        [joinpath(dir, f) for f in readdir(dir) if endswith(lowercase(f), ext_lower)]
    end
    sort!(files)
    isempty(files) && error("No \$(ext_lower) files found in \$dir")

    return read_et_data(files; kwargs...)
end
