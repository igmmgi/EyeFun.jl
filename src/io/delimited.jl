function _find_bids_sidecar(path::AbstractString)::Union{Nothing,String}
    base = String(path)
    if endswith(lowercase(base), ".gz")
        base = String(chop(base; tail = 3))
    end
    stem, _ = splitext(base)
    cand1 = stem * ".json"
    isfile(cand1) && return cand1
    if endswith(stem, "_samples")
        cand2 = String(chop(stem; tail = 8)) * "_eyetrack.json"
        isfile(cand2) && return cand2
    end
    return nothing
end

function _json_extract_number(txt::AbstractString, key::AbstractString)::Union{Nothing,Float64}
    m = match(Regex("\"" * key * "\"\\s*:\\s*([-+]?[0-9]*\\.?[0-9]+(?:[eE][-+]?[0-9]+)?)"), txt)
    isnothing(m) && return nothing
    return tryparse(Float64, m.captures[1])
end

function _json_extract_string(txt::AbstractString, key::AbstractString)::Union{Nothing,String}
    m = match(Regex("\"" * key * "\"\\s*:\\s*\"([^\"]*)\""), txt)
    isnothing(m) && return nothing
    return String(m.captures[1])
end

function _json_extract_num_array(txt::AbstractString, key::AbstractString)::Vector{Float64}
    m = match(Regex("\"" * key * "\"\\s*:\\s*\\[([^\\]]*)\\]"), txt)
    isnothing(m) && return Float64[]
    out = Float64[]
    for part in split(m.captures[1], ',')
        v = tryparse(Float64, strip(part))
        !isnothing(v) && push!(out, v)
    end
    return out
end

function _json_extract_str_array(txt::AbstractString, key::AbstractString)::Vector{String}
    m = match(Regex("\"" * key * "\"\\s*:\\s*\\[([^\\]]*)\\]"), txt)
    isnothing(m) && return String[]
    out = String[]
    for sm in eachmatch(r"\"([^\"]*)\"", m.captures[1])
        push!(out, String(sm.captures[1]))
    end
    return out
end

function _parse_bids_sidecar(json_path::AbstractString)
    txt = read(json_path, String)
    sr = _json_extract_number(txt, "SamplingFrequency")
    start_time = _json_extract_number(txt, "StartTime")
    res_arr = _json_extract_num_array(txt, "ScreenResolution")
    res = length(res_arr) >= 2 ? (round(Int, res_arr[1]), round(Int, res_arr[2])) : nothing

    sw = _json_extract_number(txt, "ScreenWidthCm")
    if isnothing(sw)
        sz_arr = _json_extract_num_array(txt, "ScreenSize")
        if !isempty(sz_arr)
            # BIDS ScreenSize is in meters [width_m, height_m]
            sw = sz_arr[1] < 5.0 ? sz_arr[1] * 100.0 : sz_arr[1]
        end
    end

    vd = _json_extract_number(txt, "ViewingDistanceCm")
    if isnothing(vd)
        vd_raw = _json_extract_number(txt, "ViewingDistance")
        if !isnothing(vd_raw)
            vd = vd_raw < 5.0 ? vd_raw * 100.0 : vd_raw
        end
    end

    coord_str = _json_extract_string(txt, "CoordinateSystem")
    coords = if isnothing(coord_str)
        nothing
    else
        cs_lo = lowercase(coord_str)
        if cs_lo in ("deg", "degrees")
            :deg
        elseif cs_lo in ("center", "center_px")
            :center_px
        else
            :px
        end
    end

    src_str = _json_extract_string(txt, "Source")
    src = (!isnothing(src_str) && !isempty(src_str)) ? Symbol(src_str) : nothing

    cols = _json_extract_str_array(txt, "Columns")
    return (
        sample_rate = sr,
        start_time = start_time,
        screen_res = res,
        screen_width_cm = sw,
        viewing_distance_cm = vd,
        coords = coords,
        source = src,
        columns = cols,
    )
end

