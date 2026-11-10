"""
    read_smi(path::String; events_path=nothing, verbose=false) -> SMIFile

Read an SMI data file (`.txt` text export or `.idf` binary) and return a raw
`SMIFile` container with parsed sample data and recording metadata.

The function auto-detects the format from the file extension. When `events_path`
points to an SMI BeGaze `*_events.txt` export, fixation/saccade/blink rows are
parsed into `smi.events` and can be stamped onto `EyeData` with
`create_eyefun_data(smi; include_events=true)`.

Screen geometry (`screen_width_cm`, `viewing_distance_cm`) is extracted directly
from the file header (`Stimulus Dimension [mm]` and `Head Distance [mm]`). If
these header fields are absent, conservative defaults are used (30 cm / 50 cm).

Pass the returned `SMIFile` to `create_eyefun_data` and `detect_events!` to detect events:

```julia
raw = read_smi("pp23671_rest1_samples.txt")
ed  = create_eyefun_data(raw)
detect_events!(ed)
fixations(ed)
saccades(ed)
blinks(ed)
plot_gaze(ed)
```
"""
function read_smi(
    path::String;
    events_path::Union{Nothing,String} = nothing,
    verbose::Bool = false,
)
    isfile(path) || error("File not found: $path")
    ext = lowercase(splitext(path)[2])
    smi = if ext == ".txt"
        _read_smi_txt(path; verbose = verbose)
    elseif ext == ".idf"
        _read_smi_idf(path; verbose = verbose)
    else
        error("Unknown SMI file extension: $ext. Expected .txt or .idf")
    end
    resolved_ev = events_path
    if isnothing(resolved_ev) && ext == ".txt" && ncodeunits(path) > 12
        tail = SubString(path, ncodeunits(path) - 11, ncodeunits(path))
        if lowercase(tail) == "_samples.txt"
            cand = SubString(path, 1, ncodeunits(path) - 12) * "_events.txt"
            isfile(cand) && (resolved_ev = cand)
        end
    end
    if !isnothing(resolved_ev)
        isfile(resolved_ev) || error("SMI events file not found: $resolved_ev")
        ev_df = _read_smi_events_txt(resolved_ev)
        if nrow(ev_df) > 0
            smi.events = nrow(smi.events) > 0 ? vcat(smi.events, ev_df; cols = :union) : ev_df
        end
    end
    return smi
end

const _BYTE_POW10 = (
    1.0,
    10.0,
    100.0,
    1_000.0,
    10_000.0,
    100_000.0,
    1_000_000.0,
    10_000_000.0,
    100_000_000.0,
    1_000_000_000.0,
    10_000_000_000.0,
    100_000_000_000.0,
)

@inline function _tsv_trim_span(data::Vector{UInt8}, a::Int, b::Int)
    @inbounds while a <= b && (data[a] == UInt8(' ') || data[a] == UInt8('\r') || data[a] == UInt8('\t'))
        a += 1
    end
    @inbounds while b >= a && (data[b] == UInt8(' ') || data[b] == UInt8('\r') || data[b] == UInt8('\t'))
        b -= 1
    end
    return (a, b)
end

@inline function _tsv_split_spans!(
    col_a::Vector{Int},
    col_b::Vector{Int},
    data::Vector{UInt8},
    ls::Int,
    le::Int,
)::Int
    cap = length(col_a)
    col = 0
    start = ls
    @inbounds for i = ls:le
        if data[i] == UInt8('\t')
            col += 1
            if col <= cap
                col_a[col] = start
                col_b[col] = i - 1
            end
            start = i + 1
        end
    end
    col += 1
    if col <= cap
        @inbounds col_a[col] = start
        @inbounds col_b[col] = le
    end
    return col
end

@inline function _span_eq_ascii(data::Vector{UInt8}, a::Int, b::Int, s::AbstractString)::Bool
    len = b - a + 1
    len == ncodeunits(s) || return false
    @inbounds for k = 1:len
        data[a+k-1] == codeunit(s, k) || return false
    end
    return true
end

@inline function _span_starts_with_ascii(
    data::Vector{UInt8},
    a::Int,
    b::Int,
    s::AbstractString,
)::Bool
    len = ncodeunits(s)
    b - a + 1 >= len || return false
    @inbounds for k = 1:len
        data[a+k-1] == codeunit(s, k) || return false
    end
    return true
end

@inline function _span_to_string(data::Vector{UInt8}, a::Int, b::Int)::String
    a > b && return ""
    return GC.@preserve data unsafe_string(pointer(data, a), b - a + 1)
end

@inline function _bytes_parse_int(data::Vector{UInt8}, a::Int, b::Int)::Int
    a, b = _tsv_trim_span(data, a, b)
    a > b && return 0
    neg = false
    @inbounds c0 = data[a]
    if c0 == UInt8('-')
        neg = true
        a += 1
    elseif c0 == UInt8('+')
        a += 1
    end
    a > b && return 0
    acc = 0
    @inbounds for i = a:b
        c = data[i]
        if UInt8('0') <= c <= UInt8('9')
            acc = acc * 10 + Int(c - UInt8('0'))
        else
            v = tryparse(Int, _span_to_string(data, a, b))
            return isnothing(v) ? 0 : (neg ? -v : v)
        end
    end
    return neg ? -acc : acc
