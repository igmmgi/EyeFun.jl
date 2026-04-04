"""
    TobiiFile

Raw data container returned by `read_tobii`. Analogous to `EDFFile` and `SMIFile`.

Contains the parsed sample data and recording metadata, *before* event detection.
Pass to `EyeData(raw)` to obtain an analysis-ready `EyeData`.

# Fields
- `filename::String` — path to the source file
- `samples::DataFrame` — raw sample rows (`time`, `participant`,
  `gxL`, `gyL`, `paL`, `gxR`, `gyR`, `paR`, `message`)
- `events::DataFrame` — raw event rows (`time`, `type`, `message`)
- `sample_rate::Float64` — recording frequency in Hz 
- `screen_res::Tuple{Int,Int}` — screen resolution `(width, height)` in pixels
- `screen_width_cm::Float64` — physical screen width in cm
- `viewing_distance_cm::Float64` — eye-to-screen distance in cm
- `subject::String` — participant ID extracted from the file
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
        dur_min = ns / sr / 60.0
        print(io, "  $ns samples")
        sr > 0 && print(io, " ($(round(sr; digits=1)) Hz")

        # Eye presence
        has_left = hasproperty(tob.samples, :gxL) && any(!isnan, tob.samples.gxL)
        has_right = hasproperty(tob.samples, :gxR) && any(!isnan, tob.samples.gxR)
        eye_str =
            has_left && has_right ? "binocular" :
            has_left ? "left eye" : has_right ? "right eye" : ""
        !isempty(eye_str) && print(io, ", $eye_str")
        sr > 0 && print(io, ")")
        println(io)

        # Duration
        if dur_min >= 1.0
            println(io, "  $(round(dur_min; digits=1)) min")
        else
            println(io, "  $(round(ns / sr; digits=1)) s")
        end

        # Events
        ne = nrow(tob.events)
        if ne > 0
            println(io, "  $ne event(s)")
        end

        # Subject
        !isempty(tob.subject) && print(io, "  subject: $(tob.subject)")
    else
        print(io, "  (no samples loaded)")
    end
end


"""
    create_eyefun_data(tob::TobiiFile) -> EyeData

Build an analysis-ready `EyeData` from a raw `TobiiFile`.

Performs format conversion only — the raw sample columns (`gxL`, `gyL`, `paL`,
etc.) are transferred into the standard `EyeData` schema. Event columns (`in_fix`,
`in_sacc`, `in_blink`) are **not** populated; call `detect_events!(ed)` afterwards
to run fixation/saccade/blink detection.
"""
function create_eyefun_data(tob::TobiiFile)
    samples = tob.samples
    nrow(samples) > 0 || error("No sample data in TobiiFile.")

    # Work on a copy so the raw TobiiFile is left intact
    df = copy(samples)

    # We join events into the samples table if possible, or just keep it separate
    # Tobii TSV files often merge messages into the sample rows during export 
    # (or they are intermixed). If we generated `message` column directly, we use it.

    return EyeData(
        df;
        source = :tobii,
        sample_rate = tob.sample_rate,
        screen_res = tob.screen_res,
        screen_width_cm = tob.screen_width_cm,
        viewing_distance_cm = tob.viewing_distance_cm,
    )
end
