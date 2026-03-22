# ── EyeData type ───────────────────────────────────────────────────────────── #

"""
    EyeData

Eye-tracking data container that pairs sample-level data in a `DataFrame`
with recording metadata (sample rate, screen geometry, etc.).

# Fields
- `df::DataFrame` — sample-level data (gaze, pupil, events, etc.)
- `source::Symbol` — data source (`:eyelink`, `:tobii`, `:pupil_labs`, `:generic`)
- `sample_rate::Float64` — sampling frequency in Hz
- `screen_res::Tuple{Int,Int}` — screen resolution `(width, height)` in pixels
- `screen_width_cm::Float64` — physical screen width in cm
- `viewing_distance_cm::Float64` — distance from screen to eyes in cm

# Example
```julia
edf = read_eyelink_edf("data.edf")
ed = create_eyelink_edf_dataframe(edf)  # returns EyeData

ed.df.gxR      # access columns via .dataframe
nrow(ed.df)    # DataFrame functions on .df
plot_gaze(ed)  # all plot/analysis functions accept EyeData
ed.screen_res  # metadata fields directly
```
"""
mutable struct EyeData
    df::DataFrame
    source::Symbol
    sample_rate::Float64
    screen_res::Tuple{Int,Int}
    screen_width_cm::Float64
    viewing_distance_cm::Float64
end

"""
    EyeData(df::DataFrame; source=:generic, sample_rate=1000.0,
            screen_res=(1920,1080), screen_width_cm=53.0, viewing_distance_cm=60.0)

Construct an `EyeData` wrapper from a plain DataFrame.
"""
function EyeData(
    df::DataFrame;
    source::Symbol = :generic,
    sample_rate::Real = 1000.0,
    screen_res::Tuple{Int,Int} = (1920, 1080),
    screen_width_cm::Real = 53.0,
    viewing_distance_cm::Real = 60.0,
)
    EyeData(
        df,
        source,
        Float64(sample_rate),
        screen_res,
        Float64(screen_width_cm),
        Float64(viewing_distance_cm),
    )
end

# ── Show ───────────────────────────────────────────────────────────────────── #

function Base.show(io::IO, ed::EyeData)
    sr = Int(ed.sample_rate)
    w, h = ed.screen_res
    print(io, "EyeData($(ed.source), $(sr) Hz, $(w)×$(h))")
end

function Base.show(io::IO, ::MIME"text/plain", ed::EyeData)
    df = ed.df
    sr = Int(ed.sample_rate)
    w, h = ed.screen_res
    println(io, "EyeData ($(ed.source), $(sr) Hz, $(w)×$(h))")

    # Samples
    ns = nrow(df)
    dur_s = ns / ed.sample_rate
    dur_min = dur_s / 60.0
    if dur_min >= 1.0
        println(io, "  $(ns) samples ($(round(dur_min; digits=1)) min)")
    else
        println(io, "  $(ns) samples ($(round(dur_s; digits=1)) s)")
    end

    # Trials
    # TODO: better way of giving user way of defining "trials"
    if hasproperty(df, :trial)
        nt = length(unique(skipmissing(df.trial)))
        nt > 0 && println(io, "  $(nt) trials")
    end

    # Event counts
    _count_onsets(v) = count(i -> v[i] && (i == 1 || !v[i-1]), eachindex(v))
    parts = String[]
    hasproperty(df, :in_fix) && push!(parts, "$(_count_onsets(df.in_fix)) fixations")
    hasproperty(df, :in_sacc) && push!(parts, "$(_count_onsets(df.in_sacc)) saccades")
    hasproperty(df, :in_blink) && push!(parts, "$(_count_onsets(df.in_blink)) blinks")
    !isempty(parts) && println(io, "  ", join(parts, ", "))

    # Columns
    print(io, "  $(ncol(df)) columns: ", join(names(df), ", "))
end
