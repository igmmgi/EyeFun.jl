"""
Data parsing and conversion functions.
"""

"""
    _estimate_sample_rate(df::DataFrame) -> Float64

Estimate sample rate from the data by looking at median inter-sample interval.
Used as a fallback when recording metadata does not contain sample rate.
"""
function _estimate_sample_rate(df::DataFrame)
    n = min(nrow(df), 1000)
    times = Float64.(df.time[1:n])
    diffs = diff(times)
    valid_diffs = filter(d -> d > 0, diffs)
    isempty(valid_diffs) && return 1000.0  # fallback
    median_dt_ms = Statistics.median(valid_diffs)
    return round(1000.0 / median_dt_ms)
end

function events_to_dataframe(events::Vector{EDFEvent})
    isempty(events) && return DataFrame()
    return DataFrame(
        # EDFEventBasic fields
        time = UInt32[ev.basic.time for ev in events],
        type = Int16[ev.basic.type for ev in events],
        read = UInt16[ev.basic.read for ev in events],
        sttime = UInt32[ev.basic.sttime for ev in events],
        entime = UInt32[ev.basic.entime for ev in events],
        eye = Int16[ev.basic.eye for ev in events],
        status = UInt16[ev.basic.status for ev in events],
        flags = UInt16[ev.basic.flags for ev in events],
        input = UInt16[ev.basic.input for ev in events],
        buttons = UInt16[ev.basic.buttons for ev in events],
        parsedby = UInt16[ev.basic.parsedby for ev in events],
        message = String[ev.basic.message for ev in events],
        # EDFEventPositions fields
        hstx = Float32[ev.positions.hstx for ev in events],
        hsty = Float32[ev.positions.hsty for ev in events],
        gstx = Float32[ev.positions.gstx for ev in events],
        gsty = Float32[ev.positions.gsty for ev in events],
        sta = Float32[ev.positions.sta for ev in events],
        henx = Float32[ev.positions.henx for ev in events],
        heny = Float32[ev.positions.heny for ev in events],
        genx = Float32[ev.positions.genx for ev in events],
        geny = Float32[ev.positions.geny for ev in events],
        ena = Float32[ev.positions.ena for ev in events],
        havx = Float32[ev.positions.havx for ev in events],
        havy = Float32[ev.positions.havy for ev in events],
        gavx = Float32[ev.positions.gavx for ev in events],
        gavy = Float32[ev.positions.gavy for ev in events],
        ava = Float32[ev.positions.ava for ev in events],
        # EDFEventVelocities fields
        ampl = Float32[ev.velocities.ampl for ev in events],
        pvel = Float32[ev.velocities.pvel for ev in events],
        svel = Float32[ev.velocities.svel for ev in events],
        evel = Float32[ev.velocities.evel for ev in events],
        supd_x = Float32[ev.velocities.supd_x for ev in events],
        eupd_x = Float32[ev.velocities.eupd_x for ev in events],
        supd_y = Float32[ev.velocities.supd_y for ev in events],
        eupd_y = Float32[ev.velocities.eupd_y for ev in events];
        copycols = false,
    )
end

function recordings_to_dataframe(recordings::Vector{EDFRecording})
    isempty(recordings) && return DataFrame()
    fields = fieldnames(EDFRecording)
    data = Dict{Symbol,Vector}()
    for f in fields
        data[f] =
            Vector{Union{fieldtype(EDFRecording, f),Missing}}(undef, length(recordings))
    end
    for (i, r) in enumerate(recordings)
        for f in fields
            data[f][i] = getfield(r, f)
        end
    end
    return DataFrame(data)
end

"""
    parse_saccades(events::DataFrame)

Extract saccade events from the events DataFrame.
"""
function parse_saccades(events::DataFrame)
    if nrow(events) == 0
        return DataFrame()
    end

    saccades = filter(row -> row.type == EVENT_ENDSACC, events)

    if nrow(saccades) == 0
        return DataFrame()
    end

    # Add duration column (entime - sttime inclusive)
    saccades.duration = saccades.entime .- saccades.sttime .+ 1

    # Select whichever of the relevant columns are present
    # (binary reader has href/head velocity fields; ASC reader may not)
    wanted_cols = [
        :sttime,
        :entime,
        :duration,
        :hstx,
        :hsty,
        :gstx,
        :gsty,
        :henx,
        :heny,
        :genx,
        :geny,
        :havx,
        :havy,
        :gavx,
        :gavy,
        :ampl,
        :pvel,
        :svel,
        :evel,
        :eye,
    ]
    present_cols = [c for c in wanted_cols if c in propertynames(saccades)]

    return select(saccades, present_cols)
