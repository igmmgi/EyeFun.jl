"""
Type definitions for EDFReader.jl.
"""

"""
    EDFRecording

Recording block metadata (START / END blocks in the EDF stream).
"""
struct EDFRecording
    time::UInt32
    sample_rate::Float32
    eflags::UInt16
    sflags::UInt16
    state::UInt8           # RECORDING_START or RECORDING_END
    record_type::UInt8     # RECORD_SAMPLES, RECORD_EVENTS, RECORD_BOTH
    pupil_type::UInt8      # PUPIL_AREA or PUPIL_DIAMETER
    recording_mode::UInt8  # MODE_PUPIL or MODE_CR
    filter_type::UInt8
    pos_type::UInt8        # POS_GAZE, POS_HREF, POS_RAW
    eye::UInt8             # EYE_LEFT, EYE_RIGHT, EYE_BINOCULAR
    trial::Union{Int,Nothing}
end

"""
    EDFFile

Main container returned by `read_eyelink_edf` and `read_eyelink_asc`.

Access sub-tables via functions rather than fields:
- `saccades(edf)`, `fixations(edf)`, `blinks(edf)`
- `messages(edf)`, `aois(edf)`
- `variables(edf)`
"""
mutable struct EDFFile <: EyeFile
    filename::String
    preamble::String
    events::DataFrame
    samples::Union{DataFrame,Nothing}
    recordings::DataFrame
    function EDFFile(filename::String)
        new(filename, "", DataFrame(), nothing, DataFrame())
    end
end

function Base.show(io::IO, ::MIME"text/plain", edf::EDFFile)
    println(io, "EDFFile(\"$(basename(edf.filename))\")")

    # Samples info
    if !isnothing(edf.samples) && nrow(edf.samples) > 0
        ns = nrow(edf.samples)
        print(io, "  $(ns) samples")

        # Sample rate from recordings
        if nrow(edf.recordings) > 0 && hasproperty(edf.recordings, :sample_rate)
            sr = first(edf.recordings.sample_rate)
            sr_str = string(round(sr; digits=2))
            sr > 0 && print(io, " ($(sr_str) Hz")
            # Eye mode
            if hasproperty(edf.recordings, :eye)
                eye_code = first(edf.recordings.eye)
                eye_str =
                    eye_code == EYE_BINOCULAR ? "binocular" :
                    eye_code == EYE_LEFT ? "left eye" :
                    eye_code == EYE_RIGHT ? "right eye" : ""
                !isempty(eye_str) && print(io, ", $eye_str")
            end
            sr > 0 && print(io, ")")
        end
        println(io)

        # Trials
        if hasproperty(edf.samples, :trial)
            nt = length(unique(skipmissing(edf.samples.trial)))
            nt > 0 && println(io, "  $nt trials")
        end
    end

    # Event counts
    if nrow(edf.events) > 0 && hasproperty(edf.events, :type)
        nfix = count(==(EVENT_ENDFIX), edf.events.type)
        nsac = count(==(EVENT_ENDSACC), edf.events.type)
        nbl = count(==(EVENT_ENDBLINK), edf.events.type)
        nmsg = count(==(EVENT_MESSAGEEVENT), edf.events.type)
        parts = String[]
        nfix > 0 && push!(parts, "$(nfix) fixations")
        nsac > 0 && push!(parts, "$(nsac) saccades")
        nbl > 0 && push!(parts, "$(nbl) blinks")
        nmsg > 0 && push!(parts, "$(nmsg) messages")
        !isempty(parts) && print(io, "  ", join(parts, ", "))
    end
end

function Base.show(io::IO, edf::EDFFile)
    print(io, "EDFFile(\"$(basename(edf.filename))\")")
end