@inline function _delim_split_spans!(
    col_a::Vector{Int},
    col_b::Vector{Int},
    data::Vector{UInt8},
    ls::Int,
    le::Int,
    delim::UInt8,
)::Int
    cap = length(col_a)
    col = 0
    start = ls
    in_quotes = false
    @inbounds for i = ls:le
        b = data[i]
        if b == UInt8('"')
            in_quotes = !in_quotes
        elseif b == delim && !in_quotes
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

@inline function _delim_unquote_trim(data::Vector{UInt8}, a::Int, b::Int)::Tuple{Int,Int,Bool}
    a, b = _tsv_trim_span(data, a, b)
    has_escaped = false
    if b >= a + 1 && @inbounds(data[a]) == UInt8('"') && @inbounds(data[b]) == UInt8('"')
        a += 1
        b -= 1
        @inbounds for k = a:(b-1)
            if data[k] == UInt8('"') && data[k+1] == UInt8('"')
                has_escaped = true
                break
            end
        end
    end
    return (a, b, has_escaped)
end

@inline function _delim_span_string(data::Vector{UInt8}, a::Int, b::Int)::String
    a, b, has_esc = _delim_unquote_trim(data, a, b)
    a > b && return ""
    s = _span_to_string(data, a, b)
    return has_esc ? replace(s, "\"\"" => "\"") : s
end

const _DELIM_COL_ALIASES = Dict{String,Symbol}(
    "time" => :time,
    "timestamp" => :time,
    "time_ms" => :time,
    "time_s" => :time,
    "time_us" => :time,
    "t" => :time,
    "time_rel" => :time_rel,
    "trial" => :trial,
    "trial_id" => :trial,
    "trial_number" => :trial,
    "participant" => :participant,
    "subject" => :participant,
    "subject_id" => :participant,
    "message" => :message,
    "msg" => :message,
    "gx" => :gx,
    "x" => :gx,
    "gaze_x" => :gx,
    "x_coordinate" => :gx,
    "gy" => :gy,
    "y" => :gy,
    "gaze_y" => :gy,
    "y_coordinate" => :gy,
    "pa" => :pa,
    "pupil" => :pa,
    "pupil_size" => :pa,
    "gxl" => :gxL,
    "left_x" => :gxL,
    "eye1_x_coordinate" => :gxL,
    "gyl" => :gyL,
    "left_y" => :gyL,
    "eye1_y_coordinate" => :gyL,
    "pal" => :paL,
    "left_pupil" => :paL,
    "eye1_pupil_size" => :paL,
    "gxr" => :gxR,
    "right_x" => :gxR,
    "eye2_x_coordinate" => :gxR,
    "gyr" => :gyR,
    "right_y" => :gyR,
    "eye2_y_coordinate" => :gyR,
    "par" => :paR,
    "right_pupil" => :paR,
    "eye2_pupil_size" => :paR,
)

@inline function _is_bool_event_col(sym::Symbol)::Bool
    s = String(sym)
    return sym in (:in_fix, :in_sacc, :in_blink, :in_pso, :in_msacc) ||
           endswith(s, "_in_fix") ||
           endswith(s, "_in_sacc") ||
           endswith(s, "_in_blink") ||
           endswith(s, "_in_pso") ||
           endswith(s, "_in_msacc")
end

@inline function _is_i32_dur_col(sym::Symbol)::Bool
    s = String(sym)
    return sym in (:fix_dur, :sacc_dur, :blink_dur, :pso_dur, :msacc_dur) ||
           endswith(s, "_fix_dur") ||
           endswith(s, "_sacc_dur") ||
           endswith(s, "_blink_dur") ||
           endswith(s, "_pso_dur") ||
           endswith(s, "_msacc_dur")
end

@inline function _is_f32_gaze_col(sym::Symbol)::Bool
    return sym in (:gx, :gy, :pa, :gxL, :gyL, :paL, :gxR, :gyR, :paR)
end

