"""
    read_eyelink_edf(filename::String;
                    start_marker::String = DEFAULT_START_MARKER,
                    end_marker::String = DEFAULT_END_MARKER) -> EDFFile

Read an EDF file

# Arguments
- `filename`: Path to the .edf file
- `start_marker`: Message text that marks trial start (default: "TRIALID")
- `end_marker`: Message text that marks trial end (default: "TRIAL_RESULT")

# Returns
An `EDFFile` containing:
- `preamble`: The file's text header
- `events`: DataFrame of all events (messages, IO, eye events)
- `recordings`: DataFrame of recording blocks
- `saccades`, `fixations`, `blinks`, `messages`: Parsed sub-DataFrames
- `samples`: DataFrame of eye tracking samples
"""
function read_eyelink_edf(
    filename::String;
    start_marker::String = DEFAULT_START_MARKER,
    end_marker::String = DEFAULT_END_MARKER,
)

    isfile(filename) || error("File not found: $filename")

    edf = EDFFile(filename)
    open(filename, "r") do io
        # Read preamble ────────────────────────────────────────
        edf.preamble = read_edf_preamble(io)
        @info "Read preamble ($(length(edf.preamble)) bytes)"

        # Load remaining bytes, then walk records in memory ────
        # Reading the whole binary body at once and parsing with integer indices
        # eliminates IO dispatch, eof() syscalls, and seek() calls — the primary
        # source of allocations in the IO-stream approach.
        binary_data = read(io)
        @info "Loaded $(length(binary_data)) binary bytes"

        events_data = EDFEvent[]
        recordings_data = EDFRecording[]

        trial = 0
        in_trial = false
        current_sample_ts = UInt32(0)
        current_eye_code = EYE_RIGHT
        current_sflags = UInt16(0)
        sample_count = 0

        KNOWN_ETS = (
            EVENT_STARTPARSE,
            EVENT_ENDPARSE,
            EVENT_BREAKPARSE,
            EVENT_STARTBLINK,
            EVENT_ENDBLINK,
            EVENT_STARTSACC,
            EVENT_ENDSACC,
            EVENT_STARTFIX,
            EVENT_ENDFIX,
            EVENT_FIXUPDATE,
            EVENT_STARTSAMPLES,
            EVENT_ENDSAMPLES,
            EVENT_STARTEVENTS,
            EVENT_ENDEVENTS,
            EVENT_MESSAGEEVENT,
            EVENT_BUTTONEVENT,
            EVENT_INPUTEVENT,
            EVENT_LOST_DATA,
        )

        # ── Allocate sample columns with concrete types (no Union{T,Nothing}) ──
        col_time = UInt32[]
        col_gxR = Float32[]
        col_gyR = Float32[]
        col_paR = Float32[]
        col_gxL = Float32[]
        col_gyL = Float32[]
        col_paL = Float32[]
        col_hxR = Float32[]
        col_hyR = Float32[]
        col_hxL = Float32[]
        col_hyL = Float32[]
        col_rx = Float32[]
        col_ry = Float32[]
        col_flags = UInt16[]
        col_input = UInt16[]
        col_status = UInt16[]
        col_trial = Int[]
        let HINT = 3_000_000
            foreach(
                v -> sizehint!(v, HINT),
                (
                    col_time,
                    col_gxR,
                    col_gyR,
                    col_paR,
                    col_gxL,
                    col_gyL,
                    col_paL,
                    col_hxR,
                    col_hyR,
                    col_hxL,
                    col_hyL,
                    col_rx,
                    col_ry,
                    col_flags,
                    col_input,
                    col_status,
                    col_trial,
                ),
            )
        end

        n_data = length(binary_data)
        pos = 1

        while pos + 6 <= n_data
            # ── Speculatively read a 7-byte record header ─────────────────
            type_byte = binary_data[pos]
            marker_byte = binary_data[pos+2]
            ts = read_be_uint32(binary_data, pos + 3)

            et = Int(type_byte & TYPE_MASK)
            eye_bits = (type_byte >> 6) & 0x03
            eye_val = Int16(
                eye_bits == 0 ? -1 :
                eye_bits == 1 ? EYE_RIGHT : eye_bits == 2 ? EYE_LEFT : EYE_BINOCULAR,
            )

            # Recording control records (STARTSAMPLES=15,ENDSAMPLES=16,STARTEVENTS=17,ENDEVENTS=18)
            # may use marker byte 0x41 instead of 0x21 near the end of some EDF files.
            is_recording_et = et in
            (EVENT_STARTSAMPLES, EVENT_ENDSAMPLES, EVENT_STARTEVENTS, EVENT_ENDEVENTS)
            valid_marker =
                marker_byte == HEADER_MARKER ||
                (is_recording_et && marker_byte == UInt8(0x41))

            if !valid_marker || !(et in KNOWN_ETS)
                # Not an event header — check for sample data
                if current_sflags != 0
                    flags_peek = read_be_uint16(binary_data, pos)
                    sflags_base = current_sflags & ~UInt16(SAMPLE_FULL_TS_FLAG)
                    flags_base = flags_peek & ~UInt16(SAMPLE_FULL_TS_FLAG)
                    if flags_base == sflags_base || flags_base == (sflags_base | UInt16(1))
                        pos += 2  # consume the flags word
                        pos, current_sample_ts = _push_sample_bytes!(
                            binary_data,
                            pos,
                            flags_peek,
                            current_sflags,
                            current_sample_ts,
                            current_eye_code,
                            in_trial,
                            trial,
                            col_time,
                            col_gxR,
                            col_gyR,
                            col_paR,
                            col_gxL,
                            col_gyL,
                            col_paL,
                            col_hxR,
                            col_hyR,
                            col_hxL,
                            col_hyL,
                            col_rx,
                            col_ry,
                            col_flags,
                            col_input,
                            col_status,
                            col_trial,
                        )
                        sample_count += 1
                        continue
                    end
                end
                pos += 1
                continue
            end

            # ── Valid 7-byte header — advance past it ─────────────────────
            pos += 7

            # ── Dispatch ──────────────────────────────────────────────────
            if et == EVENT_MESSAGEEVENT
                msg_text, pos = _msg_bytes(binary_data, pos)
                if startswith(msg_text, start_marker)
                    trial += 1
                    in_trial = true

                elseif startswith(msg_text, end_marker)
                    in_trial = false
                end
                basic = EDFEventBasic(
                    ts,
                    Int16(et),
                    UInt16(0),
                    ts,
                    ts,
                    eye_val,
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    msg_text,
                )
                push!(events_data, EDFEvent(basic, ZERO_POSITIONS, ZERO_VELOCITIES))

            elseif et == EVENT_INPUTEVENT
                input_val, pos = _input_bytes(binary_data, pos)
                basic = EDFEventBasic(
                    ts,
                    Int16(et),
                    UInt16(0),
                    ts,
                    ts,
                    eye_val,
                    UInt16(0),
                    UInt16(0),
                    UInt16(input_val),
                    UInt16(0),
                    UInt16(0),
                    "",
                )
                push!(events_data, EDFEvent(basic, ZERO_POSITIONS, ZERO_VELOCITIES))

            elseif et == EVENT_BUTTONEVENT
                btn_val, pos = _input_bytes(binary_data, pos)
                basic = EDFEventBasic(
                    ts,
                    Int16(et),
                    UInt16(0),
                    ts,
                    ts,
                    eye_val,
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    UInt16(btn_val),
                    UInt16(0),
                    "",
                )
                push!(events_data, EDFEvent(basic, ZERO_POSITIONS, ZERO_VELOCITIES))

            elseif et in (EVENT_ENDSACC, EVENT_ENDFIX, EVENT_ENDBLINK, EVENT_FIXUPDATE)
                fevent, pos = _fevent_bytes(binary_data, pos, et)
                entime_val = (et == EVENT_ENDBLINK) ? ts : fevent.entime
                basic = EDFEventBasic(
                    ts,
                    Int16(et),
                    UInt16(0),
                    ts,
                    entime_val,
                    eye_val,
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    "",
                )
                positions = EDFEventPositions(
                    fevent.hstx,
                    fevent.hsty,
                    fevent.gstx,
                    fevent.gsty,
                    fevent.sta,
                    fevent.henx,
                    fevent.heny,
                    fevent.genx,
                    fevent.geny,
                    fevent.ena,
                    fevent.havx,
                    fevent.havy,
                    fevent.gavx,
                    fevent.gavy,
                    fevent.ava,
                )
                velocities = EDFEventVelocities(
                    fevent.ampl,
                    fevent.pvel,
                    fevent.svel,
                    fevent.evel,
                    fevent.supd_x,
                    fevent.eupd_x,
                    fevent.supd_y,
                    fevent.eupd_y,
                )
                push!(events_data, EDFEvent(basic, positions, velocities))

            elseif et in (
                EVENT_STARTSACC,
                EVENT_STARTFIX,
                EVENT_STARTBLINK,
                EVENT_STARTPARSE,
                EVENT_ENDPARSE,
                EVENT_BREAKPARSE,
            )
                basic = EDFEventBasic(
                    ts,
                    Int16(et),
                    UInt16(0),
                    ts,
                    ts,
                    eye_val,
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    UInt16(0),
                    "",
                )
                push!(events_data, EDFEvent(basic, ZERO_POSITIONS, ZERO_VELOCITIES))

            elseif et in (
                EVENT_STARTSAMPLES,
                EVENT_ENDSAMPLES,
                EVENT_STARTEVENTS,
                EVENT_ENDEVENTS,
            )
                rec, pos = _recording_bytes(binary_data, pos, ts, in_trial ? trial : nothing)
                if !isnothing(rec)
                    push!(recordings_data, rec)
                    # Only update parsing state from recording blocks with plausible
                    # sample rates (100–2000 Hz). Garbage STARTSAMPLES blocks embedded
                    # in the binary stream can have rates like 24320 Hz and would
                    # corrupt current_sflags mid-recording, causing sample fingerprint
                    # failures and thousands of missed samples.
                    is_plausible = rec.sample_rate >= 100.0f0 && rec.sample_rate <= 2000.0f0
                    if et == EVENT_STARTSAMPLES && is_plausible
                        current_eye_code = Int(rec.eye)
                    end
                    if is_plausible &&
                       rec.sflags != 0 &&
                       et in (EVENT_STARTSAMPLES, EVENT_ENDSAMPLES)
                        current_sflags = rec.sflags
                    end
                end

            elseif et == EVENT_LOST_DATA
                nothing  # no payload

            else
                @warn "Unknown event type $et at byte offset $(pos-7)"
                pos -= 6  # rewind to byte after the type_byte
            end
        end

        @info "Parsing complete: $(length(events_data)) events, $sample_count samples"

        # ── Phase 3: Convert to DataFrames ────────────────────────────────
        edf.events = events_to_dataframe(events_data)
        edf.recordings = recordings_to_dataframe(recordings_data)

        if !isempty(col_time)
            n = length(col_time)
            # trial column: typemin(Int) sentinel → missing
            trial_col =
                Union{Int,Missing}[v == typemin(Int) ? missing : v for v in col_trial]
            edf.samples = DataFrame(
                time = col_time,
                gxR = col_gxR,
                gyR = col_gyR,
                paR = col_paR,
                gxL = col_gxL,
                gyL = col_gyL,
                paL = col_paL,
                hxR = col_hxR,
                hyR = col_hyR,
                hxL = col_hxL,
                hyL = col_hyL,
                rx = col_rx,
                ry = col_ry,
                flags = col_flags,
                input = col_input,
                errors = col_status,
                trial = trial_col;
                copycols = false,
            )
            @info "Loaded $n samples into DataFrame"
        else
            edf.samples = DataFrame()
        end

    end

    return edf
