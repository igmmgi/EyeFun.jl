# ── Batch Reading Utilities ────────────────────────────────────────────────── #

function _batch_read(
    reader_func::Function,
    files::Vector{String},
    participant_labels,
    verbose::Bool,
    post_func::Function;
    kwargs...
)
    length(files) == 0 && error("No files provided.")

    if participant_labels !== nothing
        length(participant_labels) == length(files) ||
            error("participant_labels must have same length as files.")
        labels = String.(participant_labels)
    else
        labels = [splitext(basename(f))[1] for f in files]
    end

    eds = EyeData[]

    for (i, file) in enumerate(files)
        verbose && @info "Reading $file ($(labels[i]))"
        raw_data = reader_func(file; kwargs...)
        ed_i = post_func(raw_data)
        ed_i.df.participant .= labels[i]
        push!(eds, ed_i)
    end

    # Warn if sample rates differ across files
    rates = unique(ed.sample_rate for ed in eds)
    if length(rates) > 1
        @warn "Files have different sample rates: $rates. Using $(eds[1].sample_rate) Hz from first file."
    end

    combined = vcat([ed.df for ed in eds]...; cols = :union)
    return EyeData(
        combined;
        source = eds[1].source,
        sample_rate = eds[1].sample_rate,
        screen_res = eds[1].screen_res,
        screen_width_cm = eds[1].screen_width_cm,
        viewing_distance_cm = eds[1].viewing_distance_cm,
    )
end

function _batch_read_dir(
    reader_func::Function,
    dir::AbstractString,
    ext::String,
    recursive::Bool,
    participant_labels,
    verbose::Bool,
    post_func::Function;
    kwargs...
)
    isdir(dir) || error("Not a directory: $dir")
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
    isempty(files) && error("No $ext_lower files found in $dir")
    return _batch_read(reader_func, files, participant_labels, verbose, post_func; kwargs...)
end


# ── batch_read_eyelink ───────────────────────────────────────── #

"""
    batch_read_eyelink(files::Vector{String};
        participant_labels=nothing,
        trial_time_zero=nothing,
        verbose=false,
        kwargs...)

Read multiple EDF/ASC files and stack into a single `EyeData` with a
`:participant` column.
"""
function batch_read_eyelink(
    files::Vector{String};
    participant_labels = nothing,
    trial_time_zero = nothing,
    verbose::Bool = false,
    kwargs...,
)
    post_func = raw -> EyeData(raw; trial_time_zero = trial_time_zero)
    return _batch_read(read_eyelink, files, participant_labels, verbose, post_func; kwargs...)
end

"""
    batch_read_eyelink(dir::String; ext=".edf", recursive=false, kwargs...)

Read all files with extension `ext` in `dir` and stack into a single `EyeData`.
"""
function batch_read_eyelink(
    dir::AbstractString;
    ext::String = ".edf",
    recursive::Bool = false,
    participant_labels = nothing,
    trial_time_zero = nothing,
    verbose::Bool = false,
    kwargs...,
)
    post_func = raw -> EyeData(raw; trial_time_zero = trial_time_zero)
    return _batch_read_dir(read_eyelink, dir, ext, recursive, participant_labels, verbose, post_func; kwargs...)
end


# ── batch_read_smi ───────────────────────────────────────────── #

"""
    batch_read_smi(files::Vector{String}; participant_labels=nothing, verbose=false, kwargs...)

Read multiple SMI (.idf / .csv) files and stack into a single `EyeData`.
"""
function batch_read_smi(
    files::Vector{String};
    participant_labels = nothing,
    verbose::Bool = false,
    kwargs...,
)
    return _batch_read(read_smi, files, participant_labels, verbose, EyeData; kwargs...)
end

"""
    batch_read_smi(dir::String; ext=".idf", recursive=false, kwargs...)

Read all files with extension `ext` in `dir` and stack into a single `EyeData`.
"""
function batch_read_smi(
    dir::AbstractString;
    ext::String = ".idf",
    recursive::Bool = false,
    participant_labels = nothing,
    verbose::Bool = false,
    kwargs...,
)
    return _batch_read_dir(read_smi, dir, ext, recursive, participant_labels, verbose, EyeData; kwargs...)
end


# ── batch_read_tobii ─────────────────────────────────────────── #

"""
    batch_read_tobii(files::Vector{String}; participant_labels=nothing, verbose=false, kwargs...)

Read multiple Tobii (.tsv) files and stack into a single `EyeData`.
"""
function batch_read_tobii(
    files::Vector{String};
    participant_labels = nothing,
    verbose::Bool = false,
    kwargs...,
)
    return _batch_read(read_tobii, files, participant_labels, verbose, EyeData; kwargs...)
end

"""
    batch_read_tobii(dir::String; ext=".tsv", recursive=false, kwargs...)

Read all files with extension `ext` in `dir` and stack into a single `EyeData`.
"""
function batch_read_tobii(
    dir::AbstractString;
    ext::String = ".tsv",
    recursive::Bool = false,
    participant_labels = nothing,
    verbose::Bool = false,
    kwargs...,
)
    return _batch_read_dir(read_tobii, dir, ext, recursive, participant_labels, verbose, EyeData; kwargs...)
end
