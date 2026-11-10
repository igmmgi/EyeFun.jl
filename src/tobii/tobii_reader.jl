@inline function _is_invalid_tobii_bytes(data::Vector{UInt8}, a::Int, b::Int)::Bool
    a, b = _tsv_trim_span(data, a, b)
    (b - a + 1) == 7 || return false
    @inbounds begin
        (data[a] | 0x20) == UInt8('i') &&
            (data[a+1] | 0x20) == UInt8('n') &&
            (data[a+2] | 0x20) == UInt8('v') &&
            (data[a+3] | 0x20) == UInt8('a') &&
            (data[a+4] | 0x20) == UInt8('l') &&
            (data[a+5] | 0x20) == UInt8('i') &&
            (data[a+6] | 0x20) == UInt8('d')
    end
end

@inline function _spans_equal_bytes(
    data::Vector{UInt8},
    a1::Int,
    b1::Int,
    a2::Int,
    b2::Int,
)::Bool
    len = b1 - a1 + 1
    len == (b2 - a2 + 1) || return false
    len <= 0 && return true
    @inbounds for k = 0:(len-1)
        data[a1+k] == data[a2+k] || return false
    end
    return true
end

@inline function _tobii_col_span(
    data::Vector{UInt8},
    col_a::Vector{Int},
    col_b::Vector{Int},
    n_cols::Int,
    idx::Int,
)::Tuple{Int,Int}
    (idx > 0 && idx <= n_cols) || return (1, 0)
    return _tsv_trim_span(data, @inbounds(col_a[idx]), @inbounds(col_b[idx]))
end

@inline function _tobii_parse_f32_col(
    data::Vector{UInt8},
    col_a::Vector{Int},
    col_b::Vector{Int},
    n_cols::Int,
    idx::Int,
)::Float32
    (idx > 0 && idx <= n_cols) || return NaN32
    return Float32(_bytes_parse_f64(data, @inbounds(col_a[idx]), @inbounds(col_b[idx])))
end

