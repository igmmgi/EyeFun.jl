const _KNOWN_ET_MASK =
    (UInt64(1) << EVENT_STARTPARSE) |
    (UInt64(1) << EVENT_ENDPARSE) |
    (UInt64(1) << EVENT_BREAKPARSE) |
    (UInt64(1) << EVENT_STARTBLINK) |
    (UInt64(1) << EVENT_ENDBLINK) |
    (UInt64(1) << EVENT_STARTSACC) |
    (UInt64(1) << EVENT_ENDSACC) |
    (UInt64(1) << EVENT_STARTFIX) |
    (UInt64(1) << EVENT_ENDFIX) |
    (UInt64(1) << EVENT_FIXUPDATE) |
    (UInt64(1) << EVENT_STARTSAMPLES) |
    (UInt64(1) << EVENT_ENDSAMPLES) |
    (UInt64(1) << EVENT_STARTEVENTS) |
    (UInt64(1) << EVENT_ENDEVENTS) |
    (UInt64(1) << EVENT_MESSAGEEVENT) |
    (UInt64(1) << EVENT_BUTTONEVENT) |
    (UInt64(1) << EVENT_INPUTEVENT) |
    (UInt64(1) << EVENT_LOST_DATA)

const _RECORDING_ET_MASK =
    (UInt64(1) << EVENT_STARTSAMPLES) |
    (UInt64(1) << EVENT_ENDSAMPLES) |
    (UInt64(1) << EVENT_STARTEVENTS) |
    (UInt64(1) << EVENT_ENDEVENTS)

const _START_ET_MASK =
    (UInt64(1) << EVENT_STARTSACC) |
    (UInt64(1) << EVENT_STARTFIX) |
    (UInt64(1) << EVENT_STARTBLINK) |
    (UInt64(1) << EVENT_STARTPARSE) |
    (UInt64(1) << EVENT_ENDPARSE) |
    (UInt64(1) << EVENT_BREAKPARSE)

const _FEVENT_ET_MASK =
    (UInt64(1) << EVENT_ENDSACC) |
    (UInt64(1) << EVENT_ENDFIX) |
    (UInt64(1) << EVENT_ENDBLINK) |
    (UInt64(1) << EVENT_FIXUPDATE)