end

@inline function _bytes_parse_f64(data::Vector{UInt8}, a::Int, b::Int)::Float64
    a, b = _tsv_trim_span(data, a, b)
    a > b && return NaN
    neg = false
    @inbounds b1 = data[a]
    if b1 == UInt8('-')
        neg = true
        a += 1
    elseif b1 == UInt8('+')
        a += 1
    end
    a > b && return NaN
    acc = Int64(0)
    n_frac = 0
    in_frac = false
    n_digits = 0
    @inbounds for i = a:b
        c = data[i]
        if UInt8('0') <= c <= UInt8('9')
            n_digits += 1
            if n_digits <= 17
                acc = acc * 10 + Int64(c - UInt8('0'))
                in_frac && (n_frac += 1)
            else
                s = _span_to_string(data, neg ? a - 1 : a, b)
                v = tryparse(Float64, occursin(',', s) ? replace(s, ',' => '.') : s)
                return (isnothing(v) || !isfinite(v)) ? NaN : v
            end
        elseif (c == UInt8('.') || c == UInt8(',')) && !in_frac
            in_frac = true
        else
            s = _span_to_string(data, neg ? a - 1 : a, b)
            v = tryparse(Float64, occursin(',', s) ? replace(s, ',' => '.') : s)
            return (isnothing(v) || !isfinite(v)) ? NaN : v
        end
    end
    n_digits == 0 && return NaN
    val =
        n_frac == 0 ? Float64(acc) :
        (
            n_frac <= 11 ? Float64(acc) / @inbounds(_BYTE_POW10[n_frac+1]) :
            Float64(acc) * 10.0^(-n_frac)
        )
    return neg ? -val : val
end

@inline function _smi_le_u32(data::Vector{UInt8}, off::Integer)
    return ltoh(GC.@preserve data unsafe_load(Ptr{UInt32}(pointer(data, Int(off)))))
end

@inline function _smi_le_i32(data::Vector{UInt8}, off::Integer)
    return ltoh(GC.@preserve data unsafe_load(Ptr{Int32}(pointer(data, Int(off)))))
end

@inline function _smi_le_f64(data::Vector{UInt8}, off::Integer)
    return ltoh(GC.@preserve data unsafe_load(Ptr{Float64}(pointer(data, Int(off)))))
end


function _parse_smi_txt_columns!(
    col_a::Vector{Int},
    col_b::Vector{Int},
    raw::Vector{UInt8},
    sa::Int,
    sb::Int,
    path::String,
)
    idx_time = idx_type = idx_trial = idx_trigger = 0
    idx_lpx = idx_lpy = idx_lrx = idx_lry = idx_ldx = idx_ldy = 0
    idx_rpx = idx_rpy = idx_rrx = idx_rry = idx_rdx = idx_rdy = 0

    col_header = split(_span_to_string(raw, sa, sb), '\t')
    for (ci, h_raw) in enumerate(col_header)
        h = strip(h_raw)
        if h == "Time" && idx_time == 0
            idx_time = ci
        elseif h == "Type" && idx_type == 0
            idx_type = ci
        elseif h == "Trial" && idx_trial == 0
            idx_trial = ci
        elseif h == "Trigger" && idx_trigger == 0
            idx_trigger = ci
        elseif h == "L POR X [px]" && idx_lpx == 0
            idx_lpx = ci
        elseif h == "L POR Y [px]" && idx_lpy == 0
            idx_lpy = ci
        elseif h == "L Raw X [px]" && idx_lrx == 0
            idx_lrx = ci
        elseif h == "L Raw Y [px]" && idx_lry == 0
            idx_lry = ci
        elseif h == "L Dia X [px]" && idx_ldx == 0
            idx_ldx = ci
        elseif h == "L Dia Y [px]" && idx_ldy == 0
            idx_ldy = ci
        elseif h == "R POR X [px]" && idx_rpx == 0
            idx_rpx = ci
        elseif h == "R POR Y [px]" && idx_rpy == 0
            idx_rpy = ci
        elseif h == "R Raw X [px]" && idx_rrx == 0
            idx_rrx = ci
        elseif h == "R Raw Y [px]" && idx_rry == 0
            idx_rry = ci
        elseif h == "R Dia X [px]" && idx_rdx == 0
            idx_rdx = ci
        elseif h == "R Dia Y [px]" && idx_rdy == 0
            idx_rdy = ci
        end
    end
    idx_time == 0 && error("Required 'Time' column not found in SMI TXT header: $path")

    need_cols = max(length(col_header) + 4, 24)
    if length(col_a) < need_cols
        resize!(col_a, need_cols)
        resize!(col_b, need_cols)
    end
    return (;
        idx_time,
        idx_type,
        idx_trial,
        idx_trigger,
        idx_lpx,
        idx_lpy,
        idx_lrx,
        idx_lry,
        idx_ldx,
        idx_ldy,
        idx_rpx,
        idx_rpy,
        idx_rrx,
        idx_rry,
        idx_rdx,
        idx_rdy,
    )
end

