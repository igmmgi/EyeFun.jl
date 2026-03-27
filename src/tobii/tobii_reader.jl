# ── Tobii TSV Reader ───────────────────────────────────────────────────────── #

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
    viewing_distance_cm::Real = 60.0
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
    
    gxLs = sizehint!(Float64[], estimated_samples)
    gyLs = sizehint!(Float64[], estimated_samples)
    gxRs = sizehint!(Float64[], estimated_samples)
    gyRs = sizehint!(Float64[], estimated_samples)
    paLs = sizehint!(Float64[], estimated_samples)
    paRs = sizehint!(Float64[], estimated_samples)
    messages = sizehint!(String[], estimated_samples)
    
    event_times = sizehint!(Float64[], 100)
    event_types = sizehint!(String[], 100)
    event_msgs = sizehint!(String[], 100)

    # Column mapping indices
    col_map = Dict{String, Int}()
    
    open(path, "r") do io
        header_parsed = false
        
        for line in eachline(io)
            isempty(strip(line)) && continue
            
            parts = split(line, '\t')
            
            if !header_parsed
                # Map column indices from header
                for (i, c) in enumerate(parts)
                    col_map[strip(c)] = i
                end
                header_parsed = true
                continue
            end
            
            # Helper to get column value or empty string
            get_val(col_name) = haskey(col_map, col_name) && col_map[col_name] <= length(parts) ? strip(parts[col_map[col_name]]) : ""
            
            # Time is mandatory for samples
            t_str = get_val("Recording timestamp [ms]")
            isempty(t_str) && continue
            t_ms = parse(Float64, t_str)
            
            # Events
            evt_type = get_val("Event")
            evt_val = get_val("Event value")
            stim_name = get_val("Presented Stimulus name")
            
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
            valL = get_val("Validity left")
            valR = get_val("Validity right")
            
            # Sometimes parsing fails or is empty, fallback to NaN
            parse_float(s) = isempty(s) ? NaN : (tryparse(Float64, s) === nothing ? NaN : parse(Float64, s))
            
            gxL = parse_float(get_val("Gaze point left X [DACS px]"))
            gyL = parse_float(get_val("Gaze point left Y [DACS px]"))
            paL = parse_float(get_val("Pupil diameter left [mm]"))
            
            gxR = parse_float(get_val("Gaze point right X [DACS px]"))
            gyR = parse_float(get_val("Gaze point right Y [DACS px]"))
            paR = parse_float(get_val("Pupil diameter right [mm]"))
            
            participant = get_val("Participant name")
            if isempty(tob.subject) && !isempty(participant)
                tob.subject = participant
            end
            
            # Gaze invalidity marking
            if lowercase(valL) == "invalid"
                gxL = gyL = paL = NaN
            end
            if lowercase(valR) == "invalid"
                gxR = gyR = paR = NaN
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

    df = DataFrame(
        time = times,
        participant = participants,
        gxL = gxLs,
        gyL = gyLs,
        gxR = gxRs,
        gyR = gyRs,
        paL = paLs,
        paR = paRs,
        message = messages
    )
    
    ev_df = DataFrame(
        time = event_times,
        type = event_types,
        message = event_msgs
    )
    
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