end


"""
    read_eyelink_asc(filename::String;
             loadsamples::Bool = true,
             start_marker::String = "TRIALID",
             end_marker::String = "TRIAL_RESULT") -> EDFFile

Read an EDF ASCII (`.asc`) file produced by SR Research's `edf2asc` tool.

# Arguments
- `filename`: Path to the `.asc` file
- `loadsamples`: Whether to parse raw sample lines (gaze + pupil). Set to `false`
  for faster loading when only events are needed.
- `start_marker`: MSG text that marks trial onset (prefix match)
- `end_marker`: MSG text that marks trial offset (prefix match)

# Returns
An `EDFFile` with `.fixations`, `.saccades`, `.blinks`, `.messages`, `.samples`, and
`.recordings` DataFrames, identical in structure to `read_eyelink_edf`.
"""
function read_eyelink_asc(
    filename::String;
    loadsamples::Bool = true,
    start_marker::String = "TRIALID",
    end_marker::String = "TRIAL_RESULT",
)

    isfile(filename) || error("File not found: $filename")

    edf = EDFFile(filename)

    # ── Event / recording accumulators ────────────────────────────────────────── #
    preamble_lines = String[]
    event_rows = EDFEvent[]
    recording_rows = EDFRecording[]

    # ── Sample accumulators (millions of rows — use typed column vectors) ─────── #
    # Pre-allocate with a generous capacity hint to avoid repeated resizing.
    HINT = 3_000_000
    sam_time = sizehint!(UInt32[], HINT)
    sam_gxR = sizehint!(Float32[], HINT)
    sam_gyR = sizehint!(Float32[], HINT)
    sam_paR = sizehint!(Float32[], HINT)
    sam_gxL = sizehint!(Float32[], HINT)
    sam_gyL = sizehint!(Float32[], HINT)
    sam_paL = sizehint!(Float32[], HINT)
    sam_trial = sizehint!(Int[], HINT)

    trial = 0
    in_trial = false

    in_preamble = true

    n_lines = 0

    open(filename, "r") do io
        for line in eachline(io)
            n_lines += 1

            # ── Preamble (** comment lines) ─────────────────────────────── #
            if startswith(line, "**")
                in_preamble && push!(preamble_lines, line)
                continue
            end

            in_preamble = false
            isempty(line) && continue

            # ── Dispatch on first character / keyword ───────────────────── #
            c = line[1]

            # Fast path: sample lines start with a digit
            if c >= '0' && c <= '9'
                if loadsamples
                    _push_sample!(
                        line,
                        trial,
                        in_trial,
                        sam_time,
                        sam_gxR,
                        sam_gyR,
                        sam_paR,
                        sam_gxL,
                        sam_gyL,
                        sam_paL,
                        sam_trial,
                    )
                end
                continue
            end

            # Keyword dispatch
            if c == 'M' && startswith(line, "MSG")
                parts = split(line; limit = 3)
                row = _parse_msg(parts)
                if !isnothing(row)
                    push!(event_rows, row)
                end
                # Update trial state
                if length(parts) >= 3
                    msg_text = parts[3]
                    if startswith(msg_text, start_marker)
                        trial += 1
                        in_trial = true

                    elseif startswith(msg_text, end_marker)
                        in_trial = false
                    end
                end

            elseif c == 'E'
                if startswith(line, "EFIX")
                    row = _parse_efix(line)
                    !isnothing(row) && push!(event_rows, row)
                elseif startswith(line, "ESACC")
                    row = _parse_esacc(line)
                    !isnothing(row) && push!(event_rows, row)
                elseif startswith(line, "EBLINK")
                    row = _parse_eblink(line)
                    !isnothing(row) && push!(event_rows, row)
                elseif startswith(line, "END")
                    row = _parse_end(line)
                    !isnothing(row) && push!(recording_rows, row)
                end

            elseif c == 'S' && startswith(line, "START")
                row = _parse_start(line, in_trial, trial)
                !isnothing(row) && push!(recording_rows, row)

            elseif c == 'I' && startswith(line, "INPUT")
                row = _parse_input(line)
                !isnothing(row) && push!(event_rows, row)
            end
        end
    end

    @info "Parsed $n_lines lines from $filename"

    edf.preamble = join(preamble_lines, "\n")

    # ── Build events DataFrame ─────────────────────────────────────────────── #
    if !isempty(event_rows)
        edf.events = events_to_dataframe(event_rows)
    end

    # ── Build samples DataFrame (column-major — no per-row schema scan) ──── #
    if loadsamples && !isempty(sam_time)
        MISS = typemin(Int)
        trial_col = Union{Int,Missing}[v == MISS ? missing : v for v in sam_trial]
        edf.samples = DataFrame(
            time = sam_time,
            gxR = sam_gxR,
            gyR = sam_gyR,
            paR = sam_paR,
            gxL = sam_gxL,
            gyL = sam_gyL,
            paL = sam_paL,
            trial = trial_col;
            copycols = false,
        )
    end

    # ── Build recordings DataFrame ─────────────────────────────────────────── #
    if !isempty(recording_rows)
        edf.recordings = recordings_to_dataframe(recording_rows)
    end

    @info "ASC read complete: $(nrow(edf.events)) events, " *
          (loadsamples ? "$(nrow(edf.samples)) samples" : "samples not loaded")

    return edf
end

"""
    read_eyelink(filename::String; kwargs...) -> EDFFile

Unified EyeLink data reader. Dispatches on file extension:
- `.edf` → `read_eyelink_edf` (pure Julia binary reader, no external tools)
- `.asc` → `read_eyelink_asc` (reads `.asc` produced by `edf2asc`)

```julia
et = read_eyelink("recording.edf")
et = read_eyelink("recording.asc")
```
"""
function read_eyelink(filename::String; kwargs...)
    @info "Reading $(filename)"
    ext = lowercase(splitext(filename)[2])
    if ext == ".edf"
        return read_eyelink_edf(filename; kwargs...)
    elseif ext == ".asc"
        return read_eyelink_asc(filename; kwargs...)
    else
        error("Unknown file extension '$ext'. Expected .edf or .asc")
    end
end