function _read_smi_txt(path::String; verbose::Bool = false)
    raw = Base.read(path)
    n_bytes = length(raw)

    sample_rate = 0.0
    screen_res = (1280, 1024)
    subject = ""
    stim_width_mm = 0.0
    head_dist_mm = 0.0

    est = clamp(div(n_bytes, 65), 64, 3_000_000)
    time_vec = sizehint!(Float64[], est)
    trial_vec = sizehint!(Int[], est)
    msg_vec = sizehint!(String[], est)
    gxL = sizehint!(Float32[], est)
    gyL = sizehint!(Float32[], est)
    paL = sizehint!(Float32[], est)
    gxR = sizehint!(Float32[], est)
    gyR = sizehint!(Float32[], est)
    paR = sizehint!(Float32[], est)
    pupxL = sizehint!(Float32[], est)
    pupyL = sizehint!(Float32[], est)
    pupxR = sizehint!(Float32[], est)
    pupyR = sizehint!(Float32[], est)
    evt_times = Float64[]
    evt_msgs = String[]

    header_parsed = false
    col_a = Vector{Int}(undef, 32)
    col_b = Vector{Int}(undef, 32)

    idx_time = 0
    idx_type = 0
    idx_trial = 0
    idx_trigger = 0
    idx_lpx = idx_lpy = idx_lrx = idx_lry = idx_ldx = idx_ldy = 0
    idx_rpx = idx_rpy = idx_rrx = idx_rry = idx_rdx = idx_rdy = 0

    int_trig_cache = Dict{Int,String}()
    str_trig_cache = Dict{String,String}()
    pending_msg = ""
    NaN32 = Float32(NaN)

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
        ls > le && continue

        if !header_parsed
            sa, sb = _tsv_trim_span(raw, ls, le)
            sa > sb && continue
            if sb - sa >= 1 && @inbounds(raw[sa]) == UInt8('#') && @inbounds(raw[sa+1]) == UInt8('#')
                line_s = _span_to_string(raw, sa + 2, sb)
                content = lstrip(line_s)
                if startswith(content, "Sample Rate:")
                    sample_rate = parse(Float64, strip(split(content, '\t')[end]))
                elseif startswith(content, "Calibration Area:")
                    parts = split(content, '\t')
                    if length(parts) >= 3
                        w = parse(Int, strip(parts[end-1]))
                        h = parse(Int, strip(parts[end]))
                        screen_res = (w, h)
                    end
                elseif startswith(content, "Subject:")
                    subject = String(strip(split(content, '\t')[end]))
                elseif startswith(content, "Stimulus Dimension [mm]:")
                    parts = split(content, '\t')
                    if length(parts) >= 3
                        stim_width_mm = parse(Float64, strip(parts[end-1]))
                    end
                elseif startswith(content, "Head Distance [mm]:")
                    head_dist_mm = parse(Float64, strip(split(content, '\t')[end]))
                end
                continue
            end

            (;
                idx_time,
                idx_type,
                idx_trial,
                idx_trigger,
                idx_lpx,
                idx_lpy,
                idx_lrx,
                idx_lry,
                idx_ldx,
                idx_ldy,
                idx_rpx,
                idx_rpy,
                idx_rrx,
                idx_rry,
                idx_rdx,
                idx_rdy,
            ) = _parse_smi_txt_columns!(col_a, col_b, raw, sa, sb, path)
            header_parsed = true
            continue
        end

        n_cols = _tsv_split_spans!(col_a, col_b, raw, ls, le)
        (idx_type == 0 || n_cols < max(idx_type, idx_time)) && continue
        ta, tb = _tsv_trim_span(raw, @inbounds(col_a[idx_type]), @inbounds(col_b[idx_type]))

        if _span_eq_ascii(raw, ta, tb, "MSG")
            t_ms = _bytes_parse_f64(raw, @inbounds(col_a[idx_time]), @inbounds(col_b[idx_time])) / 1000.0
            if !isnan(t_ms)
                m_txt = ""
                found_hash_msg = false
                for mc = (idx_type+1):n_cols
                    ma, mb = _tsv_trim_span(raw, @inbounds(col_a[mc]), @inbounds(col_b[mc]))
                    if _span_starts_with_ascii(raw, ma, mb, "# Message:")
                        ma2, mb2 = _tsv_trim_span(raw, ma + 10, mb)
                        m_txt = _span_to_string(raw, ma2, mb2)
                        found_hash_msg = true
                        break
                    end
                end
                if !found_hash_msg
                    fallback_c = idx_trial > idx_type && idx_trial < n_cols ? idx_trial + 1 : idx_type + 1
                    if fallback_c <= n_cols
                        ma, mb = _tsv_trim_span(raw, @inbounds(col_a[fallback_c]), @inbounds(col_b[fallback_c]))
                        m_txt = _span_to_string(raw, ma, mb)
                    end
                end
                if !isempty(m_txt)
                    push!(evt_times, t_ms)
                    push!(evt_msgs, m_txt)
                    pending_msg = isempty(pending_msg) ? m_txt : (pending_msg * "; " * m_txt)
                end
            end
            continue
        end

        _span_eq_ascii(raw, ta, tb, "SMP") || continue

        # Time: µs → ms
        t_ms = _bytes_parse_f64(raw, @inbounds(col_a[idx_time]), @inbounds(col_b[idx_time])) / 1000.0
        push!(time_vec, t_ms)
        tr_val =
            (idx_trial > 0 && idx_trial <= n_cols) ?
            _bytes_parse_int(raw, @inbounds(col_a[idx_trial]), @inbounds(col_b[idx_trial])) : 1
        push!(trial_vec, tr_val)

        # Trigger -> message (cache integer trigger strings)
        msg_str = ""
        if idx_trigger > 0 && idx_trigger <= n_cols
            ga, gb = _tsv_trim_span(raw, @inbounds(col_a[idx_trigger]), @inbounds(col_b[idx_trigger]))
            if ga <= gb && !(ga == gb && @inbounds(raw[ga]) == UInt8('0'))
                is_digits = true
                trig_int = 0
                @inbounds for k = ga:gb
                    c = raw[k]
                    if UInt8('0') <= c <= UInt8('9')
                        trig_int = trig_int * 10 + Int(c - UInt8('0'))
                    else
                        is_digits = false
                        break
                    end
                end
                if is_digits
                    if trig_int != 0
                        cached_s = get(int_trig_cache, trig_int, nothing)
                        if isnothing(cached_s)
                            cached_s = string(trig_int)
                            int_trig_cache[trig_int] = cached_s
                        end
                        msg_str = cached_s
                    end
                else
                    raw_t = _span_to_string(raw, ga, gb)
                    msg_str = get!(str_trig_cache, raw_t, raw_t)
                end
                if !isempty(msg_str)
                    push!(evt_times, t_ms)
                    push!(evt_msgs, msg_str)
                end
            end
        end
        if !isempty(pending_msg)
            msg_str = isempty(msg_str) ? pending_msg : (pending_msg * "; " * msg_str)
            pending_msg = ""
        end
        push!(msg_vec, msg_str)

        # Left raw pupil position (camera coords)
        lrx, lry = NaN, NaN
        if idx_lrx > 0 && idx_lrx <= n_cols && idx_lry > 0 && idx_lry <= n_cols
            lrx = _bytes_parse_f64(raw, @inbounds(col_a[idx_lrx]), @inbounds(col_b[idx_lrx]))
            lry = _bytes_parse_f64(raw, @inbounds(col_a[idx_lry]), @inbounds(col_b[idx_lry]))
            if lrx == 0.0 && lry == 0.0
                lrx = NaN
                lry = NaN
            end
        end
        push!(pupxL, Float32(lrx))
        push!(pupyL, Float32(lry))

        # Left calibrated gaze (POR); fall back to raw if POR absent
        lx, ly = 0.0, 0.0
        if idx_lpx > 0 && idx_lpx <= n_cols && idx_lpy > 0 && idx_lpy <= n_cols
            lx = _bytes_parse_f64(raw, @inbounds(col_a[idx_lpx]), @inbounds(col_b[idx_lpx]))
            ly = _bytes_parse_f64(raw, @inbounds(col_a[idx_lpy]), @inbounds(col_b[idx_lpy]))
        elseif idx_lrx > 0
            lx = isnan(lrx) ? 0.0 : lrx
            ly = isnan(lry) ? 0.0 : lry
        end
        pa_l = 0.0
        if idx_ldx > 0 && idx_ldx <= n_cols
            pdx = _bytes_parse_f64(raw, @inbounds(col_a[idx_ldx]), @inbounds(col_b[idx_ldx]))
            pdy =
                (idx_ldy > 0 && idx_ldy <= n_cols) ?
                _bytes_parse_f64(raw, @inbounds(col_a[idx_ldy]), @inbounds(col_b[idx_ldy])) : pdx
            pa_l = (pdx + pdy) / 2.0
        end
        l_miss = (lx == 0.0 && ly == 0.0) || isnan(lx) || isnan(ly)
        push!(gxL, l_miss ? NaN32 : Float32(lx))
        push!(gyL, l_miss ? NaN32 : Float32(ly))
        push!(paL, (pa_l == 0.0 || isnan(pa_l)) ? NaN32 : Float32(pa_l))

        # Right raw pupil position
        rrx, rry = NaN, NaN
        if idx_rrx > 0 && idx_rrx <= n_cols && idx_rry > 0 && idx_rry <= n_cols
            rrx = _bytes_parse_f64(raw, @inbounds(col_a[idx_rrx]), @inbounds(col_b[idx_rrx]))
            rry = _bytes_parse_f64(raw, @inbounds(col_a[idx_rry]), @inbounds(col_b[idx_rry]))
            if rrx == 0.0 && rry == 0.0
                rrx = NaN
                rry = NaN
            end
        end
        push!(pupxR, Float32(rrx))
        push!(pupyR, Float32(rry))

        # Right calibrated gaze (POR); fall back to raw if POR absent
        rx, ry = 0.0, 0.0
        if idx_rpx > 0 && idx_rpx <= n_cols && idx_rpy > 0 && idx_rpy <= n_cols
            rx = _bytes_parse_f64(raw, @inbounds(col_a[idx_rpx]), @inbounds(col_b[idx_rpx]))
            ry = _bytes_parse_f64(raw, @inbounds(col_a[idx_rpy]), @inbounds(col_b[idx_rpy]))
        elseif idx_rrx > 0
            rx = isnan(rrx) ? 0.0 : rrx
            ry = isnan(rry) ? 0.0 : rry
        end
        pa_r = 0.0
        if idx_rdx > 0 && idx_rdx <= n_cols
            rdx = _bytes_parse_f64(raw, @inbounds(col_a[idx_rdx]), @inbounds(col_b[idx_rdx]))
            rdy =
                (idx_rdy > 0 && idx_rdy <= n_cols) ?
                _bytes_parse_f64(raw, @inbounds(col_a[idx_rdy]), @inbounds(col_b[idx_rdy])) : rdx
            pa_r = (rdx + rdy) / 2.0
        end
        r_miss = (rx == 0.0 && ry == 0.0) || isnan(rx) || isnan(ry)
        push!(gxR, r_miss ? NaN32 : Float32(rx))
        push!(gyR, r_miss ? NaN32 : Float32(ry))
        push!(paR, (pa_r == 0.0 || isnan(pa_r)) ? NaN32 : Float32(pa_r))
    end

    if !isempty(pending_msg) && !isempty(msg_vec)
        msg_vec[end] =
            isempty(msg_vec[end]) ? pending_msg : (msg_vec[end] * "; " * pending_msg)
    end

    # Screen geometry from file header; fall back to SMI RED typical values
    screen_width_cm = stim_width_mm > 0 ? stim_width_mm / 10.0 : 30.0
    viewing_distance_cm = head_dist_mm > 0 ? head_dist_mm / 10.0 : 50.0
    if isempty(subject)
        subject = replace(splitext(basename(path))[1], r"_samples$"i => "")
    end

    n = length(time_vec)
    if sample_rate <= 0.0 && n > 1
        sample_rate = _estimate_sample_rate_typed(time_vec)
    end
    df = DataFrame(
        time = time_vec,
        trial = trial_vec,
        participant = fill(subject, n),
        gxL = gxL,
        gyL = gyL,
        paL = paL,
        gxR = gxR,
        gyR = gyR,
        paR = paR,
        pupxL = pupxL,
        pupyL = pupyL,
        pupxR = pupxR,
        pupyR = pupyR,
        message = msg_vec;
        copycols = false,
    )

    verbose && @info "SMI TXT: $n samples, $sample_rate Hz, subject=$subject"

    smi = SMIFile(path)
    smi.samples = df
    smi.events = DataFrame(
        time = evt_times,
        type = fill("MSG", length(evt_times)),
        message = evt_msgs;
        copycols = false,
    )
    smi.sample_rate = sample_rate
    smi.screen_res = screen_res
    smi.screen_width_cm = Float64(screen_width_cm)
    smi.viewing_distance_cm = Float64(viewing_distance_cm)
    smi.subject = subject
    return smi