@inline function _is_f64_known_col(sym::Symbol)::Bool
    s = String(sym)
    return sym in (
        :time,
        :time_rel,
        :vel,
        :fix_gavx,
        :fix_gavy,
        :fix_ava,
        :sacc_gstx,
        :sacc_gsty,
        :sacc_genx,
        :sacc_geny,
        :sacc_ampl,
        :sacc_pvel,
        :msacc_dx,
        :msacc_dy,
        :msacc_ampl,
        :msacc_pvel,
    ) ||
           endswith(s, "_fix_gavx") ||
           endswith(s, "_fix_gavy") ||
           endswith(s, "_fix_ava") ||
           endswith(s, "_sacc_gstx") ||
           endswith(s, "_sacc_gsty") ||
           endswith(s, "_sacc_genx") ||
           endswith(s, "_sacc_geny") ||
           endswith(s, "_sacc_ampl") ||
           endswith(s, "_sacc_pvel") ||
           endswith(s, "_msacc_dx") ||
           endswith(s, "_msacc_dy") ||
           endswith(s, "_msacc_ampl") ||
           endswith(s, "_msacc_pvel")
end

@inline function _bytes_parse_bool(data::Vector{UInt8}, a::Int, b::Int)::Bool
    a, b, _ = _delim_unquote_trim(data, a, b)
    len = b - a + 1
    len <= 0 && return false
    c1 = @inbounds data[a]
    if len == 1
        return c1 == UInt8('1') || (c1 | 0x20) == UInt8('t')
    elseif len == 4
        return (@inbounds(data[a]) | 0x20) == UInt8('t') &&
               (@inbounds(data[a+1]) | 0x20) == UInt8('r') &&
               (@inbounds(data[a+2]) | 0x20) == UInt8('u') &&
               (@inbounds(data[a+3]) | 0x20) == UInt8('e')
    end
    return false
end

@inline function _looks_like_data_token(data::Vector{UInt8}, a::Int, b::Int)::Bool
    a, b, _ = _delim_unquote_trim(data, a, b)
    a > b && return true
    v = _bytes_parse_f64(data, a, b)
    !isnan(v) && return true
    return _span_eq_ascii(data, a, b, "NaN") ||
           _span_eq_ascii(data, a, b, "nan") ||
           _span_eq_ascii(data, a, b, "n/a") ||
           _span_eq_ascii(data, a, b, "NA")
end