function _parse_tobii_header!(
    col_a::Vector{Int},
    col_b::Vector{Int},
    raw::Vector{UInt8},
    ls::Int,
    le::Int,
    path::String,
)
    n_tabs = 0
    @inbounds for k = ls:le
        raw[k] == UInt8('\t') && (n_tabs += 1)
    end
    cap = max(n_tabs + 8, 32)
    resize!(col_a, cap)
    resize!(col_b, cap)
    n_hdr = _tsv_split_spans!(col_a, col_b, raw, ls, le)
    col_map = Dict{String,Int}()
    sizehint!(col_map, n_hdr)
    @inbounds for i = 1:n_hdr
        ha, hb = _tsv_trim_span(raw, col_a[i], col_b[i])
        ha <= hb && (col_map[_span_to_string(raw, ha, hb)] = i)
    end

    if haskey(col_map, "Recording timestamp [ms]")
        idx_time = col_map["Recording timestamp [ms]"]
        time_scale = 1.0
    elseif haskey(col_map, "Recording timestamp [μs]")
        idx_time = col_map["Recording timestamp [μs]"]
        time_scale = 1e-3
    elseif haskey(col_map, "Recording timestamp [µs]")
        idx_time = col_map["Recording timestamp [µs]"]
        time_scale = 1e-3
    elseif haskey(col_map, "Recording timestamp [us]")
        idx_time = col_map["Recording timestamp [us]"]
        time_scale = 1e-3
    elseif haskey(col_map, "Recording timestamp")
        idx_time = col_map["Recording timestamp"]
        time_scale = 1.0
    else
        error(
            "Required timestamp column (e.g. 'Recording timestamp [ms]' or 'Recording timestamp [μs]') not found in Tobii TSV: $path",
        )
    end

    idx_sensor = get(col_map, "Sensor", 0)
    idx_evt = get(col_map, "Event", 0)
    idx_evt_val = get(col_map, "Event value", 0)
    idx_stim = get(col_map, "Presented Stimulus name", 0)
    idx_valL = get(col_map, "Validity left", 0)
    idx_valR = get(col_map, "Validity right", 0)
    idx_pvalL = get(col_map, "Validity pupil left", 0)
    idx_pvalR = get(col_map, "Validity pupil right", 0)

    idx_gxL = get(col_map, "Gaze point left X [DACS px]", 0)
    idx_gyL = get(col_map, "Gaze point left Y [DACS px]", 0)
    idx_gxR = get(col_map, "Gaze point right X [DACS px]", 0)
    idx_gyR = get(col_map, "Gaze point right Y [DACS px]", 0)

    idx_gxL_norm = get(
        col_map,
        "Gaze point left X [ADCS norm]",
        get(col_map, "Gaze point left X [MCS norm]", 0),
    )
    idx_gyL_norm = get(
        col_map,
        "Gaze point left Y [ADCS norm]",
        get(col_map, "Gaze point left Y [MCS norm]", 0),
    )
    idx_gxR_norm = get(
        col_map,
        "Gaze point right X [ADCS norm]",
        get(col_map, "Gaze point right X [MCS norm]", 0),
    )
    idx_gyR_norm = get(
        col_map,
        "Gaze point right Y [ADCS norm]",
        get(col_map, "Gaze point right Y [MCS norm]", 0),
    )

    idx_gx_fused = get(col_map, "Gaze point X [DACS px]", 0)
    idx_gy_fused = get(col_map, "Gaze point Y [DACS px]", 0)
    idx_gx_fused_norm = get(
        col_map,
        "Gaze point X [ADCS norm]",
        get(col_map, "Gaze point X [MCS norm]", 0),
    )
    idx_gy_fused_norm = get(
        col_map,
        "Gaze point Y [ADCS norm]",
        get(col_map, "Gaze point Y [MCS norm]", 0),
    )

    use_fused_gaze =
        (idx_gxL == 0 && idx_gxR == 0 && idx_gxL_norm == 0 && idx_gxR_norm == 0) &&
        (idx_gx_fused > 0 || idx_gx_fused_norm > 0)

    idx_paL = get(col_map, "Pupil diameter left [mm]", get(col_map, "Pupil diameter left", 0))
    idx_paR = get(col_map, "Pupil diameter right [mm]", get(col_map, "Pupil diameter right", 0))
    idx_pa_fused = get(
        col_map,
        "Pupil diameter filtered [mm]",
        get(col_map, "Pupil diameter [mm]", 0),
    )
    use_fused_pupil = (idx_paL == 0 && idx_paR == 0 && idx_pa_fused > 0)

    idx_subj = get(col_map, "Participant name", 0)
    idx_trial = get(col_map, "Trial", get(col_map, "Trial number", 0))

    idx_em_type = get(col_map, "Eye movement type", 0)
    idx_em_dur = get(
        col_map,
        "Eye movement event duration [ms]",
        get(col_map, "Eye movement event duration", 0),
    )
    idx_em_idx = get(col_map, "Eye movement type index", 0)
    idx_fix_x = get(col_map, "Fixation point X [DACS px]", 0)
    idx_fix_y = get(col_map, "Fixation point Y [DACS px]", 0)

    return (;
        idx_time,
        time_scale,
        idx_sensor,
        idx_evt,
        idx_evt_val,
        idx_stim,
        idx_valL,
        idx_valR,
        idx_pvalL,
        idx_pvalR,
        idx_gxL,
        idx_gyL,
        idx_gxR,
        idx_gyR,
        idx_gxL_norm,
        idx_gyL_norm,
        idx_gxR_norm,
        idx_gyR_norm,
        idx_gx_fused,
        idx_gy_fused,
        idx_gx_fused_norm,
        idx_gy_fused_norm,
        use_fused_gaze,
        idx_paL,
        idx_paR,
        idx_pa_fused,
        use_fused_pupil,
        idx_subj,
        idx_trial,
        idx_em_type,
        idx_em_dur,
        idx_em_idx,
        idx_fix_x,
        idx_fix_y,
    )
end