end

function _read_smi_idf(path::String; verbose::Bool = false)

    data = read(path)
    n_bytes = length(data)
    n_bytes >= 16 || error("IDF file too small: $path")

    # Screen geometry defaults (IDF header doesn't reliably encode physical dims)
    screen_width_cm = 30.0
    viewing_distance_cm = 60.0

    # Find the ASCII column-header string starting with "TimeStamp"
    header_str = ""
    col_offset = 0
    @inbounds for i = 1:(n_bytes-9)
        if data[i] == UInt8('T') &&
           data[i+1] == UInt8('i') &&
           data[i+2] == UInt8('m') &&
           data[i+3] == UInt8('e') &&
           data[i+4] == UInt8('S') &&
           data[i+5] == UInt8('t')
            j = i
            while j <= n_bytes && data[j] >= 0x20 && data[j] <= 0x7e
                j += 1
            end
            header_str = String(data[i:(j-1)])
            col_offset = j
            break
        end
    end
    isempty(header_str) && error("Could not find column header in IDF file.")

    col_names = split(strip(header_str))
    has_right_cols = any(startswith(c, "R") && c ∉ ("Trig",) for c in col_names)

    # Sample rate (fixed offset heuristic for IDF v9)
    sample_rate = 0.0
    screen_res = (1280, 1024)
    if n_bytes > 0x2DC
        sr_candidate = _smi_le_i32(data, 0x2D3)
        if sr_candidate > 0 && sr_candidate <= 2000
            sample_rate = Float64(sr_candidate)
        end
    end
    header_sample_rate = sample_rate

    # Skip null padding after column header
    pos = col_offset
    @inbounds while pos <= n_bytes && data[pos] == 0x00
        pos += 1
    end

    # Locate sub-record start via timestamp consistency scan
    sub_record_size = 106
    data_start = 0
    found_data = false

    for try_offset = pos:4:min(pos+64, n_bytes-4*sub_record_size)
        ts1 = _smi_le_u32(data, try_offset + 4)
        ts1 > 1_000_000 || continue

        ts2 = _smi_le_u32(data, try_offset + sub_record_size + 4)
        ts3 = _smi_le_u32(data, try_offset + 2 * sub_record_size + 4)

        d1 = (ts2 >= ts1) ? (ts2 - ts1) : ((0xFFFFFFFF - ts1) + ts2 + 1)
        d2 = (ts3 >= ts2) ? (ts3 - ts2) : ((0xFFFFFFFF - ts2) + ts3 + 1)

        if d1 > 0 && d2 > 0 && abs(Int64(d2) - Int64(d1)) < 0.05 * Int64(d1)
            data_start = try_offset
            found_data = true
            break
        elseif has_right_cols &&
               ts1 == ts2 &&
               try_offset + 5 * sub_record_size <= n_bytes + 1
            ts4 = _smi_le_u32(data, try_offset + 3 * sub_record_size + 4)
            ts5 = _smi_le_u32(data, try_offset + 4 * sub_record_size + 4)
            dp1 = (ts3 >= ts1) ? (ts3 - ts1) : ((0xFFFFFFFF - ts1) + ts3 + 1)
            dp2 = (ts5 >= ts3) ? (ts5 - ts3) : ((0xFFFFFFFF - ts3) + ts5 + 1)
            if ts3 == ts4 &&
               dp1 > 0 &&
               dp2 > 0 &&
               abs(Int64(dp2) - Int64(dp1)) < 0.05 * Int64(dp1)
                data_start = try_offset
                found_data = true
                break
            end
        end
    end

    found_data ||
        error("Could not locate IDF sub-record data. Use the .txt export instead.")

    n_sub_records = (n_bytes - data_start + 1) ÷ sub_record_size

    time_vec = Vector{Float64}(undef, n_sub_records)
    trial_vec = ones(Int, n_sub_records)
    msg_vec = fill("", n_sub_records)
    NaN32 = Float32(NaN)
    gxL = fill(NaN32, n_sub_records)
    gyL = fill(NaN32, n_sub_records)
    paL = fill(NaN32, n_sub_records)
    gxR = fill(NaN32, n_sub_records)
    gyR = fill(NaN32, n_sub_records)
    paR = fill(NaN32, n_sub_records)
    pupxL = fill(NaN32, n_sub_records)
    pupyL = fill(NaN32, n_sub_records)
    pupxR = fill(NaN32, n_sub_records)
    pupyR = fill(NaN32, n_sub_records)
    diaxL = fill(NaN32, n_sub_records)
    diayL = fill(NaN32, n_sub_records)
    diaxR = fill(NaN32, n_sub_records)
    diayR = fill(NaN32, n_sub_records)
    crxL = fill(NaN32, n_sub_records)
    cryL = fill(NaN32, n_sub_records)
    crxR = fill(NaN32, n_sub_records)
    cryR = fill(NaN32, n_sub_records)

    row = 0
    last_raw_ts = UInt32(0)
    time_high_bits = Int64(0)
    trig_cache = Dict{Int,String}()

    @inbounds for s = 0:(n_sub_records-1)
        sub_off = data_start + s * sub_record_size
        sub_off + sub_record_size - 1 > n_bytes && break

        raw_ts = _smi_le_u32(data, sub_off + 4)

        # Alternating sub-records: even indices → left eye, odd → right (if binocular).
        # In binocular recordings, paired L/R sub-records share the exact same timestamp,
        # so merge the right-eye sub-record into the current sample row.
        to_left = (s % 2 == 0) || !has_right_cols
        merge_into_prev = !to_left && row >= 1 && raw_ts == last_raw_ts
        if !merge_into_prev
            row += 1
            if row > 1 && raw_ts < last_raw_ts
                time_high_bits += 0x100000000
            end
            last_raw_ts = raw_ts
            time_vec[row] = Float64(time_high_bits | Int64(raw_ts)) / 256_000.0
        end

        gx = _smi_le_f64(data, sub_off + 72)
        gy = _smi_le_f64(data, sub_off + 80)
        px = _smi_le_f64(data, sub_off + 24)
        py = _smi_le_f64(data, sub_off + 32)
        pupdx = _smi_le_f64(data, sub_off + 40)
        pupdy = _smi_le_f64(data, sub_off + 48)
        cx = _smi_le_f64(data, sub_off + 56)
        cy = _smi_le_f64(data, sub_off + 64)
        pa = (pupdx + pupdy) / 2.0

        b102 = data[sub_off+102]
        b103 = data[sub_off+103]
        trig_val =
            Int(b103 >> 4) * 1000 +
            Int(b103 & 0x0F) * 100 +
            Int(b102 >> 4) * 10 +
            Int(b102 & 0x0F)
        if trig_val > 0 && isempty(msg_vec[row])
            cached_t = get(trig_cache, trig_val, nothing)
            if isnothing(cached_t)
                cached_t = string(trig_val)
                trig_cache[trig_val] = cached_t
            end
            msg_vec[row] = cached_t
        end

        gaze_missing = (gx == 0.0 && gy == 0.0)
        pupil_missing = (pa == 0.0)

        if to_left
            gxL[row] = gaze_missing ? NaN32 : Float32(gx)
            gyL[row] = gaze_missing ? NaN32 : Float32(gy)
            paL[row] = pupil_missing ? NaN32 : Float32(pa)
            pupxL[row] = (pupil_missing || px == 0.0) ? NaN32 : Float32(px)
            pupyL[row] = (pupil_missing || py == 0.0) ? NaN32 : Float32(py)
            diaxL[row] = pupil_missing ? NaN32 : Float32(pupdx)
            diayL[row] = pupil_missing ? NaN32 : Float32(pupdy)
            crxL[row] = cx == 0.0 ? NaN32 : Float32(cx)
            cryL[row] = cy == 0.0 ? NaN32 : Float32(cy)
        else
            gxR[row] = gaze_missing ? NaN32 : Float32(gx)
            gyR[row] = gaze_missing ? NaN32 : Float32(gy)
            paR[row] = pupil_missing ? NaN32 : Float32(pa)
            pupxR[row] = (pupil_missing || px == 0.0) ? NaN32 : Float32(px)
            pupyR[row] = (pupil_missing || py == 0.0) ? NaN32 : Float32(py)
            diaxR[row] = pupil_missing ? NaN32 : Float32(pupdx)
            diayR[row] = pupil_missing ? NaN32 : Float32(pupdy)
            crxR[row] = cx == 0.0 ? NaN32 : Float32(cx)
            cryR[row] = cy == 0.0 ? NaN32 : Float32(cy)
        end
    end

    resize!(time_vec, row)
    resize!(trial_vec, row)
    resize!(msg_vec, row)
    resize!(gxL, row)
    resize!(gyL, row)
    resize!(paL, row)
    resize!(gxR, row)
    resize!(gyR, row)
    resize!(paR, row)
    resize!(pupxL, row)
    resize!(pupyL, row)
    resize!(pupxR, row)
    resize!(pupyR, row)
    resize!(diaxL, row)
    resize!(diayL, row)
    resize!(diaxR, row)
    resize!(diayR, row)
    resize!(crxL, row)
    resize!(cryL, row)
    resize!(crxR, row)
    resize!(cryR, row)

    if header_sample_rate == 0.0 && row > 1
        n_check = min(row, 2000)
        valid_diffs = Float64[]
        sizehint!(valid_diffs, n_check)
        @inbounds for i = 2:n_check
            dt = time_vec[i] - time_vec[i-1]
            dt > 0.0 && push!(valid_diffs, dt)
        end
        if !isempty(valid_diffs)
            sample_rate = round(1000.0 / median!(valid_diffs))
        else
            sample_rate = 50.0
            @warn "Could not detect IDF sample rate from timestamps, defaulting to 50 Hz"
        end
    elseif header_sample_rate > 0.0
        sample_rate = header_sample_rate
    else
        sample_rate = 50.0
    end

    evt_times = Float64[]
    evt_msgs = String[]
    @inbounds for i = 1:row
        m = msg_vec[i]
        if !isempty(m)
            push!(evt_times, time_vec[i])
            push!(evt_msgs, m)
        end
    end

    idf_subject = splitext(basename(path))[1]
    df = DataFrame(
        time = time_vec,
        trial = trial_vec,
        participant = fill(idf_subject, row),
        gxL = gxL,
        gyL = gyL,
        paL = paL,
        gxR = gxR,
        gyR = gyR,
        paR = paR,
        pupxL = pupxL,
        pupyL = pupyL,
        pupxR = pupxR,
        pupyR = pupyR,
        diaxL = diaxL,
        diayL = diayL,
        diaxR = diaxR,
        diayR = diayR,
        crxL = crxL,
        cryL = cryL,
        crxR = crxR,
        cryR = cryR,
        message = msg_vec;
        copycols = false,
    )

    if verbose
        @info "SMI IDF: $row samples ($n_sub_records sub-records) at $sample_rate Hz"
        @info "SMI IDF Events: $(length(evt_times)) hardware triggers parsed."
    end

    smi = SMIFile(path)
    smi.subject = idf_subject
    smi.samples = df
    smi.events = DataFrame(
        time = evt_times,
        type = fill("MSG", length(evt_times)),
        message = evt_msgs;
        copycols = false,
    )
    smi.sample_rate = sample_rate
    smi.screen_res = screen_res
    smi.screen_width_cm = Float64(screen_width_cm)
    smi.viewing_distance_cm = Float64(viewing_distance_cm)
    return smi
