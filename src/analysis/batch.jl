# ── batch_read_eyelink_edf_dataframe ───────────────────────────────────────── #

"""
    batch_read_eyelink_edf_dataframe(files::Vector{String};
        participant_labels=nothing,
        trial_time_zero=nothing,
        verbose=false,
        kwargs...)

Read multiple EDF/ASC files and stack into a single `EyeData` with a
`:participant` column. Each file is processed with `read_eyelink_edf_dataframe`.

# Parameters
- `participant_labels`: a `Vector` of labels (same length as `files`), or
  `nothing` to auto-derive from filenames (without extension)
- `trial_time_zero`: message string to use as t=0 within each trial (passed to reader)
- `verbose`: if `true`, log each file as it is read
- `kwargs...`: additional keyword arguments forwarded to `read_eyelink_edf_dataframe`

Metadata (sample rate, screen resolution, etc.) is taken from the first file.
A warning is emitted if sample rates differ across files.

# Example
```julia
files = ["sub01.edf", "sub02.edf", "sub03.edf"]
df_all = batch_read_eyelink_edf_dataframe(files; trial_time_zero="Stimulus On")
```
"""
function batch_read_eyelink_edf_dataframe(
    files::Vector{String};
    participant_labels = nothing,
    trial_time_zero = nothing,
    verbose::Bool = false,
    kwargs...,
)

    length(files) == 0 && error("No files provided.")

    if participant_labels !== nothing
        length(participant_labels) == length(files) ||
            error("participant_labels must have same length as files.")
        labels = String.(participant_labels)
    else
        labels = [splitext(basename(f))[1] for f in files]
    end

    dfs = DataFrame[]
    eds = EyeData[]

    for (i, file) in enumerate(files)
        verbose && @info "Reading $file ($(labels[i]))"
        ed_i =
            read_eyelink_edf_dataframe(file; trial_time_zero = trial_time_zero, kwargs...)
        df_i = ed_i.df
        insertcols!(df_i, 1, :participant => fill(labels[i], nrow(df_i)))
        push!(dfs, df_i)
        push!(eds, ed_i)
    end

    # Warn if sample rates differ across files
    rates = unique(ed.sample_rate for ed in eds)
    if length(rates) > 1
        @warn "Files have different sample rates: $rates. Using $(eds[1].sample_rate) Hz from first file."
    end

    combined = vcat(dfs...; cols = :union)
    return EyeData(
        combined;
        source = eds[1].source,
        sample_rate = eds[1].sample_rate,
        screen_res = eds[1].screen_res,
        screen_width_cm = eds[1].screen_width_cm,
        viewing_distance_cm = eds[1].viewing_distance_cm,
    )
end

"""
    batch_read_eyelink_edf_dataframe(dir::String; recursive=false, kwargs...)

Read all `.edf` files in `dir` and stack into a single `EyeData`.
Files are sorted alphabetically. Participant labels are derived from filenames.

Set `recursive=true` to search subdirectories as well.

# Example
```julia
df_all = batch_read_eyelink_edf_dataframe("data/raw/")
```
"""
function batch_read_eyelink_edf_dataframe(
    dir::AbstractString;
    recursive::Bool = false,
    kwargs...,
)
    isdir(dir) || error("Not a directory: $dir")
    files = if recursive
        [
            joinpath(root, f) for (root, _, fs) in walkdir(dir) for
            f in fs if endswith(lowercase(f), ".edf")
        ]
    else
        [joinpath(dir, f) for f in readdir(dir) if endswith(lowercase(f), ".edf")]
    end
    sort!(files)
    isempty(files) && error("No .edf files found in $dir")
    return batch_read_eyelink_edf_dataframe(files; kwargs...)
end