"""
    read_tobii(path::String; kwargs...) -> TobiiFile

Read a Tobii Pro Lab Data Export TSV file and return a raw `TobiiFile`
container with parsed sample data and recording metadata.

Supply screen geometry via keyword arguments when needed; `sample_rate` is estimated
from the median consecutive timestamp interval.

# Keyword Arguments
- `screen_res::Tuple{Int,Int}`: screen resolution (default: `(1920, 1080)`)
- `screen_width_cm::Real`: physical screen width in cm (default: `53.0`)
- `viewing_distance_cm::Real`: distance to screen in cm (default: `60.0`)
- `verbose::Bool`: log summary metadata (default: `false`)

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
    verbose::Bool = false,
)
    isfile(path) || error("File not found: $path")

    tob = TobiiFile(path, screen_res, screen_width_cm, viewing_distance_cm)
    raw = Base.read(path)
    total_len = length(raw)

    estimated_samples = clamp(div(total_len, 80), 64, 3_000_000)

    times = sizehint!(Float64[], estimated_samples)
    trials = sizehint!(Int[], estimated_samples)
    participants = sizehint!(String[], estimated_samples)

    gxLs = sizehint!(Float32[], estimated_samples)
    gyLs = sizehint!(Float32[], estimated_samples)
    gxRs = sizehint!(Float32[], estimated_samples)
    gyRs = sizehint!(Float32[], estimated_samples)
    paLs = sizehint!(Float32[], estimated_samples)
    paRs = sizehint!(Float32[], estimated_samples)
    messages = sizehint!(String[], estimated_samples)

    native_evt = sizehint!(UInt8[], estimated_samples)
    native_dur = sizehint!(Int32[], estimated_samples)
    native_idx = sizehint!(Int32[], estimated_samples)
    native_fix_x = sizehint!(Float32[], estimated_samples)
    native_fix_y = sizehint!(Float32[], estimated_samples)

    event_times = sizehint!(Float64[], 64)
    event_types = sizehint!(String[], 64)
    event_msgs = sizehint!(String[], 64)

    header_parsed = false
    col_a = Int[]
    col_b = Int[]

    idx_time = idx_sensor = idx_evt = idx_evt_val = idx_stim = 0
    idx_valL = idx_valR = idx_pvalL = idx_pvalR = 0
    idx_gxL = idx_gyL = idx_paL = idx_gxR = idx_gyR = idx_paR = 0
    idx_gxL_norm = idx_gyL_norm = idx_gxR_norm = idx_gyR_norm = 0
    idx_gx_fused = idx_gy_fused = idx_gx_fused_norm = idx_gy_fused_norm = idx_pa_fused = 0
    idx_subj = idx_trial = 0
    idx_em_type = idx_em_dur = idx_em_idx = idx_fix_x = idx_fix_y = 0
    use_fused_gaze = false
    use_fused_pupil = false
    time_scale = 1.0
    res_w_f32 = Float32(screen_res[1])
    res_h_f32 = Float32(screen_res[2])

    empty_str = ""
    last_subj_a = 1
    last_subj_b = 0
    last_subj_str = empty_str

    last_stim_a = 1
    last_stim_b = 0
    seen_first_stim = false
    current_trial = 1
    pending_msg = empty_str

    pos = 1
    if total_len >= 3 && @inbounds(raw[1]) == 0xEF && @inbounds(raw[2]) == 0xBB && @inbounds(raw[3]) == 0xBF
        pos = 4
    end

    @inbounds while pos <= total_len
        nl = pos
        while nl <= total_len && raw[nl] != UInt8('\n')
            nl += 1
        end
        ls = pos
        le = nl - 1
        pos = nl + 1
        if le >= ls && raw[le] == UInt8('\r')
            le -= 1
        end
        ta, tb = _tsv_trim_span(raw, ls, le)
        ta > tb && continue

        if !header_parsed
            (;
                idx_time,
                time_scale,
                idx_sensor,
                idx_evt,
                idx_evt_val,
                idx_stim,
                idx_valL,
                idx_valR,
                idx_pvalL,
                idx_pvalR,
                idx_gxL,
                idx_gyL,
                idx_gxR,
                idx_gyR,
                idx_gxL_norm,
                idx_gyL_norm,
                idx_gxR_norm,
                idx_gyR_norm,
                idx_gx_fused,
                idx_gy_fused,
                idx_gx_fused_norm,
                idx_gy_fused_norm,
                use_fused_gaze,
                idx_paL,
                idx_paR,
                idx_pa_fused,
                use_fused_pupil,
                idx_subj,
                idx_trial,
                idx_em_type,
                idx_em_dur,
                idx_em_idx,
                idx_fix_x,
                idx_fix_y,
            ) = _parse_tobii_header!(col_a, col_b, raw, ls, le, path)
            header_parsed = true
            continue
        end

        n_cols = _tsv_split_spans!(col_a, col_b, raw, ls, le)

        t_a, t_b = _tobii_col_span(raw, col_a, col_b, n_cols, idx_time)
        t_a > t_b && continue
        t_ms = _bytes_parse_f64(raw, t_a, t_b) * time_scale
        isnan(t_ms) && continue

        # Reuse previous String across consecutive identical participant spans
        pa, pb = _tobii_col_span(raw, col_a, col_b, n_cols, idx_subj)
        if pa <= pb
            if !_spans_equal_bytes(raw, pa, pb, last_subj_a, last_subj_b)
                last_subj_a = pa
                last_subj_b = pb
                last_subj_str = _span_to_string(raw, pa, pb)
            end
        elseif last_subj_a <= last_subj_b && idx_sensor > 0
            # Keep participant across metadata rows when blank
        else
            last_subj_a = 1
            last_subj_b = 0
            last_subj_str = empty_str
        end
        participant = last_subj_str
        if isempty(tob.subject) && !isempty(participant)
            tob.subject = participant
        end

        sensor_is_et = true
        if idx_sensor > 0
            sna, snb = _tobii_col_span(raw, col_a, col_b, n_cols, idx_sensor)
            sensor_is_et = _span_eq_ascii(raw, sna, snb, "Eye Tracker")
        end

        if idx_trial > 0
            tra, trb = _tobii_col_span(raw, col_a, col_b, n_cols, idx_trial)
            if tra <= trb
                parsed_tr = _bytes_parse_int(raw, tra, trb)
                parsed_tr > 0 && (current_trial = parsed_tr)
            end
        end

        eva, evb = _tobii_col_span(raw, col_a, col_b, n_cols, idx_evt)
        vla, vlb = _tobii_col_span(raw, col_a, col_b, n_cols, idx_evt_val)
        sta, stb = _tobii_col_span(raw, col_a, col_b, n_cols, idx_stim)

        msg = empty_str
        if eva <= evb
            evt_str = _span_to_string(raw, eva, evb)
            msg = vla > vlb ? evt_str : (evt_str * ": " * _span_to_string(raw, vla, vlb))
            push!(event_times, t_ms)
            push!(event_types, "MSG")
            push!(event_msgs, msg)
            if sta <= stb && !_spans_equal_bytes(raw, sta, stb, last_stim_a, last_stim_b)
                last_stim_a = sta
                last_stim_b = stb
                stim_str = _span_to_string(raw, sta, stb)
                msg = msg * "; Stimulus: " * stim_str
                if idx_trial == 0
                    if seen_first_stim
                        current_trial += 1
                    else
                        seen_first_stim = true
                    end
                end
            end
        elseif sta <= stb
            if !_spans_equal_bytes(raw, sta, stb, last_stim_a, last_stim_b)
                last_stim_a = sta
                last_stim_b = stb
                stim_str = _span_to_string(raw, sta, stb)
                msg = "Stimulus: " * stim_str
                if idx_trial == 0
                    if seen_first_stim
                        current_trial += 1
                    else
                        seen_first_stim = true
                    end
                end
            end
        elseif idx_sensor == 0 || sensor_is_et
            last_stim_a = 1
            last_stim_b = 0
        end

        # Skip non-eye-tracker rows while forwarding any event text onto the nearest eye-tracker sample
        if !sensor_is_et
            if !isempty(msg)
                pending_msg = isempty(pending_msg) ? msg : (pending_msg * "; " * msg)
            end
            continue
        end

        if !isempty(pending_msg)
            msg = isempty(msg) ? pending_msg : (pending_msg * "; " * msg)
            pending_msg = empty_str
        end

        if use_fused_gaze
            gxL =
                idx_gx_fused > 0 ? _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gx_fused) :
                _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gx_fused_norm) * res_w_f32
            gyL =
                idx_gy_fused > 0 ? _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gy_fused) :
                _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gy_fused_norm) * res_h_f32
            gxR = NaN32
            gyR = NaN32
        else
            gxL =
                idx_gxL > 0 ? _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gxL) :
                (
                    idx_gxL_norm > 0 ?
                    _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gxL_norm) * res_w_f32 :
                    NaN32
                )
            gyL =
                idx_gyL > 0 ? _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gyL) :
                (
                    idx_gyL_norm > 0 ?
                    _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gyL_norm) * res_h_f32 :
                    NaN32
                )
            gxR =
                idx_gxR > 0 ? _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gxR) :
                (
                    idx_gxR_norm > 0 ?
                    _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gxR_norm) * res_w_f32 :
                    NaN32
                )
            gyR =
                idx_gyR > 0 ? _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gyR) :
                (
                    idx_gyR_norm > 0 ?
                    _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_gyR_norm) * res_h_f32 :
                    NaN32
                )
        end

        if use_fused_pupil
            paL = _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_pa_fused)
            paR = NaN32
        else
            paL = _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_paL)
            paR = _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_paR)
        end

        if idx_valL > 0 && _is_invalid_tobii_bytes(raw, col_a[min(idx_valL, n_cols)], idx_valL <= n_cols ? col_b[idx_valL] : 0)
            if !use_fused_gaze || idx_valR == 0 || (
                idx_valR <= n_cols && _is_invalid_tobii_bytes(raw, col_a[idx_valR], col_b[idx_valR])
            )
                gxL = gyL = NaN32
                idx_pvalL == 0 && !use_fused_pupil && (paL = NaN32)
            end
        end
        if idx_valR > 0 && idx_valR <= n_cols && _is_invalid_tobii_bytes(raw, col_a[idx_valR], col_b[idx_valR])
            gxR = gyR = NaN32
            idx_pvalR == 0 && (paR = NaN32)
        end
        if idx_pvalL > 0 && idx_pvalL <= n_cols && _is_invalid_tobii_bytes(raw, col_a[idx_pvalL], col_b[idx_pvalL])
            paL = NaN32
        end
        if idx_pvalR > 0 && idx_pvalR <= n_cols && _is_invalid_tobii_bytes(raw, col_a[idx_pvalR], col_b[idx_pvalR])
            paR = NaN32
        end

        if idx_em_type > 0 && idx_em_type <= n_cols
            ema, emb = _tsv_trim_span(raw, col_a[idx_em_type], col_b[idx_em_type])
            em_code =
                _span_eq_ascii(raw, ema, emb, "Fixation") ? 0x01 :
                _span_eq_ascii(raw, ema, emb, "Saccade") ? 0x02 :
                _span_eq_ascii(raw, ema, emb, "EyesNotFound") ? 0x03 : 0x00
            em_d =
                (idx_em_dur > 0 && idx_em_dur <= n_cols) ?
                Int32(clamp(_bytes_parse_int(raw, col_a[idx_em_dur], col_b[idx_em_dur]), 0, Int(typemax(Int32)))) :
                Int32(0)
            em_i =
                (idx_em_idx > 0 && idx_em_idx <= n_cols) ?
                Int32(clamp(_bytes_parse_int(raw, col_a[idx_em_idx], col_b[idx_em_idx]), 0, Int(typemax(Int32)))) :
                Int32(0)
            fx = _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_fix_x)
            fy = _tobii_parse_f32_col(raw, col_a, col_b, n_cols, idx_fix_y)
            push!(native_evt, em_code)
            push!(native_dur, em_d)
            push!(native_idx, em_i)
            push!(native_fix_x, fx)
            push!(native_fix_y, fy)
        end

        push!(times, t_ms)
        push!(trials, current_trial)
        push!(participants, participant)
        push!(gxLs, gxL)
        push!(gyLs, gyL)
        push!(gxRs, gxR)
        push!(gyRs, gyR)
        push!(paLs, paL)
        push!(paRs, paR)
        push!(messages, msg)
    end

    if !isempty(pending_msg) && !isempty(messages)
        messages[end] =
            isempty(messages[end]) ? pending_msg : (messages[end] * "; " * pending_msg)
    end

    n = length(times)
    df = DataFrame(
        time = times,
        trial = trials,
        participant = participants,
        gxL = gxLs,
        gyL = gyLs,
        paL = paLs,
        gxR = gxRs,
        gyR = gyRs,
        paR = paRs,
        message = messages;
        copycols = false,
    )

    ev_df = DataFrame(
        time = event_times,
        type = event_types,
        message = event_msgs;
        copycols = false,
    )

    tob.samples = df
    tob.events = ev_df
    if length(native_evt) == n
        tob.native_evt = native_evt
        tob.native_dur = native_dur
        tob.native_idx = native_idx
        tob.native_fix_x = native_fix_x
        tob.native_fix_y = native_fix_y
    end

    if n > 1
        n_check = min(n, 2000)
        valid_diffs = Float64[]
        sizehint!(valid_diffs, n_check)
        @inbounds for i = 2:n_check
            dt = times[i] - times[i-1]
            dt > 0.0 && push!(valid_diffs, dt)
        end
        if !isempty(valid_diffs)
            med_diff_ms = median!(valid_diffs)
            if med_diff_ms > 0
                tob.sample_rate = 1000.0 / med_diff_ms
            end
        end
    end

    verbose && @info "Tobii TSV: $n samples, $(tob.sample_rate) Hz, subject=$(tob.subject)"
    return tob
end

@inline function _tobii_row_gaze_pupil(
    gxL::Float32,
    gyL::Float32,
    paL::Float32,
    gxR::Float32,
    gyR::Float32,
    paR::Float32,
)
    vl = !isnan(gxL) && !isnan(gyL)
    vr = !isnan(gxR) && !isnan(gyR)
    gx = vl && vr ? 0.5 * (Float64(gxL) + Float64(gxR)) : vl ? Float64(gxL) : vr ? Float64(gxR) : NaN
    gy = vl && vr ? 0.5 * (Float64(gyL) + Float64(gyR)) : vl ? Float64(gyL) : vr ? Float64(gyR) : NaN
    pl = !isnan(paL)
    pr = !isnan(paR)
    pa = pl && pr ? 0.5 * (Float64(paL) + Float64(paR)) : pl ? Float64(paL) : pr ? Float64(paR) : NaN
    return (gx, gy, pa)
end

function _stamp_tobii_events!(df::DataFrame, tob::TobiiFile, ppd::Float64)
    n = nrow(df)
    times = df[!, :time]
    trials = df[!, :trial]
    parts = df[!, :participant]
    gxLs = df[!, :gxL]
    gyLs = df[!, :gyL]
    paLs = df[!, :paL]
    gxRs = df[!, :gxR]
    gyRs = df[!, :gyR]
    paRs = df[!, :paR]

    codes = tob.native_evt
    durs = tob.native_dur
    idxs = tob.native_idx
    fxs = tob.native_fix_x
    fys = tob.native_fix_y
    inv_ppd = ppd > 0.0 ? 1.0 / ppd : 0.025

    in_fix = falses(n)
    fix_gavx = fill(NaN, n)
    fix_gavy = fill(NaN, n)
    fix_ava = fill(NaN, n)
    fix_dur = fill(Int32(0), n)
    in_sacc = falses(n)
    sacc_gstx = fill(NaN, n)
    sacc_gsty = fill(NaN, n)
    sacc_genx = fill(NaN, n)
    sacc_geny = fill(NaN, n)
    sacc_dur = fill(Int32(0), n)
    sacc_ampl = fill(NaN, n)
    sacc_pvel = fill(NaN, n)
    in_blink = falses(n)
    blink_dur = fill(Int32(0), n)

    i = 1
    @inbounds while i <= n
        code = codes[i]
        if code == 0x00
            i += 1
            continue
        end
        tr_i = trials[i]
        p_i = parts[i]
        idx_i = idxs[i]
        j = i
        while j < n &&
                  codes[j+1] == code &&
                  isequal(trials[j+1], tr_i) &&
                  isequal(parts[j+1], p_i) &&
                  times[j+1] >= times[j] &&
                  (idx_i == 0 || idxs[j+1] == idx_i)
            j += 1
        end

        # Keep a 1-sample boundary gap if the next sample immediately starts a distinct
        # event of the exact same class within the same trial/participant.
        hi = j
        if j < n &&
           j > i &&
           codes[j+1] == code &&
           isequal(trials[j+1], tr_i) &&
           isequal(parts[j+1], p_i) &&
           times[j+1] >= times[j]
            hi = j - 1
        end

        d_ms = durs[i] > 0 ? durs[i] : round(Int32, max(0.0, times[hi] - times[i]))
        if code == 0x01
            sx = 0.0
            sy = 0.0
            ng = 0
            sp = 0.0
            np = 0
            for k = i:hi
                gx, gy, pa = _tobii_row_gaze_pupil(gxLs[k], gyLs[k], paLs[k], gxRs[k], gyRs[k], paRs[k])
                if !isnan(gx) && !isnan(gy)
                    sx += gx
                    sy += gy
                    ng += 1
                end
                if !isnan(pa)
                    sp += pa
                    np += 1
                end
            end
            mx = !isnan(fxs[i]) ? Float64(fxs[i]) : (ng > 0 ? sx / ng : NaN)
            my = !isnan(fys[i]) ? Float64(fys[i]) : (ng > 0 ? sy / ng : NaN)
            mp = np > 0 ? sp / np : NaN
            for k = i:hi
                in_fix[k] = true
                fix_gavx[k] = mx
                fix_gavy[k] = my
                fix_ava[k] = mp
                fix_dur[k] = d_ms
            end
        elseif code == 0x02
            sx = NaN
            sy = NaN
            for k = i:hi
                gx, gy, _ = _tobii_row_gaze_pupil(gxLs[k], gyLs[k], paLs[k], gxRs[k], gyRs[k], paRs[k])
                if !isnan(gx) && !isnan(gy)
                    sx = gx
                    sy = gy
                    break
                end
            end
            ex = NaN
            ey = NaN
            for k = hi:-1:i
                gx, gy, _ = _tobii_row_gaze_pupil(gxLs[k], gyLs[k], paLs[k], gxRs[k], gyRs[k], paRs[k])
                if !isnan(gx) && !isnan(gy)
                    ex = gx
                    ey = gy
                    break
                end
            end
            amp = (!isnan(sx) && !isnan(ex)) ? hypot(ex - sx, ey - sy) * inv_ppd : NaN
            pv = NaN
            prev_x = NaN
            prev_y = NaN
            prev_t = NaN
            for k = i:hi
                gx, gy, _ = _tobii_row_gaze_pupil(gxLs[k], gyLs[k], paLs[k], gxRs[k], gyRs[k], paRs[k])
                tk = times[k]
                if !isnan(gx) && !isnan(gy)
                    if !isnan(prev_x) && tk > prev_t
                        v_step = (hypot(gx - prev_x, gy - prev_y) * inv_ppd) / ((tk - prev_t) * 1e-3)
                        if isnan(pv) || v_step > pv
                            pv = v_step
                        end
                    end
                    prev_x = gx
                    prev_y = gy
                    prev_t = tk
                end
            end
            for k = i:hi
                in_sacc[k] = true
                sacc_gstx[k] = sx
                sacc_gsty[k] = sy
                sacc_genx[k] = ex
                sacc_geny[k] = ey
                sacc_dur[k] = d_ms
                sacc_ampl[k] = amp
                sacc_pvel[k] = pv
            end
        elseif code == 0x03
            for k = i:hi
                in_blink[k] = true
                blink_dur[k] = d_ms
            end
        end

        i = j + 1
    end

    df[!, :in_fix] = in_fix
    df[!, :fix_gavx] = fix_gavx
    df[!, :fix_gavy] = fix_gavy
    df[!, :fix_ava] = fix_ava
    df[!, :fix_dur] = fix_dur
    df[!, :in_sacc] = in_sacc
    df[!, :sacc_gstx] = sacc_gstx
    df[!, :sacc_gsty] = sacc_gsty
    df[!, :sacc_genx] = sacc_genx
    df[!, :sacc_geny] = sacc_geny
    df[!, :sacc_dur] = sacc_dur
    df[!, :sacc_ampl] = sacc_ampl
    df[!, :sacc_pvel] = sacc_pvel
    df[!, :in_blink] = in_blink
    df[!, :blink_dur] = blink_dur
    return df
end