end

"""
    parse_fixations(events::DataFrame)

Extract fixation events from the events DataFrame.
"""
function parse_fixations(events::DataFrame)
    if nrow(events) == 0
        return DataFrame()
    end

    fixations = filter(row -> row.type == EVENT_ENDFIX, events)

    if nrow(fixations) == 0
        return DataFrame()
    end

    # Add duration column (entime - sttime inclusive)
    fixations.duration = fixations.entime .- fixations.sttime .+ 1

    # Select whichever of the relevant columns are present
    wanted_cols = [
        :sttime,
        :entime,
        :duration,
        :hstx,
        :hsty,
        :gstx,
        :gsty,
        :henx,
        :heny,
        :genx,
        :geny,
        :havx,
        :havy,
        :gavx,
        :gavy,
        :ava,
        :eye,
    ]
    present_cols = [c for c in wanted_cols if c in propertynames(fixations)]

    return select(fixations, present_cols)
end

"""
    parse_blinks(events::DataFrame)

Extract blink events from the events DataFrame.
"""
function parse_blinks(events::DataFrame; samples::Union{DataFrame,Nothing} = nothing)
    if nrow(events) == 0
        return DataFrame()
    end

    end_blinks = filter(r -> r.type == EVENT_ENDBLINK, events)

    if nrow(end_blinks) == 0
        return DataFrame()
    end

    # EDF binary blink recovery:
    # In the EDF binary format, blinks always sit inside a saccade:
    #   SSACC → SBLINK → EBLINK → ESACC
    # ENDBLINK has a 0-byte payload, and its header timestamp equals the
    # STARTBLINK timestamp (i.e. sttime == entime == blink start time).
    # The real blink end time is the last sample with NaN gaze data within
    # the wrapping saccade interval.
    #
    # For ASC files: sttime and entime are already correct from the parsed line.

    result_sttime = Vector{UInt32}(undef, nrow(end_blinks))
    result_entime = Vector{UInt32}(undef, nrow(end_blinks))
    result_eye = end_blinks.eye

    # Detect binary data: in binary EDF, ENDBLINK always has sttime == entime
    is_binary = all(r -> r.sttime == r.entime, eachrow(end_blinks))

    if is_binary
        end_saccs = filter(r -> r.type == EVENT_ENDSACC, events)
        # Build per-eye saccade (sttime, entime) pairs sorted by sttime
        esacc_pairs = if nrow(end_saccs) > 0
            [
                (st = UInt32(r.sttime), en = UInt32(r.entime), eye = Int16(r.eye)) for
                r in eachrow(end_saccs)
            ]
        else
            NamedTuple{(:st, :en, :eye),Tuple{UInt32,UInt32,Int16}}[]
        end
        sort!(esacc_pairs, by = x -> x.st)

        # Prepare sample data for NaN lookup
        has_samples = !isnothing(samples) && nrow(samples) > 0
        sam_times = has_samples ? Vector{UInt32}(samples.time) : UInt32[]
        gaze_col = if has_samples
            if hasproperty(samples, :gxL) && any(!isnan, samples.gxL)
                Vector{Float32}(samples.gxL)
            elseif hasproperty(samples, :gxR) && any(!isnan, samples.gxR)
                Vector{Float32}(samples.gxR)
            else
                Float32[]
            end
        else
            Float32[]
        end

        for (i, row) in enumerate(eachrow(end_blinks))
            blink_start = row.sttime
            result_sttime[i] = blink_start

            # Find the wrapping ESACC: the saccade whose sttime <= blink_start
            # with the latest entime (the outermost saccade enclosing the blink).
            sacc_end = blink_start
            for sp in esacc_pairs
                if sp.st <= blink_start && sp.en > sacc_end
                    sacc_end = sp.en
                end
            end

            if !isempty(gaze_col)
                # Find the last NaN gaze sample between blink_start and sacc_end
                lo = searchsortedfirst(sam_times, blink_start)
                hi = searchsortedlast(sam_times, sacc_end)
                last_nan = blink_start
                for j = lo:hi
                    if isnan(gaze_col[j])
                        last_nan = sam_times[j]
                    end
                end
                result_entime[i] = last_nan
            else
                result_entime[i] = sacc_end
            end
        end
    else
        for (i, row) in enumerate(eachrow(end_blinks))
            result_sttime[i] = row.sttime
            result_entime[i] = row.entime
        end
    end

    duration = result_entime .- result_sttime .+ 1

    blinks = DataFrame(
        sttime = result_sttime,
        entime = result_entime,
        duration = duration,
        eye = result_eye,
    )

    # Deduplicate for binary EDF: multiple STARTBLINK events within the same
    # wrapping saccade produce multiple ENDBLINKs with the same entime.
    # Keep only the earliest sttime per (eye, entime) pair.
    if is_binary && nrow(blinks) > 0
        sort!(blinks, [:eye, :entime, :sttime])
        unique!(blinks, [:eye, :entime])
    end

    # Merge overlapping/adjacent blinks for the same eye.
    # edf2asc treats long NaN stretches (with brief recovery attempts) as one blink.
    if is_binary && nrow(blinks) > 1
        sort!(blinks, [:eye, :sttime])
        merged_st = UInt32[]
        merged_en = UInt32[]
        merged_eye = eltype(blinks.eye)[]
        cur_st = blinks.sttime[1]
        cur_en = blinks.entime[1]
        cur_eye = blinks.eye[1]
        for i = 2:nrow(blinks)
            if blinks.eye[i] == cur_eye && blinks.sttime[i] <= cur_en + UInt32(1)
                # Overlapping or adjacent → extend
                cur_en = max(cur_en, blinks.entime[i])
            else
                push!(merged_st, cur_st)
                push!(merged_en, cur_en)
                push!(merged_eye, cur_eye)
                cur_st = blinks.sttime[i]
                cur_en = blinks.entime[i]
                cur_eye = blinks.eye[i]
            end
        end
        push!(merged_st, cur_st)
        push!(merged_en, cur_en)
        push!(merged_eye, cur_eye)
        blinks = DataFrame(
            sttime = merged_st,
            entime = merged_en,
            duration = merged_en .- merged_st .+ UInt32(1),
            eye = merged_eye,
        )
    end

    return blinks