function _parse_edf_binary!(
    edf::EDFFile,
    binary_data::Vector{UInt8},
    pos::Int,
    start_marker::String,
    end_marker::String,
    verbose::Bool,
)
    n_data = length(binary_data)
    rem_bytes = max(n_data - pos + 1, 0)

    ev_cols = _EDFEventCols(clamp(div(rem_bytes, 192), 256, 250_000))
    sample_cols = _EDFSampleCols(0)
    recordings_data = EDFRecording[]

    trial = 0
    in_trial = false
    current_sample_ts = UInt32(0)
    current_sflags = UInt16(0)
    sflags_base = UInt16(0)
    current_sample_body_bytes = 0

    while pos + 6 <= n_data
        @inbounds marker_byte = binary_data[pos+2]
        is_header = false
        et = 0
        if marker_byte == HEADER_MARKER
            et = Int(@inbounds(binary_data[pos]) & TYPE_MASK)
            is_header = ((_KNOWN_ET_MASK >> et) & UInt64(1)) != 0
        elseif marker_byte == UInt8(0x41)
            et = Int(@inbounds(binary_data[pos]) & TYPE_MASK)
            is_header = ((_RECORDING_ET_MASK >> et) & UInt64(1)) != 0
        end

        if !is_header
            if current_sflags != 0
                flags_peek = read_be_uint16(binary_data, pos)
                flags_base = flags_peek & ~UInt16(SAMPLE_FULL_TS_FLAG)
                if flags_base == sflags_base || flags_base == (sflags_base | UInt16(1))
                    req =
                        ((flags_peek & SAMPLE_FULL_TS_FLAG) != 0 ? 4 : 1) +
                        current_sample_body_bytes
                    if pos + 1 + req <= n_data
                        pos += 2
                        pos, current_sample_ts = _push_sample_bytes!(
                            binary_data,
                            pos,
                            flags_peek,
                            current_sflags,
                            current_sample_ts,
                            in_trial,
                            trial,
                            sample_cols,
                        )
                        continue
                    end
                end
            end
            pos += 1
            continue
        end

        type_byte = @inbounds binary_data[pos]
        ts = read_be_uint32(binary_data, pos + 3)
        eye_bits = (type_byte >> 6) & 0x03
        eye_val = Int16(
            eye_bits == 0 ? -1 :
            eye_bits == 1 ? EYE_RIGHT : eye_bits == 2 ? EYE_LEFT : EYE_BINOCULAR,
        )

        pos += 7
        et_bit = UInt64(1) << et

        if (et_bit & _FEVENT_ET_MASK) != 0
            pos = _push_fevent_bytes!(ev_cols, binary_data, pos, ts, et, eye_val)

        elseif (et_bit & _START_ET_MASK) != 0
            _push_basic_event!(ev_cols, ts, et, eye_val)

        elseif et == EVENT_MESSAGEEVENT
            t_lo, t_hi, pos = _msg_span_bytes(binary_data, pos)
            if t_lo <= t_hi
                if _matches_marker_bytes(binary_data, t_lo, t_hi, start_marker)
                    trial += 1
                    in_trial = true
                elseif _matches_marker_bytes(binary_data, t_lo, t_hi, end_marker)
                    in_trial = false
                end
            end
            _push_msg_event_bytes!(ev_cols, ts, eye_val, binary_data, t_lo, t_hi)

        elseif (et_bit & _RECORDING_ET_MASK) != 0
            rec, pos = _recording_bytes(binary_data, pos, ts, in_trial ? trial : nothing)
            if !isnothing(rec)
                push!(recordings_data, rec)
                # Only update parsing state from recording blocks with plausible
                # sample rates (100–2000 Hz). Garbage STARTSAMPLES blocks embedded
                # in the binary stream can have rates like 24320 Hz and would
                # corrupt current_sflags mid-recording.
                is_plausible = rec.sample_rate >= 100.0f0 && rec.sample_rate <= 2000.0f0
                if is_plausible &&
                   rec.sflags != 0 &&
                   (et == EVENT_STARTSAMPLES || et == EVENT_ENDSAMPLES)
                    current_sflags = rec.sflags
                    sflags_base = current_sflags & ~UInt16(SAMPLE_FULL_TS_FLAG)
                    current_sample_body_bytes = _edf_sample_body_bytes(current_sflags)
                    if sample_cols.cap == 0
                        est = clamp(
                            div(n_data - pos + 1, max(3 + current_sample_body_bytes, 8)) +
                            512,
                            512,
                            3_000_000,
                        )
                        _grow_sample_cols!(sample_cols, est)
                    end
                end
            end

        elseif et == EVENT_INPUTEVENT
            input_val, pos = _input_bytes(binary_data, pos)
            _push_basic_event!(ev_cols, ts, et, eye_val; input_val = UInt16(input_val))

        elseif et == EVENT_BUTTONEVENT
            btn_val, pos = _input_bytes(binary_data, pos)
            _push_basic_event!(ev_cols, ts, et, eye_val; btn_val = UInt16(btn_val))

        elseif et == EVENT_LOST_DATA
            nothing

        else
            @warn "Unknown event type $et at byte offset $(pos-7)"
            pos -= 6
        end
    end

    verbose &&
        @info "Parsing complete: $(ev_cols.len) events, $(sample_cols.len) samples"

    edf.events = _finalize_events_df!(ev_cols)
    edf.recordings = recordings_to_dataframe(recordings_data)
    edf.samples = _finalize_samples_df!(sample_cols)
    verbose && sample_cols.len > 0 && @info "Loaded $(sample_cols.len) samples into DataFrame"
    return edf
end

