# ── Tobii TSV Reader ───────────────────────────────────────────────────────── #

# Helper: parse a float from a string, returning NaN on empty or unparseable input
_tobii_parse_float(s) = something(tryparse(Float32, s), Float32(NaN))

"""
    read_tobii(path::String; kwargs...) -> TobiiFile

Read a Tobii Pro Lab Data Export TSV file and return a raw `TobiiFile`
container with parsed sample data and recording metadata.

Because Tobii exports do not consistently embed screen geometry, you can
manually supply it via keyword arguments. The sample rate is automatically
estimated by taking the median of consecutive valid time intervals.

# Keyword Arguments
- `screen_res::Tuple{Int,Int}`: screen resolution (default: `(1920, 1080)`)
- `screen_width_cm::Real`: physical screen width in cm (default: `53.0`)
- `viewing_distance_cm::Real`: distance to screen in cm (default: `60.0`)

# Example
```julia
tob = read_tobii("export.tsv", screen_res=(1920,1080))
ed  = EyeData(tob)
detect_events!(ed)
fixations(ed)
```
"""
function read_tobii(
    path::String;
    screen_res::Tuple{Int,Int} = (1920, 1080),
    screen_width_cm::Real = 53.0,
    viewing_distance_cm::Real = 60.0,
)
    isfile(path) || error("File not found: $path")

    # Initialize the container
    tob = TobiiFile(path, screen_res, screen_width_cm, viewing_distance_cm)

    # Pre-allocate arrays for fast parsing
    # We don't know the exact count, but we can guess it's roughly the number of lines
    n_lines = countlines(path)
    estimated_samples = max(0, n_lines - 1)

    times = sizehint!(Float64[], estimated_samples)
    participants = sizehint!(String[], estimated_samples)

    gxLs = sizehint!(Float32[], estimated_samples)
    gyLs = sizehint!(Float32[], estimated_samples)
    gxRs = sizehint!(Float32[], estimated_samples)
    gyRs = sizehint!(Float32[], estimated_samples)
    paLs = sizehint!(Float32[], estimated_samples)
    paRs = sizehint!(Float32[], estimated_samples)
    messages = sizehint!(String[], estimated_samples)

    event_times = sizehint!(Float64[], 100)
    event_types = sizehint!(String[], 100)
    event_msgs = sizehint!(String[], 100)

    _get_val(parts, idx) = idx > 0 && idx <= length(parts) ? strip(parts[idx]) : ""

    open(path, "r") do io
        header_parsed = false
        col_map = Dict{String,Int}()

        # Pre-computed indices for hot path dynamically scoped tightly inside closure
        idx_time = idx_evt = idx_evt_val = idx_stim = idx_valL = idx_valR = 0
        idx_gxL = idx_gyL = idx_paL = idx_gxR = idx_gyR = idx_paR = idx_subj = 0

        last_subj_raw = ""
        last_subj_str = ""

        for line in eachline(io)
            isempty(strip(line)) && continue

            parts = split(line, '\t')

            if !header_parsed
                # Map column indices from header
                for (i, c) in enumerate(parts)
                    col_map[strip(c)] = i
                end
                header_parsed = true

                idx_time = get(col_map, "Recording timestamp [ms]", 0)
                idx_evt = get(col_map, "Event", 0)
                idx_evt_val = get(col_map, "Event value", 0)
                idx_stim = get(col_map, "Presented Stimulus name", 0)
                idx_valL = get(col_map, "Validity left", 0)
                idx_valR = get(col_map, "Validity right", 0)
                idx_gxL = get(col_map, "Gaze point left X [DACS px]", 0)
                idx_gyL = get(col_map, "Gaze point left Y [DACS px]", 0)
                idx_paL = get(col_map, "Pupil diameter left [mm]", 0)
                idx_gxR = get(col_map, "Gaze point right X [DACS px]", 0)
                idx_gyR = get(col_map, "Gaze point right Y [DACS px]", 0)
                idx_paR = get(col_map, "Pupil diameter right [mm]", 0)
                idx_subj = get(col_map, "Participant name", 0)
                continue
            end

            # Time is mandatory for samples
            t_str = _get_val(parts, idx_time)
            isempty(t_str) && continue
            t_ms = parse(Float64, t_str)

            # Events
            evt_type = _get_val(parts, idx_evt)
            evt_val = _get_val(parts, idx_evt_val)
            stim_name = _get_val(parts, idx_stim)

            msg = ""
            if !isempty(evt_type)
                # Found an explicit event
                msg = isempty(evt_val) ? evt_type : "$evt_type: $evt_val"
                push!(event_times, t_ms)
                push!(event_types, "MSG")
                push!(event_msgs, msg)
            elseif !isempty(stim_name)
                # Sometimes a new stimulus begins without a formal event, or alongside it
                msg = "Stimulus: $stim_name"
            end

            # Check if this row represents a gaze sample (has valid left OR right eye validity or pupil data) Let's just blindly push all rows as samples to maintain timeline
            valL = _get_val(parts, idx_valL)
            valR = _get_val(parts, idx_valR)

            # Parse gaze and pupil values
            gxL = _tobii_parse_float(_get_val(parts, idx_gxL))
            gyL = _tobii_parse_float(_get_val(parts, idx_gyL))
            paL = _tobii_parse_float(_get_val(parts, idx_paL))

            gxR = _tobii_parse_float(_get_val(parts, idx_gxR))
            gyR = _tobii_parse_float(_get_val(parts, idx_gyR))
            paR = _tobii_parse_float(_get_val(parts, idx_paR))

            raw_part = _get_val(parts, idx_subj)
            if raw_part != last_subj_raw
                last_subj_raw = raw_part
                last_subj_str = String(raw_part)
            end
            participant = last_subj_str

            if isempty(tob.subject) && !isempty(participant)
                tob.subject = participant
            end

            # Gaze invalidity marking
            if lowercase(valL) == "invalid"
                gxL = gyL = paL = Float32(NaN)
            end
            if lowercase(valR) == "invalid"
                gxR = gyR = paR = Float32(NaN)
            end

            push!(times, t_ms)
            push!(participants, participant)
            push!(gxLs, gxL)
            push!(gyLs, gyL)
            push!(gxRs, gxR)
            push!(gyRs, gyR)
            push!(paLs, paL)
            push!(paRs, paR)
            push!(messages, msg)
        end
    end

    n = length(times)
    df = DataFrame(
        time = times,
        trial = fill(1, n),
        participant = participants,
        gxL = gxLs,
        gyL = gyLs,
        paL = paLs,
        gxR = gxRs,
        gyR = gyRs,
        paR = paRs,
        pupxL = fill(Float32(NaN), n),
        pupyL = fill(Float32(NaN), n),
        pupxR = fill(Float32(NaN), n),
        pupyR = fill(Float32(NaN), n),
        message = messages,
    )

    ev_df = DataFrame(time = event_times, type = event_types, message = event_msgs)

    tob.samples = df
    tob.events = ev_df

    # Estimate sample rate by taking the median of valid consecutive time differences
    if length(times) > 1
        diffs = diff(times)
        valid_diffs = filter(x -> x > 0, diffs)
        if !isempty(valid_diffs)
            med_diff_ms = median(valid_diffs)
            if med_diff_ms > 0
                tob.sample_rate = 1000.0 / med_diff_ms
            end
        end
    end

    return tob
end