end

"""
    parse_messages(events::DataFrame)

Extract message events from the events DataFrame.
"""
function parse_messages(events::DataFrame)
    if nrow(events) == 0
        return DataFrame()
    end

    messages = filter(row -> row.type == EVENT_MESSAGEEVENT, events)

    if nrow(messages) == 0
        return DataFrame()
    end

    # Select relevant columns
    relevant_cols = [:sttime, :message, :eye]

    return select(messages, relevant_cols)
end

"""
    parse_variables(events::DataFrame)

Extract trial variables from message events.
"""
function parse_variables(events::DataFrame)
    if nrow(events) == 0
        return DataFrame()
    end

    # Filter for TRIAL_VAR messages
    var_messages = filter(
        row -> row.type == EVENT_MESSAGEEVENT && occursin("TRIAL_VAR", row.message),
        events,
    )

    if nrow(var_messages) == 0
        return DataFrame()
    end

    # Parse variable names and values
    variables = DataFrame()
    variables.sttime = var_messages.sttime

    # Extract variable name and value from message
    var_names = String[]
    var_values = String[]

    for msg in var_messages.message
        # Remove "!V TRIAL_VAR" prefix and split
        clean_msg = replace(msg, r"^\s*!V\s*TRIAL_VAR\s*" => "")
        parts = split(strip(clean_msg), ' ', limit = 2)

        if length(parts) >= 1
            push!(var_names, parts[1])
            push!(var_values, length(parts) >= 2 ? parts[2] : "")
        else
            push!(var_names, "")
            push!(var_values, "")
        end
    end
    variables.variable = var_names
    variables.value = var_values

    # Return long format (wide format not available without trial information)
    return variables