"""
    read_eyelink_edf(filename::String;
                    start_marker::String = DEFAULT_START_MARKER,
                    end_marker::String = DEFAULT_END_MARKER,
                    verbose::Bool = false) -> EDFFile

Read a binary EyeLink `.edf` file.

# Arguments
- `filename`: Path to the `.edf` file
- `start_marker`: Message text that marks trial start (default: `"TRIALID"`)
- `end_marker`: Message text that marks trial end (default: `"TRIAL_RESULT"`)
- `verbose`: Emit informational log messages during parsing

# Returns
An `EDFFile` containing:
- `preamble`: The file's text header
- `events`: DataFrame of all events (messages, IO, eye events)
- `recordings`: DataFrame of recording blocks
- `samples`: DataFrame of eye tracking samples
"""
function read_eyelink_edf(
    filename::String;
    start_marker::String = DEFAULT_START_MARKER,
    end_marker::String = DEFAULT_END_MARKER,
    verbose::Bool = false,
)
    isfile(filename) || error("File not found: $filename")

    edf = EDFFile(filename)
    raw_bytes = Base.read(filename)
    preamble_str, bin_start = _extract_edf_preamble(raw_bytes)
    edf.preamble = preamble_str
    verbose && @info "Read preamble ($(ncodeunits(edf.preamble)) bytes)"
    verbose && @info "Loaded $(length(raw_bytes) - bin_start + 1) binary bytes"

    _parse_edf_binary!(edf, raw_bytes, bin_start, start_marker, end_marker, verbose)
    _populate_edf_metadata!(edf)
    return edf
end


