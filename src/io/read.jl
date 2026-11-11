"""
    detect_format(path::AbstractString)

Detect the correct `EyeFile` type based on file extension.
Returns `EDFFile`, `SMIFile`, or `TobiiFile`.
"""
function detect_format(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    if ext == ".edf" || ext == ".asc"
        return EDFFile
    elseif ext == ".idf" || ext == ".txt"
        return SMIFile
    elseif ext == ".tsv"
        return TobiiFile
    else
        error(
            "Unsupported eye-tracking data format for extension: `$ext`. Please use a supported format (.edf, .asc, .idf, .txt, .tsv)",
        )
    end
end

# Internal format-specific dispatchers returning `EyeData`.
function read_et_data(
    ::Type{EDFFile},
    path::AbstractString;
    include_variables::Bool = true,
    trial_time_zero = nothing,
    screen_res = nothing,
    screen_width_cm = nothing,
    viewing_distance_cm = nothing,
    eye::Symbol = :auto,
    kwargs...,
)
    return create_eyefun_data(
        read_eyelink(String(path); kwargs...);
        include_variables = include_variables,
        trial_time_zero = trial_time_zero,
        screen_res = screen_res,
        screen_width_cm = screen_width_cm,
        viewing_distance_cm = viewing_distance_cm,
        eye = eye,
    )
end

function read_et_data(
    ::Type{SMIFile},
    path::AbstractString;
    trial_time_zero = nothing,
    screen_res = nothing,
    screen_width_cm = nothing,
    viewing_distance_cm = nothing,
    include_events::Bool = false,
    kwargs...,
)
    return create_eyefun_data(
        read_smi(String(path); kwargs...);
        trial_time_zero = trial_time_zero,
        screen_res = screen_res,
        screen_width_cm = screen_width_cm,
        viewing_distance_cm = viewing_distance_cm,
        include_events = include_events,
    )
end

function _is_tobii_tsv_header(path::AbstractString)::Bool
    !isnothing(_find_bids_sidecar(path)) && return false
    open(path, "r") do io
        for line in eachline(io)
            s = strip(line)
            isempty(s) && continue
            return occursin("Recording timestamp", s)
        end
    end
    return false
end

function read_et_data(
    ::Type{TobiiFile},
    path::AbstractString;
    trial_time_zero = nothing,
    screen_res = nothing,
    screen_width_cm = nothing,
    viewing_distance_cm = nothing,
    include_events::Bool = false,
    kwargs...,
)
    if !_is_tobii_tsv_header(path)
        return read_et_delimited(
            path;
            trial_time_zero = trial_time_zero,
            screen_res = screen_res,
            screen_width_cm = screen_width_cm,
            viewing_distance_cm = viewing_distance_cm,
            kwargs...,
        )
    end
    raw = read_tobii(
        String(path);
        screen_res = something(screen_res, (1920, 1080)),
        screen_width_cm = something(screen_width_cm, 53.0),
        viewing_distance_cm = something(viewing_distance_cm, 60.0),
        kwargs...,
    )
    return create_eyefun_data(
        raw;
        trial_time_zero = trial_time_zero,
        screen_res = screen_res,
        screen_width_cm = screen_width_cm,
        viewing_distance_cm = viewing_distance_cm,
        include_events = include_events,
    )
end



"""
    read_et_data(path::String; kwargs...) -> EyeData

Read an eye-tracking file (or directory of files when `ext` is passed) and return an `EyeData`
container. Format is auto-detected from the file extension.
"""
function read_et_data(path::AbstractString; kwargs...)
    isfile(path) || isdir(path) || error("Path not found: $path")

    if isdir(path)
        return _read_et_data_dir(path; kwargs...)
    end

    ext = lowercase(splitext(path)[2])
    if ext == ".csv"
        return read_et_delimited(path; kwargs...)
    end
    fmt = detect_format(path)
    return read_et_data(fmt, path; kwargs...)
end

"""
    read_et_data(files::AbstractVector{<:AbstractString}; participant_labels=nothing, verbose=false, kwargs...) -> EyeData

Read a batch of files and combine them into a single `EyeData` object. 
Format is auto-detected from the first file.
"""
function read_et_data(
    files::AbstractVector{<:AbstractString};
    participant_labels = nothing,
    verbose::Bool = false,
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
    first_ext = lowercase(splitext(files[1])[2])
    is_csv_batch = first_ext == ".csv"
    fmt = is_csv_batch ? nothing : detect_format(files[1]) # Assume homogeneous batch

    for (i, file) in enumerate(files)
        verbose && @info "Reading $(file) ($(labels[i]))"
        ed_i =
            is_csv_batch ? read_et_delimited(file; verbose = verbose, kwargs...) :
            read_et_data(fmt, file; verbose = verbose, kwargs...)
        ed_i.df.participant .= labels[i]
        push!(eds, ed_i)
    end

    rates = unique(ed.sample_rate for ed in eds)
    if length(rates) > 1
        @warn "Files have different sample rates: $(rates). Using $(eds[1].sample_rate) Hz from first file."
    end
    res_set = unique(ed.screen_res for ed in eds)
    if length(res_set) > 1
        @warn "Files have different screen resolutions: $(res_set). Using $(eds[1].screen_res) from first file."
    end
    coords_set = unique(ed.coords for ed in eds)
    if length(coords_set) > 1
        @warn "Files have different coordinate systems: $(coords_set). Using $(eds[1].coords) from first file."
    end

    combined = reduce(vcat, [ed.df for ed in eds]; cols = :union)
    return EyeData(
        combined;
        source = eds[1].source,
        sample_rate = eds[1].sample_rate,
        screen_res = eds[1].screen_res,
        screen_width_cm = eds[1].screen_width_cm,
        viewing_distance_cm = eds[1].viewing_distance_cm,
        coords = eds[1].coords,
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
    isempty(files) && error("No $(ext_lower) files found in $dir")

    return read_et_data(files; kwargs...)
end