end

"""
    variables(variables::DataFrame; trial_marker::Union{String,Nothing} = nothing) -> DataFrame

Pivot the long-format trial variables table (from `parse_variables`) into a wide
one-row-per-trial DataFrame where each unique variable name becomes a column.

# Trial boundary detection
- **Default** (`trial_marker=nothing`): Auto-detects trial boundaries by finding the
  first repeated variable name. When a variable already seen in the current batch
  appears again, a new trial starts.
- **Explicit** (`trial_marker="trial"`): Uses the specified variable name as the
  trial boundary marker. Each occurrence of that variable starts a new trial, and
  its value is stored in the `trial_label` column.

# Example
```julia
edf = read_eyelink("recording.edf")
conditions = variables(edf.variables)                        # auto-detect
conditions = variables(edf.variables; trial_marker="trial")  # explicit
```
"""
function variables(variables::DataFrame; trial_marker::Union{String,Nothing} = nothing)
    if nrow(variables) == 0
        return DataFrame()
    end

    n = nrow(variables)
    var_names = variables.variable
    var_values = variables.value

    # ── Assign each row to a trial number ────────────────────────────────── #
    trial_of = Vector{Int}(undef, n)

    if isnothing(trial_marker)
        # Auto-detect: a new trial starts when a variable name repeats
        seen = Set{String}()
        current_trial = 1
        for i = 1:n
            if var_names[i] in seen
                current_trial += 1
                empty!(seen)
            end
            push!(seen, var_names[i])
            trial_of[i] = current_trial
        end
    else
        # Explicit: each occurrence of trial_marker starts a new trial
        current_trial = 0
        for i = 1:n
            if var_names[i] == trial_marker
                current_trial += 1
            end
            trial_of[i] = current_trial
        end
        # Rows before the first marker get trial 0 (filtered out below)
    end

    n_trials = maximum(trial_of)
    if n_trials == 0
        return DataFrame()
    end

    # ── Build result DataFrame ───────────────────────────────────────────── #
    result = DataFrame(trial = 1:n_trials)

    # Compute sttime_min / sttime_max per trial
    sttime_min = fill(typemax(UInt32), n_trials)
    sttime_max = fill(typemin(UInt32), n_trials)
    sttimes = variables.sttime
    for i = 1:n
        t = trial_of[i]
        t < 1 && continue
        sttime_min[t] = min(sttime_min[t], sttimes[i])
        sttime_max[t] = max(sttime_max[t], sttimes[i])
    end
    result.sttime_min = sttime_min
    result.sttime_max = sttime_max

    # If using explicit marker, store its value as trial_label and exclude it from columns
    exclude_var = trial_marker
    if !isnothing(trial_marker)
        labels = fill("", n_trials)
        for i = 1:n
            if var_names[i] == trial_marker && trial_of[i] >= 1
                labels[trial_of[i]] = var_values[i]
            end
        end
        result.trial_label = labels
    end

    # Collect column names in order of first appearance (excluding marker if explicit)
    col_order = String[]
    seen_cols = Set{String}()
    for i = 1:n
        vn = var_names[i]
        if vn ∉ seen_cols && (isnothing(exclude_var) || vn != exclude_var)
            push!(col_order, vn)
            push!(seen_cols, vn)
        end
    end

    # Fill columns
    for varname in col_order
        col_vals = fill("", n_trials)
        for i = 1:n
            if var_names[i] == varname && trial_of[i] >= 1
                col_vals[trial_of[i]] = strip(var_values[i])
            end
        end
        result[!, Symbol(varname)] = col_vals
    end

    return result
end

"""
    variables(edf::EDFFile; trial_marker::Union{String,Nothing} = nothing) -> DataFrame

Convenience method: parse trial variables from `edf.events` and pivot to wide format.
"""
function variables(edf::EDFFile; trial_marker::Union{String,Nothing} = nothing)
    vars = parse_variables(edf.events)
    nrow(vars) == 0 && return DataFrame()
    return variables(vars; trial_marker = trial_marker)
end


