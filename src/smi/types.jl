# ── SMIFile type ───────────────────────────────────────────────────────────── #

"""
    SMIFile

Raw data container returned by `read_smi`. Analogous to `EDFFile` for EyeLink.

Contains the parsed sample data and recording metadata, *before* event detection.
Pass to `create_smi_dataframe` to obtain an analysis-ready `EyeData`.

# Fields
- `filename::String` — path to the source file
- `samples::DataFrame` — raw sample rows (`time`, `trial`, `participant`,
  `gxL`, `gyL`, `paL`, `gxR`, `gyR`, `paR`, `message`)
- `sample_rate::Float64` — recording frequency in Hz
- `screen_res::Tuple{Int,Int}` — screen resolution `(width, height)` in pixels
- `screen_width_cm::Float64` — physical screen width in cm
- `viewing_distance_cm::Float64` — eye-to-screen distance in cm
- `subject::String` — participant ID extracted from the file header

# Example
```julia
raw = read_smi("pp23671_rest1_samples.txt")
raw.subject          # "pp23671"
raw.sample_rate      # 50.0
raw.samples          # DataFrame with raw gaze columns

ed = create_smi_dataframe(raw)
fixations(ed)        # now works
```
"""
mutable struct SMIFile <: EyeFile
    filename::String
    samples::DataFrame
    events::DataFrame
    sample_rate::Float64
    screen_res::Tuple{Int,Int}
    screen_width_cm::Float64
    viewing_distance_cm::Float64
    subject::String

    function SMIFile(filename::String)
        new(filename, DataFrame(), DataFrame(), 0.0, (1280, 1024), 30.0, 50.0, "")
    end
end

# ── Show ───────────────────────────────────────────────────────────────────── #

function Base.show(io::IO, smi::SMIFile)
    print(io, "SMIFile(\"$(basename(smi.filename))\")")
end

function Base.show(io::IO, ::MIME"text/plain", smi::SMIFile)
    println(io, "SMIFile(\"$(basename(smi.filename))\")")

    if nrow(smi.samples) > 0
        ns = nrow(smi.samples)
        sr = smi.sample_rate
        dur_min = ns / sr / 60.0
        sr_str = string(round(sr; digits=2))
        print(io, "  $ns samples")
        sr > 0 && print(io, " ($(sr_str) Hz")

        # Eye presence (limit to first 1000 samples to avoid O(N) scan on missing eyes)
        check_eye(col) = hasproperty(smi.samples, col) && any(!isnan, view(smi.samples[!, col], 1:min(1000, nrow(smi.samples))))
        has_left = check_eye(:gxL)
        has_right = check_eye(:gxR)
        eye_str = has_left && has_right ? "binocular" :
                  has_left ? "left eye" :
                  has_right ? "right eye" : ""
        !isempty(eye_str) && print(io, ", $eye_str")
        sr > 0 && print(io, ")")
        println(io)

        # Duration
        if dur_min >= 1.0
            println(io, "  $(round(dur_min; digits=1)) min")
        else
            println(io, "  $(round(ns / sr; digits=1)) s")
        end

        # Trials
        if hasproperty(smi.samples, :trial)
            nt = length(unique(skipmissing(smi.samples.trial)))
            nt > 0 && println(io, "  $nt trial(s)")
        end

        # Subject
        !isempty(smi.subject) && print(io, "  subject: $(smi.subject)")
    else
        print(io, "  (no samples loaded)")
    end
end

"""
    create_eyefun_data(smi::SMIFile) -> EyeData

Build an analysis-ready `EyeData` from a raw `SMIFile` (returned by `read_smi`).

Performs **format conversion only** — the raw sample columns (`gxL`, `gyL`, `paL`,
etc.) are transferred into the standard `EyeData` schema. Event columns (`in_fix`,
`in_sacc`, `in_blink`) are **not** populated; call `detect_events!(ed)` afterwards
to run I-VT/I-DT fixation/saccade detection and NaN-run blink detection.

# Example
```julia
raw = read_smi("pp23671_rest1_samples.txt")
ed  = EyeData(raw)           # format conversion only
detect_events!(ed)            # adds in_fix, in_sacc, in_blink
fixations(ed)
blinks(ed)
plot_gaze(ed)
```
"""
function create_eyefun_data(smi::SMIFile)
    samples = smi.samples
    nrow(samples) > 0 || error("No sample data in SMIFile.")

    # Work on a copy so the raw SMIFile is left intact
    df = copy(samples)

    # Core standardized analysis framework does not include raw SMI hardware diagnostics (Dia/CR)
    cols_to_drop = intersect(names(df), ["diaxL", "diayL", "diaxR", "diayR", "crxL", "cryL", "crxR", "cryR"])
    if !isempty(cols_to_drop)
        select!(df, Not(cols_to_drop))
    end

    return EyeData(
        df;
        source=:smi,
        sample_rate=smi.sample_rate,
        screen_res=smi.screen_res,
        screen_width_cm=smi.screen_width_cm,
        viewing_distance_cm=smi.viewing_distance_cm,
    )
end


