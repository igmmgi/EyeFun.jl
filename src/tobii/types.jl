"""
    TobiiFile

Raw data container returned by `read_tobii`. Analogous to `EDFFile` and `SMIFile`.

Contains the parsed sample data and recording metadata prior to event detection.
Pass to `EyeData(raw)` to build an `EyeData` container.

# Fields
- `filename::String`: path to the source file
- `samples::DataFrame`: raw sample rows (`time`, `participant`,
  `gxL`, `gyL`, `paL`, `gxR`, `gyR`, `paR`, `message`)
- `events::DataFrame`: raw event rows (`time`, `type`, `message`)
- `sample_rate::Float64`: recording frequency in Hz
- `screen_res::Tuple{Int,Int}`: screen resolution `(width, height)` in pixels
- `screen_width_cm::Float64`: physical screen width in cm
- `viewing_distance_cm::Float64`: eye-to-screen distance in cm
- `subject::String`: participant ID extracted from the file
"""
mutable struct TobiiFile <: EyeFile
    filename::String
    samples::DataFrame
    events::DataFrame
    sample_rate::Float64
    screen_res::Tuple{Int,Int}
    screen_width_cm::Float64
    viewing_distance_cm::Float64
    subject::String
    native_evt::Vector{UInt8}
    native_dur::Vector{Int32}
    native_idx::Vector{Int32}
    native_fix_x::Vector{Float32}
    native_fix_y::Vector{Float32}
    function TobiiFile(
        filename::String,
        screen_res::Tuple{Int,Int} = (1920, 1080),
        screen_width_cm::Real = 53.0,
        viewing_distance_cm::Real = 60.0,
    )
        new(
            filename,
            DataFrame(),
            DataFrame(),
            0.0,
            screen_res,
            Float64(screen_width_cm),
            Float64(viewing_distance_cm),
            "",
            UInt8[],
            Int32[],
            Int32[],
            Float32[],
            Float32[],
        )
    end
end

function Base.show(io::IO, tob::TobiiFile)
    print(io, "TobiiFile(\"$(basename(tob.filename))\")")
end

function Base.show(io::IO, ::MIME"text/plain", tob::TobiiFile)
    println(io, "TobiiFile(\"$(basename(tob.filename))\")")

    if nrow(tob.samples) > 0
        ns = nrow(tob.samples)
        sr = tob.sample_rate
        print(io, "  $ns samples")
        sr > 0 && print(io, " ($(round(sr; digits=1)) Hz")

        has_left = hasproperty(tob.samples, :gxL) && any(!isnan, tob.samples.gxL)
        has_right = hasproperty(tob.samples, :gxR) && any(!isnan, tob.samples.gxR)
        eye_str =
            has_left && has_right ? "binocular" :
            has_left ? "left eye" : has_right ? "right eye" : ""
        if sr > 0
            !isempty(eye_str) && print(io, ", $eye_str")
            print(io, ")")
        elseif !isempty(eye_str)
            print(io, " ($eye_str)")
        end
        println(io)

        if sr > 0
            dur_min = ns / sr / 60.0
            if dur_min >= 1.0
                println(io, "  $(round(dur_min; digits=1)) min")
            else
                println(io, "  $(round(ns / sr; digits=1)) s")
            end
        end

        ne = nrow(tob.events)
        if ne > 0
            println(io, "  $ne event(s)")
        end

        !isempty(tob.subject) && print(io, "  subject: $(tob.subject)")
    else
        print(io, "  (no samples loaded)")
    end
end


"""
    create_eyefun_data(tob::TobiiFile; trial_time_zero=nothing, screen_res=nothing,
                       screen_width_cm=nothing, viewing_distance_cm=nothing,
                       include_events=false) -> EyeData

Build an `EyeData` container from a raw `TobiiFile`.

By default (`include_events=false`), performs format conversion only: raw sample
columns (`gxL`, `gyL`, `paL`, etc.) are transferred into the standard `EyeData` schema
and event columns (`in_fix`, `in_sacc`, `in_blink`) are not populated; call
`detect_events!(ed)` afterwards to run fixation/saccade/blink detection. Set
`include_events=true` to populate event columns from Tobii Pro Lab's native I-VT
classifications (`Eye movement type`).
"""
function create_eyefun_data(
    tob::TobiiFile;
    trial_time_zero::Union{AbstractString,Nothing} = nothing,
    screen_res::Union{Tuple{Int,Int},Nothing} = nothing,
    screen_width_cm::Union{Real,Nothing} = nothing,
    viewing_distance_cm::Union{Real,Nothing} = nothing,
    include_events::Bool = false,
)
    samples = tob.samples
    nrow(samples) > 0 || error("No sample data in TobiiFile.")

    df = copy(samples)

    res = something(screen_res, tob.screen_res)
    sw = Float64(something(screen_width_cm, tob.screen_width_cm))
    vd = Float64(something(viewing_distance_cm, tob.viewing_distance_cm))

    if include_events && length(tob.native_evt) == nrow(df)
        deg_w = 2.0 * rad2deg(atan(sw / 2.0, vd))
        ppd = deg_w > 0.0 ? res[1] / deg_w : 40.0
        _stamp_tobii_events!(df, tob, ppd)
    end

    if !isnothing(trial_time_zero)
        _populate_trial_time_zero!(df, trial_time_zero; allow_substring = true)
    end

    sr = tob.sample_rate > 0.0 ? tob.sample_rate : 1000.0
    return EyeData(
        df;
        source = :tobii,
        sample_rate = sr,
        screen_res = res,
        screen_width_cm = sw,
        viewing_distance_cm = vd,
    )
end