"""
    parse_aois(events::DataFrame)

Extract Area of Interest (AOI) events from message events.
"""
function parse_aois(events::DataFrame)
    if nrow(events) == 0
        return DataFrame()
    end

    # Filter for IAREA RECTANGLE messages
    aoi_events = filter(
        row ->
            row.type == EVENT_MESSAGEEVENT && startswith(row.message, "!V IAREA RECTANGLE"),
        events,
    )

    if nrow(aoi_events) == 0
        return DataFrame()
    end

    # Parse AOI parameters
    aoi_index = Int[]
    left = Int[]
    top = Int[]
    right = Int[]
    bottom = Int[]
    label = String[]

    for msg in aoi_events.message
        # Remove "!V IAREA RECTANGLE" prefix
        clean_msg = replace(msg, "!V IAREA RECTANGLE" => "") |> strip
        parts = split(clean_msg, ' ')

        idx_v = length(parts) >= 1 ? tryparse(Int, parts[1]) : nothing
        l_v = length(parts) >= 2 ? tryparse(Int, parts[2]) : nothing
        t_v = length(parts) >= 3 ? tryparse(Int, parts[3]) : nothing
        r_v = length(parts) >= 4 ? tryparse(Int, parts[4]) : nothing
        b_v = length(parts) >= 5 ? tryparse(Int, parts[5]) : nothing

        if !isnothing(idx_v) &&
           !isnothing(l_v) &&
           !isnothing(t_v) &&
           !isnothing(r_v) &&
           !isnothing(b_v)
            push!(aoi_index, idx_v)
            push!(left, l_v)
            push!(top, t_v)
            push!(right, r_v)
            push!(bottom, b_v)
            push!(label, length(parts) > 5 ? join(parts[6:end], " ") : "")
        else
            push!(aoi_index, 0)
            push!(left, 0)
            push!(top, 0)
            push!(right, 0)
            push!(bottom, 0)
            push!(label, "")
        end
    end

    result = DataFrame()
    result.sttime = aoi_events.sttime
    result.aoi_index = aoi_index
    result.left = left
    result.top = top
    result.right = right
    result.bottom = bottom
    result.label = label

    return result
end