"""
    read_et_delimited(path::AbstractString; delim=nothing, has_header=nothing,
                      col_map=nothing, time_unit=:auto, sample_rate=nothing,
                      screen_res=nothing, screen_width_cm=nothing,
                      viewing_distance_cm=nothing, coords=nothing,
                      trial_time_zero=nothing, source=:delimited, verbose=false) -> EyeData

Read a generic CSV, TSV, or BIDS `*_eyetrack.tsv` eye-tracking file into an `EyeData`
container.

Automatically discovers companion BIDS `*_eyetrack.json` (or `<stem>.json`) metadata
sidecars when present to populate `sample_rate`, `screen_res`, physical geometry, and
headerless BIDS `Columns` definitions.

# Keyword Arguments
- `delim::Union{Nothing,Char}=nothing`: field delimiter (`'\\t'` or `','`; auto-detected when `nothing`)
- `has_header::Union{Nothing,Bool}=nothing`: whether line 1 is a column header (auto-detected when `nothing`)
- `col_map::Union{Nothing,AbstractDict}=nothing`: custom `Dict("raw_col" => :gx, ...)` mapping overrides
- `time_unit::Symbol=:auto`: timestamp unit (`:auto`, `:ms`, `:s`, or `:us`)
- `sample_rate::Union{Nothing,Real}=nothing`: override recording sample rate in Hz
- `screen_res::Union{Nothing,Tuple{Int,Int}}=nothing`: screen `(width, height)` in px (default `(1920, 1080)`)
- `screen_width_cm::Union{Nothing,Real}=nothing`: physical screen width in cm (default `53.0`)
- `viewing_distance_cm::Union{Nothing,Real}=nothing`: viewing distance in cm (default `60.0`)
- `coords::Union{Nothing,Symbol}=nothing`: `:topleft` or `:center`
- `trial_time_zero::Union{Nothing,AbstractString}=nothing`: optional message anchor for `:time_rel`
- `source::Symbol=:delimited`: `EyeData.source` tag (unless overridden by sidecar)
- `verbose::Bool=false`: print loading diagnostics
"""
function read_et_delimited(
    path::AbstractString;
    delim::Union{Nothing,Char} = nothing,
    has_header::Union{Nothing,Bool} = nothing,
    col_map::Union{Nothing,AbstractDict} = nothing,
    time_unit::Symbol = :auto,
    sample_rate::Union{Nothing,Real} = nothing,
    screen_res::Union{Nothing,Tuple{Int,Int}} = nothing,
    screen_width_cm::Union{Nothing,Real} = nothing,
    viewing_distance_cm::Union{Nothing,Real} = nothing,
    coords::Union{Nothing,Symbol} = nothing,
    trial_time_zero::Union{Nothing,AbstractString} = nothing,
    source::Symbol = :delimited,
    verbose::Bool = false,
)
    isfile(path) || error("File not found: $path")
    endswith(lowercase(path), ".gz") && throw(
        ArgumentError(
            "Gzip-compressed files (.gz) are not directly supported; decompress the file first.",
        ),
    )
    time_unit in (:auto, :ms, :s, :us) ||
        throw(ArgumentError("Invalid time_unit=:$time_unit. Expected :auto, :ms, :s, or :us."))

    sidecar_path = _find_bids_sidecar(path)
    meta = isnothing(sidecar_path) ? nothing : _parse_bids_sidecar(sidecar_path)

    raw = Base.read(path)
    total_len = length(raw)
    if total_len >= 2 && @inbounds(raw[1]) == 0x1f && @inbounds(raw[2]) == 0x8b
        throw(
            ArgumentError(
                "Gzip-compressed files (.gz) are not directly supported; decompress the file first.",
            ),
        )
    end
    pos = 1
    if total_len >= 3 && @inbounds(raw[1]) == 0xEF && @inbounds(raw[2]) == 0xBB && @inbounds(raw[3]) == 0xBF
        pos = 4
    end

    # Locate first non-empty, non-comment line
    first_ls = 0
    first_le = -1
    next_after_first = pos
    scan_pos = pos
    @inbounds while scan_pos <= total_len
        nl = scan_pos
        while nl <= total_len && raw[nl] != UInt8('\n')
            nl += 1
        end
        ls = scan_pos
        le = nl - 1
        scan_pos = nl + 1
        if le >= ls && raw[le] == UInt8('\r')
            le -= 1
        end
        ta, tb = _tsv_trim_span(raw, ls, le)
        ta > tb && continue
        raw[ta] == UInt8('#') && continue
        first_ls = ls
        first_le = le
        next_after_first = scan_pos
        break
    end
    first_ls == 0 && error("No data rows found in delimited file: $path")

    # Auto-detect delimiter
    delim_byte = if !isnothing(delim)
        UInt8(delim)
    else
        ext = lowercase(splitext(path)[2])
        has_tab = false
        @inbounds for k = first_ls:first_le
            if raw[k] == UInt8('\t')
                has_tab = true
                break
            end
        end
        (ext == ".tsv" || has_tab) ? UInt8('\t') : UInt8(',')
    end

    n_seps = 0
    @inbounds for k = first_ls:first_le
        raw[k] == delim_byte && (n_seps += 1)
    end
    cap = max(n_seps + 8, !isnothing(meta) ? length(meta.columns) + 4 : 16)
    col_a = Vector{Int}(undef, cap)
    col_b = Vector{Int}(undef, cap)
    n_first = _delim_split_spans!(col_a, col_b, raw, first_ls, first_le, delim_byte)

    # Determine header vs headerless (e.g. BIDS *_eyetrack.tsv)
    header_present = if !isnothing(has_header)
        has_header
    elseif !isnothing(meta) && !isempty(meta.columns) && _looks_like_data_token(raw, col_a[1], col_b[1])
        false
    else
        !_looks_like_data_token(raw, col_a[1], col_b[1])
    end

    raw_col_names = String[]
    if header_present
        for i = 1:n_first
            nm = _delim_span_string(raw, col_a[i], col_b[i])
            push!(raw_col_names, isempty(nm) ? "col_$i" : nm)
        end
        pos = next_after_first
    elseif !isnothing(meta) && !isempty(meta.columns)
        append!(raw_col_names, meta.columns)
        pos = first_ls
    else
        for i = 1:n_first
            push!(raw_col_names, i == 1 ? "time" : i == 2 ? "gx" : i == 3 ? "gy" : i == 4 ? "pa" : "col_$i")
        end
        pos = first_ls
    end

    n_schema = length(raw_col_names)
    if length(col_a) < n_schema + 4
        resize!(col_a, n_schema + 4)
        resize!(col_b, n_schema + 4)
    end

    user_map = Dict{String,Symbol}()
    if !isnothing(col_map)
        for (k, v) in col_map
            user_map[String(k)] = Symbol(v)
        end
    end

    target_syms = Vector{Symbol}(undef, n_schema)
    seen_syms = Set{Symbol}()
    raw_time_header = ""
    for i = 1:n_schema
        rn = raw_col_names[i]
        sym = if haskey(user_map, rn)
            user_map[rn]
        elseif haskey(_DELIM_COL_ALIASES, lowercase(rn))
            cand = _DELIM_COL_ALIASES[lowercase(rn)]
            cand in seen_syms ? Symbol(rn) : cand
        else
            Symbol(rn)
        end
        if sym === :time && isempty(raw_time_header)
            raw_time_header = lowercase(rn)
        end
        target_syms[i] = sym
        push!(seen_syms, sym)
    end

    # Column storage kinds:
    # 1 = Float64, 2 = Float32, 3 = Int, 4 = Int32, 5 = BitVector, 6 = String, 7 = Auto (infer)
    col_kinds = Vector{Int}(undef, n_schema)
    col_vecs = Vector{Any}(undef, n_schema)
    est_rows = clamp(div(total_len, max(16, n_schema * 6)), 32, 3_000_000)

    for i = 1:n_schema
        sym = target_syms[i]
        if _is_f32_gaze_col(sym)
            col_kinds[i] = 2
            col_vecs[i] = sizehint!(Float32[], est_rows)
        elseif _is_f64_known_col(sym)
            col_kinds[i] = 1
            col_vecs[i] = sizehint!(Float64[], est_rows)
        elseif sym === :trial
            col_kinds[i] = 3
            col_vecs[i] = sizehint!(Int[], est_rows)
        elseif _is_i32_dur_col(sym)
            col_kinds[i] = 4
            col_vecs[i] = sizehint!(Int32[], est_rows)
        elseif _is_bool_event_col(sym)
            col_kinds[i] = 5
            col_vecs[i] = sizehint!(BitVector(), est_rows)
        elseif sym in (:participant, :message)
            col_kinds[i] = 6
            col_vecs[i] = sizehint!(String[], est_rows)
        else
            col_kinds[i] = 7
            col_vecs[i] = sizehint!(String[], est_rows)
        end
    end

    time_scale = if time_unit === :s || raw_time_header == "time_s"
        1000.0
    elseif time_unit === :us || raw_time_header == "time_us"
        1e-3
    else
        1.0
    end

    empty_str = ""
    last_part_a = 1
    last_part_b = 0
    last_part_str = empty_str
    trial_missing_rows = Int[]
    trial_col_idx = findfirst(==(:trial), target_syms)

    n_rows = 0
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
        raw[ta] == UInt8('#') && continue

        n_cols = _delim_split_spans!(col_a, col_b, raw, ls, le, delim_byte)
        n_rows += 1

        for i = 1:n_schema
            ca = i <= n_cols ? col_a[i] : 1
            cb = i <= n_cols ? col_b[i] : 0
            kind = col_kinds[i]
            if kind == 1
                ua, ub, _ = _delim_unquote_trim(raw, ca, cb)
                v = ua > ub ? NaN : _bytes_parse_f64(raw, ua, ub)
                target_syms[i] === :time && (v *= time_scale)
                push!(col_vecs[i]::Vector{Float64}, v)
            elseif kind == 2
                ua, ub, _ = _delim_unquote_trim(raw, ca, cb)
                v32 = ua > ub ? NaN32 : Float32(_bytes_parse_f64(raw, ua, ub))
                push!(col_vecs[i]::Vector{Float32}, v32)
            elseif kind == 3
                ua, ub, _ = _delim_unquote_trim(raw, ca, cb)
                if ua > ub
                    push!(trial_missing_rows, n_rows)
                    push!(col_vecs[i]::Vector{Int}, 0)
                else
                    has_dot = false
                    for bi = ua:ub
                        if raw[bi] == UInt8('.')
                            has_dot = true
                            break
                        end
                    end
                    if has_dot
                        vf = _bytes_parse_f64(raw, ua, ub)
                        if isfinite(vf)
                            push!(col_vecs[i]::Vector{Int}, round(Int, vf))
                        else
                            push!(trial_missing_rows, n_rows)
                            push!(col_vecs[i]::Vector{Int}, 0)
                        end
                    else
                        push!(col_vecs[i]::Vector{Int}, _bytes_parse_int(raw, ua, ub))
                    end
                end
            elseif kind == 4
                ua, ub, _ = _delim_unquote_trim(raw, ca, cb)
                vi32 = ua > ub ? Int32(0) : Int32(clamp(_bytes_parse_int(raw, ua, ub), Int(typemin(Int32)), Int(typemax(Int32))))
                push!(col_vecs[i]::Vector{Int32}, vi32)
            elseif kind == 5
                push!(col_vecs[i]::BitVector, _bytes_parse_bool(raw, ca, cb))
            elseif kind == 6
                ua, ub, has_esc = _delim_unquote_trim(raw, ca, cb)
                if ua > ub
                    push!(col_vecs[i]::Vector{String}, empty_str)
                elseif target_syms[i] === :participant && !has_esc
                    if !_spans_equal_bytes(raw, ua, ub, last_part_a, last_part_b)
                        last_part_a = ua
                        last_part_b = ub
                        last_part_str = _span_to_string(raw, ua, ub)
                    end
                    push!(col_vecs[i]::Vector{String}, last_part_str)
                else
                    s = _span_to_string(raw, ua, ub)
                    push!(col_vecs[i]::Vector{String}, has_esc ? replace(s, "\"\"" => "\"") : s)
                end
            else
                push!(col_vecs[i]::Vector{String}, _delim_span_string(raw, ca, cb))
            end
        end
    end

    n_rows > 0 || error("No sample rows parsed from delimited file: $path")

    # Narrow auto-inferred custom columns (Int -> Float64 -> Bool -> String)
    for i = 1:n_schema
        col_kinds[i] == 7 || continue
        sv = col_vecs[i]::Vector{String}
        all_int = true
        all_float = true
        all_bool = true
        any_nonempty = false
        for s in sv
            isempty(s) && continue
            any_nonempty = true
            if all_int && isnothing(tryparse(Int, s))
                all_int = false
            end
            if all_float && isnothing(tryparse(Float64, s))
                all_float = false
            end
            if all_bool && !(lowercase(s) in ("true", "false"))
                all_bool = false
            end
        end
        if any_nonempty && all_bool
            bv = BitVector(undef, n_rows)
            @inbounds for r = 1:n_rows
                bv[r] = lowercase(sv[r]) == "true"
            end
            col_vecs[i] = bv
        elseif any_nonempty && all_int && all(s -> !isempty(s), sv)
            iv = Vector{Int}(undef, n_rows)
            @inbounds for r = 1:n_rows
                iv[r] = parse(Int, sv[r])
            end
            col_vecs[i] = iv
        elseif any_nonempty && all_float
            fv = Vector{Float64}(undef, n_rows)
            @inbounds for r = 1:n_rows
                fv[r] = isempty(sv[r]) ? NaN : parse(Float64, sv[r])
            end
            col_vecs[i] = fv
        end
    end

    if !isnothing(trial_col_idx) && !isempty(trial_missing_rows)
        src_tr = col_vecs[trial_col_idx]::Vector{Int}
        tr_union = Vector{Union{Int,Missing}}(undef, n_rows)
        @inbounds for r = 1:n_rows
            tr_union[r] = src_tr[r]
        end
        @inbounds for r in trial_missing_rows
            tr_union[r] = missing
        end
        col_vecs[trial_col_idx] = tr_union
    end

    df = DataFrame()
    for i = 1:n_schema
        df[!, target_syms[i]] = col_vecs[i]
    end

    sr_meta = !isnothing(meta) ? meta.sample_rate : nothing
    sr_init = !isnothing(sample_rate) ? Float64(sample_rate) : (!isnothing(sr_meta) ? sr_meta : 0.0)

    had_time_col = hasproperty(df, :time)
    if !had_time_col
        sr_synth = sr_init > 0.0 ? sr_init : 1000.0
        t0_ms = (!isnothing(meta) && !isnothing(meta.start_time)) ? meta.start_time * 1000.0 : 0.0
        dt_ms = 1000.0 / sr_synth
        tvec = Vector{Float64}(undef, n_rows)
        @inbounds for r = 1:n_rows
            tvec[r] = t0_ms + (r - 1) * dt_ms
        end
        insertcols!(df, 1, :time => tvec)
    end

    times = df[!, :time]
    if had_time_col && n_rows > 1
        if time_unit === :auto && !(raw_time_header in ("time_ms", "time_s", "time_us"))
            n_check = min(n_rows, 2000)
            diffs = Float64[]
            sizehint!(diffs, n_check)
            @inbounds for r = 2:n_check
                dt = times[r] - times[r-1]
                dt > 0.0 && isfinite(dt) && push!(diffs, dt)
            end
            if !isempty(diffs)
                med_dt = median!(diffs)
                is_seconds =
                    sr_init > 0.0 ? (med_dt <= 1.0 && abs(med_dt * sr_init - 1.0) < 0.25) :
                    (med_dt < 0.1)
                if is_seconds
                    times .*= 1000.0
                end
            end
        end
        if sr_init <= 0.0
            sr_init = _estimate_sample_rate_ms(times; fallback = 0.0)
        end
    end
    sr_final = sr_init > 0.0 ? sr_init : 1000.0

    if !hasproperty(df, :trial)
        df[!, :trial] = fill(1, n_rows)
    end
    if !hasproperty(df, :participant)
        subj = splitext(basename(path))[1]
        df[!, :participant] = fill(subj, n_rows)
    end

    if !isnothing(trial_time_zero) && hasproperty(df, :message)
        _populate_trial_time_zero!(df, trial_time_zero; allow_substring = true)
    end

    res_final = something(screen_res, !isnothing(meta) ? meta.screen_res : nothing, (1920, 1080))
    sw_final = Float64(something(screen_width_cm, !isnothing(meta) ? meta.screen_width_cm : nothing, 53.0))
    vd_final = Float64(something(viewing_distance_cm, !isnothing(meta) ? meta.viewing_distance_cm : nothing, 60.0))
    raw_coords = something(coords, !isnothing(meta) ? meta.coords : nothing, :px)
    coords_final = if raw_coords === :topleft
        :px
    elseif raw_coords === :center
        :center_px
    else
        raw_coords
    end
    src_final = (!isnothing(meta) && !isnothing(meta.source) && source === :delimited) ? meta.source : source

    if coords_final in (:center_px, :deg)
        for c in (:gx, :gy, :gxL, :gyL, :gxR, :gyR, :fix_gavx, :fix_gavy, :sacc_gstx, :sacc_gsty, :sacc_genx, :sacc_geny)
            hasproperty(df, c) && DataFrames.colmetadata!(df, c, "eyefun_coords", coords_final; style = :note)
        end
    end

    verbose && @info "Delimited ET: $n_rows samples, $sr_final Hz from $(basename(path))"
    return EyeData(
        df;
        source = src_final,
        sample_rate = sr_final,
        screen_res = res_final,
        screen_width_cm = sw_final,
        viewing_distance_cm = vd_final,
        coords = coords_final,
    )