end

function _read_smi_events_txt(path::String)::DataFrame
    raw = Base.read(path)
    n_bytes = length(raw)
    ev_type = String[]
    ev_st = Float64[]
    ev_en = Float64[]
    ev_dur = Float64[]
    ev_gavx = Float64[]
    ev_gavy = Float64[]
    ev_gstx = Float64[]
    ev_gsty = Float64[]
    ev_genx = Float64[]
    ev_geny = Float64[]
    ev_ampl = Float64[]
    ev_pvel = Float64[]
    ev_msg = String[]

    col_a = Vector{Int}(undef, 32)
    col_b = Vector{Int}(undef, 32)
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
        sa, sb = _tsv_trim_span(raw, ls, le)
        sa > sb && continue
        @inbounds b1 = raw[sa]
        (b1 == UInt8('#') || b1 == UInt8('T') || b1 == UInt8('E')) && continue

        n_cols = _tsv_split_spans!(col_a, col_b, raw, ls, le)
        n_cols < 5 && continue
        ka, kb = _tsv_trim_span(raw, col_a[1], col_b[1])

        if _span_starts_with_ascii(raw, ka, kb, "Fixation") && n_cols >= 7
            st = _bytes_parse_f64(raw, col_a[4], col_b[4]) / 1000.0
            en = _bytes_parse_f64(raw, col_a[5], col_b[5]) / 1000.0
            dur = _bytes_parse_f64(raw, col_a[6], col_b[6]) / 1000.0
            gx = _bytes_parse_f64(raw, col_a[7], col_b[7])
            gy = n_cols >= 8 ? _bytes_parse_f64(raw, col_a[8], col_b[8]) : NaN
            push!(ev_type, "FIXATION")
            push!(ev_st, st)
            push!(ev_en, en)
            push!(ev_dur, dur)
            push!(ev_gavx, gx)
            push!(ev_gavy, gy)
            push!(ev_gstx, NaN)
            push!(ev_gsty, NaN)
            push!(ev_genx, NaN)
            push!(ev_geny, NaN)
            push!(ev_ampl, NaN)
            push!(ev_pvel, NaN)
            push!(ev_msg, "")
        elseif _span_starts_with_ascii(raw, ka, kb, "Saccade") && n_cols >= 10
            st = _bytes_parse_f64(raw, col_a[4], col_b[4]) / 1000.0
            en = _bytes_parse_f64(raw, col_a[5], col_b[5]) / 1000.0
            dur = _bytes_parse_f64(raw, col_a[6], col_b[6]) / 1000.0
            sx = _bytes_parse_f64(raw, col_a[7], col_b[7])
            sy = _bytes_parse_f64(raw, col_a[8], col_b[8])
            ex = _bytes_parse_f64(raw, col_a[9], col_b[9])
            ey = _bytes_parse_f64(raw, col_a[10], col_b[10])
            amp = n_cols >= 11 ? _bytes_parse_f64(raw, col_a[11], col_b[11]) : NaN
            pv = n_cols >= 12 ? _bytes_parse_f64(raw, col_a[12], col_b[12]) : NaN
            push!(ev_type, "SACCADE")
            push!(ev_st, st)
            push!(ev_en, en)
            push!(ev_dur, dur)
            push!(ev_gavx, NaN)
            push!(ev_gavy, NaN)
            push!(ev_gstx, sx)
            push!(ev_gsty, sy)
            push!(ev_genx, ex)
            push!(ev_geny, ey)
            push!(ev_ampl, amp)
            push!(ev_pvel, pv)
            push!(ev_msg, "")
        elseif _span_starts_with_ascii(raw, ka, kb, "Blink") && n_cols >= 6
            st = _bytes_parse_f64(raw, col_a[4], col_b[4]) / 1000.0
            en = _bytes_parse_f64(raw, col_a[5], col_b[5]) / 1000.0
            dur = _bytes_parse_f64(raw, col_a[6], col_b[6]) / 1000.0
            push!(ev_type, "BLINK")
            push!(ev_st, st)
            push!(ev_en, en)
            push!(ev_dur, dur)
            push!(ev_gavx, NaN)
            push!(ev_gavy, NaN)
            push!(ev_gstx, NaN)
            push!(ev_gsty, NaN)
            push!(ev_genx, NaN)
            push!(ev_geny, NaN)
            push!(ev_ampl, NaN)
            push!(ev_pvel, NaN)
            push!(ev_msg, "")
        end
    end

    return DataFrame(
        time = ev_st,
        entime = ev_en,
        duration = ev_dur,
        type = ev_type,
        gavx = ev_gavx,
        gavy = ev_gavy,
        gstx = ev_gstx,
        gsty = ev_gsty,
        genx = ev_genx,
        geny = ev_geny,
        ampl = ev_ampl,
        pvel = ev_pvel,
        message = ev_msg;
        copycols = false,
    )