"""
    create_eyefun_data(edf::EDFFile; include_variables=true, trial_time_zero=nothing, screen_res=nothing) -> EyeData

Build an analysis-ready `EyeData` from an `EDFFile` (returned by `read_eyelink`).

Joins tracker-native fixation, saccade, blink, and message events onto the
sample timeline. Each sample row is annotated with event membership (`in_fix`,
`in_sacc`, `in_blink`) and event attributes (`fix_gavx`, `sacc_gstx`, etc.).

# Keyword arguments
- `include_variables=true` — join `!V TRIAL_VAR` messages as extra columns
- `trial_time_zero=nothing` — message string that marks t=0 within each trial;
  when set, a `time_rel` column (ms relative to that message) is added
- `screen_res=nothing` — override screen resolution; auto-detected from
  `DISPLAY_COORDS` message if `nothing`

# Example
```julia
raw = read_eyelink("session.edf")
ed  = EyeData(raw)          # uses tracker-native events
fixations(ed)
saccades(ed)
blinks(ed)
```
"""
function create_eyefun_data(
    edf::EDFFile;
    include_variables::Bool = true,
    trial_time_zero::Union{String,Nothing} = nothing,
    screen_res::Union{Tuple{Int,Int},Nothing} = nothing,
)
    samples = edf.samples
    if isnothing(samples) || nrow(samples) == 0
        error("No sample data in EDFFile.")
    end

    n = nrow(samples)
    times = samples.time  # sorted UInt32 vector

    # ── helpers ──────────────────────────────────────────────────────────── #
    # Forward the strictly-typed Float32 arrays produced by the Eyelink parsers
    # directly as pointers, bypassing complete array duplication.
    function _f32_col(col)
        T = eltype(col)
        T === Float32 && return col
        out = fill(Float32(NaN), length(col))
        @inbounds for (i, v) in enumerate(col)
            if !ismissing(v) && v isa Number
                out[i] = Float32(v)
            end
        end
        return out
    end

    # ── Base columns ─────────────────────────────────────────────────────── #
    NaN32 = Float32(NaN)
    gxR = hasproperty(samples, :gxR) ? _f32_col(samples.gxR) : fill(NaN32, n)
    gyR = hasproperty(samples, :gyR) ? _f32_col(samples.gyR) : fill(NaN32, n)
    paR = hasproperty(samples, :paR) ? _f32_col(samples.paR) : fill(NaN32, n)
    gxL = hasproperty(samples, :gxL) ? _f32_col(samples.gxL) : fill(NaN32, n)
    gyL = hasproperty(samples, :gyL) ? _f32_col(samples.gyL) : fill(NaN32, n)
    paL = hasproperty(samples, :paL) ? _f32_col(samples.paL) : fill(NaN32, n)

    trial =
        hasproperty(samples, :trial) ? Vector{Union{Int,Missing}}(samples.trial) :
        fill(missing, n)

    # ── Event annotation columns ─────────────────────────────────────────── #
    in_fix = falses(n)
    fix_gavx = fill(NaN32, n)
    fix_gavy = fill(NaN32, n)
    fix_ava = fill(NaN32, n)
    fix_dur = fill(Int32(0), n)

    in_sacc = falses(n)
    sacc_gstx = fill(NaN32, n)
    sacc_gsty = fill(NaN32, n)
    sacc_genx = fill(NaN32, n)
    sacc_geny = fill(NaN32, n)
    sacc_dur = fill(Int32(0), n)
    sacc_ampl = fill(NaN32, n)
    sacc_pvel = fill(NaN32, n)

    in_blink = falses(n)
    blink_dur = fill(Int32(0), n)

    message = fill("", n)

    # ── Interval join: stamp fixation data onto sample rows ──────────────── #
    # For each event [sttime, entime], find sample indices in that range using
    # searchsorted (requires samples to be sorted by time — guaranteed by EDF).
    fix_df = fixations(edf)
    if nrow(fix_df) > 0
        for row in eachrow(fix_df)
            (ismissing(row.sttime) || ismissing(row.entime)) && continue
            dur_ms = Int64(row.entime) - Int64(row.sttime)
            (dur_ms < 0 || dur_ms > 30_000) && continue  # corrupted or >30s: implausible
            lo = searchsortedfirst(times, UInt32(row.sttime))
            hi = searchsortedlast(times, UInt32(row.entime))
            if lo <= hi
                in_fix[lo:hi] .= true
                fix_gavx[lo:hi] .= Float32(row.gavx)
                fix_gavy[lo:hi] .= Float32(row.gavy)
                fix_ava[lo:hi] .= Float32(row.ava)
                fix_dur[lo:hi] .= Int32(row.duration)
            end
        end
    end

    sacc_df = saccades(edf)
    if nrow(sacc_df) > 0
        has_ampl = hasproperty(sacc_df, :ampl)
        has_pvel = hasproperty(sacc_df, :pvel)
        for row in eachrow(sacc_df)
            (ismissing(row.sttime) || ismissing(row.entime)) && continue
            dur_ms = Int64(row.entime) - Int64(row.sttime)
            (dur_ms < 0 || dur_ms > 5_000) && continue  # corrupted or >5s: implausible
            lo = searchsortedfirst(times, UInt32(row.sttime))
            hi = searchsortedlast(times, UInt32(row.entime))
            if lo <= hi
                in_sacc[lo:hi] .= true
                sacc_gstx[lo:hi] .= Float32(row.gstx)
                sacc_gsty[lo:hi] .= Float32(row.gsty)
                sacc_genx[lo:hi] .= Float32(row.genx)
                sacc_geny[lo:hi] .= Float32(row.geny)
                sacc_dur[lo:hi] .= Int32(row.duration)
                has_ampl && (sacc_ampl[lo:hi] .= Float32(row.ampl))
                has_pvel && (sacc_pvel[lo:hi] .= Float32(row.pvel))
            end
        end
    end

    blink_df = blinks(edf)
    if nrow(blink_df) > 0
        for row in eachrow(blink_df)
            lo = searchsortedfirst(times, UInt32(row.sttime))
            hi = searchsortedlast(times, UInt32(row.entime))
            if lo <= hi
                in_blink[lo:hi] .= true
                blink_dur[lo:hi] .= Int32(row.duration)
            end
        end
    end

    # ── Point-join: messages at sample timestamps ────────────────────────── #
    msg_df = messages(edf)
    if nrow(msg_df) > 0
        for row in eachrow(msg_df)
            idx = searchsortedfirst(times, UInt32(row.sttime))
            if idx <= n && times[idx] == UInt32(row.sttime)
                msg_text = strip(replace(row.message, '\0' => ""))
                if message[idx] == ""
                    message[idx] = msg_text
                else
                    message[idx] = message[idx] * "; " * msg_text
                end
            end
        end
    end

    result = DataFrame(
        time = times,
        trial = trial,
        participant = fill("", n),
        gxL = gxL,
        gyL = gyL,
        paL = paL,
        gxR = gxR,
        gyR = gyR,
        paR = paR,
        pupxL = fill(NaN32, n),
        pupyL = fill(NaN32, n),
        pupxR = fill(NaN32, n),
        pupyR = fill(NaN32, n),
        message = message,
        in_fix = in_fix,
        fix_gavx = fix_gavx,
        fix_gavy = fix_gavy,
        fix_ava = fix_ava,
        fix_dur = fix_dur,
        in_sacc = in_sacc,
        sacc_gstx = sacc_gstx,
        sacc_gsty = sacc_gsty,
        sacc_genx = sacc_genx,
        sacc_geny = sacc_geny,
        sacc_dur = sacc_dur,
        sacc_ampl = sacc_ampl,
        sacc_pvel = sacc_pvel,
        in_blink = in_blink,
        blink_dur = blink_dur;
        copycols = false,
    )

    # ── Optionally join trial variables ──────────────────────────────────── #
    if include_variables
        conds = variables(edf)
        if nrow(conds) > 0 && hasproperty(result, :trial)
            # Match on sequential trial number
            conds.trial_seq = 1:nrow(conds)
            select!(conds, Not(:trial))                    # drop original trial label
            rename!(conds, :trial_seq => :trial)
            # Drop timing columns not useful at sample level
            hasproperty(conds, :sttime_min) && select!(conds, Not(:sttime_min))
            hasproperty(conds, :sttime_max) && select!(conds, Not(:sttime_max))

            result = leftjoin(result, conds; on = :trial, makeunique = true)
        end
    end

    # ── Optionally compute trial-relative time ────────────────────────────── #
    if !isnothing(trial_time_zero) && hasproperty(result, :trial)
        time_rel = Vector{Union{Float64,Missing}}(missing, nrow(result))
        for g in groupby(result, :trial; skipmissing = true)
            # Find the first sample in this trial where message matches
            zero_idx = findfirst(r -> !ismissing(r) && r == trial_time_zero, g.message)
            if !isnothing(zero_idx)
                t0 = Float64(g.time[zero_idx])
                g_indices = parentindices(g)[1]
                time_rel[g_indices] .= Float64.(result.time[g_indices]) .- t0
            end
        end
        result.time_rel = time_rel
    end

    # ── Wrap in EyeData with metadata from the EDF recording ──────────── #
    sr = 0.0
    if nrow(edf.recordings) > 0 && hasproperty(edf.recordings, :sample_rate)
        sr = Float64(first(edf.recordings.sample_rate))
    end
    # Fallback: estimate from inter-sample intervals
    if sr <= 0.0
        sr = _estimate_sample_rate(result)
    end

    # Try to extract screen resolution from DISPLAY_COORDS message
    if isnothing(screen_res)
        screen_res = (1920, 1080)  # fallback default
        if nrow(edf.events) > 0 && hasproperty(edf.events, :message)
            for m in edf.events.message
                s = strip(string(m))
                if startswith(s, "DISPLAY_COORDS")
                    parts = split(s)
                    if length(parts) >= 5
                        right = tryparse(Int, parts[4])
                        bottom = tryparse(Int, parts[5])
                        if !isnothing(right) && !isnothing(bottom)
                            screen_res = (right + 1, bottom + 1)
                        end
                    end
                    break
                end
            end
        end
    end
    return EyeData(result; source = :eyelink, sample_rate = sr, screen_res = screen_res)
end