end

@inline function _write_delim_cell(io::IO, val, delim_char::Char)
    if ismissing(val)
        return
    elseif val isa AbstractFloat
        isnan(val) ? nothing : print(io, val)
    elseif val isa Bool
        print(io, val ? "true" : "false")
    elseif val isa Integer
        print(io, val)
    else
        s = String(val)
        if occursin(delim_char, s) || occursin('"', s) || occursin('\n', s) || occursin('\r', s)
            write(io, UInt8('"'))
            print(io, replace(s, "\"" => "\"\""))
            write(io, UInt8('"'))
        else
            print(io, s)
        end
    end
end

"""
    write_et_delimited(ed::EyeData, path::AbstractString; delim=nothing, write_bids_json=false) -> String

Export an `EyeData` table to a delimited text file (`.tsv` or `.csv`), optionally writing a
companion BIDS-compatible JSON metadata sidecar (`<stem>.json`) so `read_et_delimited(path)`
preserves sample rate, screen geometry, coordinate system, and columns on re-import.

# Keyword Arguments
- `delim::Union{Nothing,Char}=nothing`: field delimiter (`'\\t'` for `.tsv`, `','` otherwise when `nothing`)
- `write_bids_json::Bool=false`: write a `<stem>.json` sidecar with recording metadata
"""
function write_et_delimited(
    ed::EyeData,
    path::AbstractString;
    delim::Union{Nothing,Char} = nothing,
    write_bids_json::Bool = false,
)
    df = ed.df
    ext = lowercase(splitext(path)[2])
    dchar = !isnothing(delim) ? delim : (ext == ".tsv" ? '\t' : ',')
    dbyte = UInt8(dchar)

    col_names = names(df)
    n_cols = length(col_names)
    n_rows = nrow(df)
    cols = Any[df[!, i] for i = 1:n_cols]

    open(path, "w") do file_io
        buf = IOBuffer(; sizehint = 65536)
        for c = 1:n_cols
            c > 1 && write(buf, dbyte)
            _write_delim_cell(buf, col_names[c], dchar)
        end
        write(buf, UInt8('\n'))

        for r = 1:n_rows
            for c = 1:n_cols
                c > 1 && write(buf, dbyte)
                _write_delim_cell(buf, @inbounds(cols[c][r]), dchar)
            end
            write(buf, UInt8('\n'))
            if position(buf) >= 61440
                write(file_io, take!(buf))
            end
        end
        position(buf) > 0 && write(file_io, take!(buf))
    end

    if write_bids_json
        stem, _ = splitext(String(path))
        json_path = stem * ".json"
        w, h = ed.screen_res
        cols_json = join(["\"" * replace(nm, "\"" => "\\\"") * "\"" for nm in col_names], ", ")
        open(json_path, "w") do jio
            println(jio, "{")
            println(jio, "  \"SamplingFrequency\": $(ed.sample_rate),")
            println(jio, "  \"ScreenResolution\": [$w, $h],")
            println(jio, "  \"ScreenWidthCm\": $(ed.screen_width_cm),")
            println(jio, "  \"ViewingDistanceCm\": $(ed.viewing_distance_cm),")
            println(jio, "  \"CoordinateSystem\": \"$(ed.coords)\",")
            println(jio, "  \"Source\": \"$(ed.source)\",")
            println(jio, "  \"Columns\": [$cols_json]")
            println(jio, "}")
        end
    end

    return String(path)
end