function _parse_asc_bytes!(
    edf::EDFFile,
    raw::Vector{UInt8},
    loadsamples::Bool,
    start_marker::String,
    end_marker::String,
    verbose::Bool,
)
    n_bytes = length(raw)
    ev_cols = _EDFEventCols(clamp(div(n_bytes, 256), 256, 250_000))
    sam_cols = _ASCSampleCols(loadsamples ? clamp(div(n_bytes, 24), 1024, 3_000_000) : 0)
    recording_rows = EDFRecording[]
    preamble_buf = IOBuffer()
    has_preamble = false

    trial = 0
    in_trial = false
    asc_eye_mode = 0xff
    in_preamble = true
    n_lines = 0

    pos = 1
    while pos <= n_bytes
        nl = pos
        @inbounds while nl <= n_bytes && raw[nl] != 0x0a
            nl += 1
        end
        ls = pos
        le = nl - 1
        pos = nl + 1
        if le >= ls && @inbounds(raw[le]) == 0x0d
            le -= 1
        end
        n_lines += 1

        le < ls && continue

        b1 = @inbounds raw[ls]
        if b1 == UInt8('*') && le > ls && @inbounds(raw[ls+1]) == UInt8('*')
            if in_preamble
                has_preamble && write(preamble_buf, 0x0a)
                GC.@preserve raw unsafe_write(
                    preamble_buf,
                    pointer(raw, ls),
                    UInt(le - ls + 1),
                )
                has_preamble = true
            end
            continue
        end

        in_preamble = false

        if b1 >= UInt8('0') && b1 <= UInt8('9')
            if loadsamples
                _push_asc_sample_bytes!(
                    sam_cols,
                    raw,
                    ls,
                    le,
                    trial,
                    in_trial,
                    asc_eye_mode,
                )
            end
            continue
        end

        if b1 == UInt8('M') && _line_starts_with_kw(raw, ls, le, "MSG")
            trial, in_trial = _push_asc_msg_bytes!(
                ev_cols,
                raw,
                ls,
                le,
                start_marker,
                end_marker,
                trial,
                in_trial,
            )

        elseif b1 == UInt8('E')
            if _line_starts_with_kw(raw, ls, le, "EFIX")
                _push_asc_efix_bytes!(ev_cols, raw, ls, le)
            elseif _line_starts_with_kw(raw, ls, le, "ESACC")
                _push_asc_esacc_bytes!(ev_cols, raw, ls, le)
            elseif _line_starts_with_kw(raw, ls, le, "EBLINK")
                _push_asc_eblink_bytes!(ev_cols, raw, ls, le)
            elseif _line_starts_with_kw(raw, ls, le, "EVENTS")
                cfg_eye, cfg_sr = _parse_asc_samples_cfg_bytes(raw, ls, le)
                cfg_eye != 0xff && (asc_eye_mode = cfg_eye)
                if cfg_sr > 0.0f0 && !isempty(recording_rows)
                    r_last = recording_rows[end]
                    if r_last.state == RECORDING_START && r_last.sample_rate == 0.0f0
                        recording_rows[end] = EDFRecording(
                            r_last.time,
                            cfg_sr,
                            r_last.eflags,
                            r_last.sflags,
                            r_last.state,
                            r_last.record_type,
                            r_last.pupil_type,
                            r_last.recording_mode,
                            r_last.filter_type,
                            r_last.pos_type,
                            cfg_eye != 0xff ? cfg_eye : r_last.eye,
                            r_last.trial,
                        )
                    end
                end
            elseif _line_starts_with_kw(raw, ls, le, "END")
                row = _parse_asc_end_bytes(raw, ls, le)
                !isnothing(row) && push!(recording_rows, row)
            end

        elseif b1 == UInt8('S')
            if _line_starts_with_kw(raw, ls, le, "START")
                row = _parse_asc_start_bytes(raw, ls, le, in_trial, trial)
                if !isnothing(row)
                    asc_eye_mode = row.eye
                    push!(recording_rows, row)
                end
            elseif _line_starts_with_kw(raw, ls, le, "SAMPLES")
                cfg_eye, cfg_sr = _parse_asc_samples_cfg_bytes(raw, ls, le)
                cfg_eye != 0xff && (asc_eye_mode = cfg_eye)
                if cfg_sr > 0.0f0 && !isempty(recording_rows)
                    r_last = recording_rows[end]
                    if r_last.state == RECORDING_START
                        recording_rows[end] = EDFRecording(
                            r_last.time,
                            cfg_sr,
                            r_last.eflags,
                            r_last.sflags,
                            r_last.state,
                            r_last.record_type,
                            r_last.pupil_type,
                            r_last.recording_mode,
                            r_last.filter_type,
                            r_last.pos_type,
                            cfg_eye != 0xff ? cfg_eye : r_last.eye,
                            r_last.trial,
                        )
                    end
                end
            end

        elseif b1 == UInt8('I') && _line_starts_with_kw(raw, ls, le, "INPUT")
            _push_asc_input_bytes!(ev_cols, raw, ls, le)

        elseif b1 == UInt8('B') && _line_starts_with_kw(raw, ls, le, "BUTTON")
            _push_asc_button_bytes!(ev_cols, raw, ls, le)
        end
    end

    verbose && @info "Parsed $n_lines lines from $(edf.filename)"

    edf.preamble = has_preamble ? String(take!(preamble_buf)) : ""
    if ev_cols.len > 0
        edf.events = _finalize_events_df!(ev_cols)
    end
    if loadsamples && sam_cols.len > 0
        edf.samples = _finalize_asc_samples!(sam_cols)
    end
    if !isempty(recording_rows)
        edf.recordings = recordings_to_dataframe(recording_rows)
    end
    _populate_edf_metadata!(edf)

    verbose &&
        @info "ASC read complete: $(nrow(edf.events)) events, " *
              (loadsamples ? "$(nrow(edf.samples)) samples" : "samples not loaded")

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
    verbose::Bool = false,
)
    isfile(filename) || error("File not found: $filename")
    edf = EDFFile(filename)
    raw = Base.read(filename)
    return _parse_asc_bytes!(edf, raw, loadsamples, start_marker, end_marker, verbose)
end

"""
    read_eyelink(filename::String; kwargs...) -> EDFFile

Read an EyeLink recording file, dispatching on file extension:
- `.edf`: binary reader (`read_eyelink_edf`)
- `.asc`: ASCII text reader (`read_eyelink_asc`)

```julia
et = read_eyelink("recording.edf")
et = read_eyelink("recording.asc")
```
"""
function read_eyelink(filename::String; verbose::Bool = false, kwargs...)
    verbose && @info "Reading $(filename)"
    ext = lowercase(splitext(filename)[2])
    if ext == ".edf"
        return read_eyelink_edf(filename; verbose = verbose, kwargs...)
    elseif ext == ".asc"
        return read_eyelink_asc(filename; verbose = verbose, kwargs...)
    else
        error("Unknown file extension '$ext'. Expected .edf or .asc")
    end
end