end

function _stamp_smi_events!(df::DataFrame, evs::DataFrame)
    n = nrow(df)
    times = df[!, :time]
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

    ev_t = evs[!, :type]
    ev_st = evs[!, :time]
    ev_en = evs[!, :entime]
    ev_dur = evs[!, :duration]
    @inbounds for k = 1:nrow(evs)
        tp = ev_t[k]
        (ismissing(ev_en[k]) || isnan(ev_en[k])) && continue
        st = Float64(ev_st[k])
        en = Float64(ev_en[k])
        lo = searchsortedfirst(times, st)
        hi = searchsortedlast(times, en)
        lo > hi && continue
        d_ms = round(Int32, ismissing(ev_dur[k]) || isnan(ev_dur[k]) ? max(0.0, en - st) : Float64(ev_dur[k]))
        if tp == "FIXATION"
            gx = Float64(evs.gavx[k])
            gy = Float64(evs.gavy[k])
            for j = lo:hi
                in_fix[j] = true
                fix_gavx[j] = gx
                fix_gavy[j] = gy
                fix_dur[j] = d_ms
            end
        elseif tp == "SACCADE"
            sx, sy = Float64(evs.gstx[k]), Float64(evs.gsty[k])
            ex, ey = Float64(evs.genx[k]), Float64(evs.geny[k])
            amp = Float64(evs.ampl[k])
            pv = Float64(evs.pvel[k])
            for j = lo:hi
                in_sacc[j] = true
                sacc_gstx[j] = sx
                sacc_gsty[j] = sy
                sacc_genx[j] = ex
                sacc_geny[j] = ey
                sacc_dur[j] = d_ms
                sacc_ampl[j] = amp
                sacc_pvel[j] = pv
            end
        elseif tp == "BLINK"
            for j = lo:hi
                in_blink[j] = true
                blink_dur[j] = d_ms
            end
        end
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
