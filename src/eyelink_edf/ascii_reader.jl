# Byte-slice helpers for EyeLink ASCII (.asc) parsing.

const _ASC_POW10 = (1.0f0, 10.0f0, 100.0f0, 1_000.0f0, 10_000.0f0, 100_000.0f0)

@inline function _asc_is_ws(b::UInt8)::Bool
    return b == UInt8(' ') || b == UInt8('\t')
end

@inline function _asc_next_token(data::Vector{UInt8}, i::Int, le::Int)
    @inbounds while i <= le && _asc_is_ws(data[i])
        i += 1
    end
    i > le && return (1, 0, i)
    j = i + 1
    @inbounds while j <= le && !_asc_is_ws(data[j])
        j += 1
    end
    return (i, j - 1, j)
end

@inline function _tok_eq_ascii(data::Vector{UInt8}, a::Int, b::Int, s::String)::Bool
    len = b - a + 1
    len == sizeof(s) || return false
    @inbounds for k = 1:len
        data[a+k-1] == codeunit(s, k) || return false
    end
    return true
end

@inline function _line_starts_with(data::Vector{UInt8}, ls::Int, le::Int, s::String)::Bool
    len = sizeof(s)
    le - ls + 1 >= len || return false
    @inbounds for k = 1:len
        data[ls+k-1] == codeunit(s, k) || return false
    end
    return true
end

@inline function _line_starts_with_kw(
    data::Vector{UInt8},
    ls::Int,
    le::Int,
    s::String,
)::Bool
    len = sizeof(s)
    rem = le - ls + 1
    rem >= len || return false
    @inbounds for k = 1:len
        data[ls+k-1] == codeunit(s, k) || return false
    end
    return rem == len || _asc_is_ws(@inbounds data[ls+len])
end

@inline function _parse_u32_bytes(data::Vector{UInt8}, a::Int, b::Int)::UInt32
    a > b && return typemax(UInt32)
    acc = UInt64(0)
    @inbounds for i = a:b
        c = data[i]
        if c >= UInt8('0') && c <= UInt8('9')
            acc = acc * UInt64(10) + UInt64(c - UInt8('0'))
        else
            return typemax(UInt32)
        end
    end
    return acc <= UInt64(typemax(UInt32)) ? UInt32(acc) : typemax(UInt32)
end

@inline function _parse_u16_bytes(data::Vector{UInt8}, a::Int, b::Int)::Int32
    u = _parse_u32_bytes(data, a, b)
    return u <= UInt32(typemax(UInt16)) ? Int32(u) : Int32(-1)
end

@inline function _parse_f32_bytes(data::Vector{UInt8}, a::Int, b::Int)::Float32
    a > b && return Float32(NaN)
    @inbounds b1 = data[a]
    if b1 == UInt8('.')
        (a == b || @inbounds(data[a+1]) < UInt8('0') || @inbounds(data[a+1]) > UInt8('9')) &&
            return Float32(NaN)
    elseif b1 >= UInt8('A') && b1 <= UInt8('Z')
        return Float32(NaN)
    end
    i = a
    neg = false
    if b1 == UInt8('-')
        neg = true
        i = a + 1
    elseif b1 == UInt8('+')
        i = a + 1
    end
    i > b && return Float32(NaN)
    acc = Int64(0)
    n_frac = 0
    in_frac = false
    n_digits = 0
    @inbounds while i <= b
        c = data[i]
        if c >= UInt8('0') && c <= UInt8('9')
            n_digits += 1
            if n_digits <= 9
                acc = acc * 10 + Int64(c - UInt8('0'))
                in_frac && (n_frac += 1)
            else
                s = GC.@preserve data unsafe_string(pointer(data, a), b - a + 1)
                v = tryparse(Float32, s)
                return (isnothing(v) || !isfinite(v)) ? Float32(NaN) : v
            end
        elseif c == UInt8('.') && !in_frac
            in_frac = true
        else
            s = GC.@preserve data unsafe_string(pointer(data, a), b - a + 1)
            v = tryparse(Float32, s)
            return (isnothing(v) || !isfinite(v)) ? Float32(NaN) : v
        end
        i += 1
    end
    n_digits == 0 && return Float32(NaN)
    val =
        n_frac == 0 ? Float32(acc) :
        (
            n_frac <= 5 ? Float32(acc) / @inbounds(_ASC_POW10[n_frac+1]) :
            Float32(Float64(acc) * 10.0^(-n_frac))
        )
    return neg ? -val : val
end

@inline function _eye_code_bytes(data::Vector{UInt8}, a::Int, b::Int)::Int16
    len = b - a + 1
    if len == 1
        c = @inbounds data[a]
        c == UInt8('R') && return Int16(EYE_RIGHT)
        c == UInt8('L') && return Int16(EYE_LEFT)
    elseif _tok_eq_ascii(data, a, b, "RIGHT")
        return Int16(EYE_RIGHT)
    elseif _tok_eq_ascii(data, a, b, "LEFT")
        return Int16(EYE_LEFT)
    end
    return Int16(EYE_BINOCULAR)
end

@inline function _asc_tokens7_bytes(data::Vector{UInt8}, ls::Int, le::Int)
    EMPTY = (1, 0)
    t1 = t2 = t3 = t4 = t5 = t6 = t7 = EMPTY
    i = ls
    count = 0
    while i <= le && count < 7
        a, b, next_i = _asc_next_token(data, i, le)
        a > b && break
        count += 1
        tok = (a, b)
        if count == 1
            t1 = tok
        elseif count == 2
            t2 = tok
        elseif count == 3
            t3 = tok
        elseif count == 4
            t4 = tok
        elseif count == 5
            t5 = tok
        elseif count == 6
            t6 = tok
        else
            t7 = tok
        end
        i = next_i
    end
    return (t1, t2, t3, t4, t5, t6, t7), count
end

@inline function _asc_tokens11_bytes(data::Vector{UInt8}, ls::Int, le::Int)
    EMPTY = (1, 0)
    t1 = t2 = t3 = t4 = t5 = t6 = t7 = t8 = t9 = t10 = t11 = EMPTY
    i = ls
    count = 0
    while i <= le && count < 11
        a, b, next_i = _asc_next_token(data, i, le)
        a > b && break
        count += 1
        tok = (a, b)
        if count == 1
            t1 = tok
        elseif count == 2
            t2 = tok
        elseif count == 3
            t3 = tok
        elseif count == 4
            t4 = tok
        elseif count == 5
            t5 = tok
        elseif count == 6
            t6 = tok
        elseif count == 7
            t7 = tok
        elseif count == 8
            t8 = tok
        elseif count == 9
            t9 = tok
        elseif count == 10
            t10 = tok
        else
            t11 = tok
        end
        i = next_i
    end
    return (t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11), count
end

mutable struct _ASCSampleCols
    len::Int
    cap::Int
    time::Vector{UInt32}
    gxR::Vector{Float32}
    gyR::Vector{Float32}
    paR::Vector{Float32}
    gxL::Vector{Float32}
    gyL::Vector{Float32}
    paL::Vector{Float32}
    trial::Vector{Union{Int,Missing}}
end

function _ASCSampleCols(cap::Int)
    return _ASCSampleCols(
        0,
        cap,
        Vector{UInt32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Union{Int,Missing}}(missing, cap),
    )
end

@noinline function _grow_asc_samples!(sc::_ASCSampleCols)
    old_cap = sc.cap
    new_cap = max(old_cap * 2, 1024)
    sc.cap = new_cap
    resize!(sc.time, new_cap)
    resize!(sc.gxR, new_cap)
    resize!(sc.gyR, new_cap)
    resize!(sc.paR, new_cap)
    resize!(sc.gxL, new_cap)
    resize!(sc.gyL, new_cap)
    resize!(sc.paL, new_cap)
    resize!(sc.trial, new_cap)
    @inbounds fill!(view(sc.trial, (old_cap+1):new_cap), missing)
    return nothing
end

function _finalize_asc_samples!(sc::_ASCSampleCols)::DataFrame
    n = sc.len
    n == 0 && return DataFrame()
    if n < sc.cap
        resize!(sc.time, n)
        resize!(sc.gxR, n)
        resize!(sc.gyR, n)
        resize!(sc.paR, n)
        resize!(sc.gxL, n)
        resize!(sc.gyL, n)
        resize!(sc.paL, n)
        resize!(sc.trial, n)
    end
    return DataFrame(
        time = sc.time,
        gxR = sc.gxR,
        gyR = sc.gyR,
        paR = sc.paR,
        gxL = sc.gxL,
        gyL = sc.gyL,
        paL = sc.paL,
        trial = sc.trial;
        copycols = false,
    )
end

@inline function _push_asc_sample_bytes!(
    sc::_ASCSampleCols,
    data::Vector{UInt8},
    ls::Int,
    le::Int,
    trial::Int,
    in_trial::Bool,
    asc_eye_mode::UInt8,
)
    toks, ntok = _asc_tokens7_bytes(data, ls, le)
    ntok < 4 && return nothing

    ts = _parse_u32_bytes(data, toks[1][1], toks[1][2])
    ts == typemax(UInt32) && return nothing

    NaN32 = Float32(NaN)
    is_binocular =
        asc_eye_mode == UInt8(EYE_BINOCULAR) || (asc_eye_mode == 0xff && ntok >= 7)

    if is_binocular
        ntok < 7 && return nothing
        gxL = _parse_f32_bytes(data, toks[2][1], toks[2][2])
        gyL = _parse_f32_bytes(data, toks[3][1], toks[3][2])
        paL = _parse_f32_bytes(data, toks[4][1], toks[4][2])
        gxR = _parse_f32_bytes(data, toks[5][1], toks[5][2])
        gyR = _parse_f32_bytes(data, toks[6][1], toks[6][2])
        paR = _parse_f32_bytes(data, toks[7][1], toks[7][2])
    elseif asc_eye_mode == UInt8(EYE_LEFT)
        gxL = _parse_f32_bytes(data, toks[2][1], toks[2][2])
        gyL = _parse_f32_bytes(data, toks[3][1], toks[3][2])
        paL = _parse_f32_bytes(data, toks[4][1], toks[4][2])
        gxR = NaN32
        gyR = NaN32
        paR = NaN32
    else
        gxL = NaN32
        gyL = NaN32
        paL = NaN32
        gxR = _parse_f32_bytes(data, toks[2][1], toks[2][2])
        gyR = _parse_f32_bytes(data, toks[3][1], toks[3][2])
        paR = _parse_f32_bytes(data, toks[4][1], toks[4][2])
    end

    k = sc.len + 1
    if k > sc.cap
        _grow_asc_samples!(sc)
    end
    sc.len = k
    @inbounds begin
        sc.time[k] = ts
        sc.gxR[k] = gxR
        sc.gyR[k] = gyR
        sc.paR[k] = paR
        sc.gxL[k] = gxL
        sc.gyL[k] = gyL
        sc.paL[k] = paL
        in_trial && (sc.trial[k] = trial)
    end
    return nothing
end

@inline function _push_asc_msg_bytes!(
    ev::_EDFEventCols,
    data::Vector{UInt8},
    ls::Int,
    le::Int,
    start_marker::String,
    end_marker::String,
    trial::Int,
    in_trial::Bool,
)
    _, _, i2 = _asc_next_token(data, ls, le)
    a2, b2, i3 = _asc_next_token(data, i2, le)
    a2 > b2 && return trial, in_trial
    ts = _parse_u32_bytes(data, a2, b2)
    ts == typemax(UInt32) && return trial, in_trial

    m_lo = i3
    @inbounds while m_lo <= le && _asc_is_ws(data[m_lo])
        m_lo += 1
    end
    m_hi = le
    @inbounds while m_hi >= m_lo && _asc_is_ws(data[m_hi])
        m_hi -= 1
    end

    _push_msg_event_bytes!(ev, ts, Int16(-1), data, m_lo, m_hi)

    if m_lo <= m_hi
        if _matches_marker_bytes(data, m_lo, m_hi, start_marker)
            trial += 1
            in_trial = true
        elseif _matches_marker_bytes(data, m_lo, m_hi, end_marker)
            in_trial = false
        end
    end
    return trial, in_trial
end

@inline function _push_asc_efix_bytes!(
    ev::_EDFEventCols,
    data::Vector{UInt8},
    ls::Int,
    le::Int,
)
    toks, ntok = _asc_tokens11_bytes(data, ls, le)
    ntok < 8 && return nothing
    eye = _eye_code_bytes(data, toks[2][1], toks[2][2])
    st = _parse_u32_bytes(data, toks[3][1], toks[3][2])
    st == typemax(UInt32) && return nothing
    en = _parse_u32_bytes(data, toks[4][1], toks[4][2])
    en == typemax(UInt32) && return nothing
    gavx = _parse_f32_bytes(data, toks[6][1], toks[6][2])
    gavy = _parse_f32_bytes(data, toks[7][1], toks[7][2])
    ava = _parse_f32_bytes(data, toks[8][1], toks[8][2])

    k = _next_event_slot!(ev)
    NaN32 = Float32(NaN)
    @inbounds begin
        ev.time[k] = en
        ev.type[k] = Int16(EVENT_ENDFIX)
        ev.sttime[k] = st
        ev.entime[k] = en
        ev.eye[k] = eye
        ev.hstx[k] = NaN32
        ev.hsty[k] = NaN32
        ev.gstx[k] = NaN32
        ev.gsty[k] = NaN32
        ev.sta[k] = NaN32
        ev.henx[k] = NaN32
        ev.heny[k] = NaN32
        ev.genx[k] = NaN32
        ev.geny[k] = NaN32
        ev.ena[k] = NaN32
        ev.havx[k] = NaN32
        ev.havy[k] = NaN32
        ev.gavx[k] = gavx
        ev.gavy[k] = gavy
        ev.ava[k] = ava
    end
    return nothing
end

@inline function _push_asc_esacc_bytes!(
    ev::_EDFEventCols,
    data::Vector{UInt8},
    ls::Int,
    le::Int,
)
    toks, ntok = _asc_tokens11_bytes(data, ls, le)
    ntok < 11 && return nothing
    eye = _eye_code_bytes(data, toks[2][1], toks[2][2])
    st = _parse_u32_bytes(data, toks[3][1], toks[3][2])
    st == typemax(UInt32) && return nothing
    en = _parse_u32_bytes(data, toks[4][1], toks[4][2])
    en == typemax(UInt32) && return nothing
    gstx = _parse_f32_bytes(data, toks[6][1], toks[6][2])
    gsty = _parse_f32_bytes(data, toks[7][1], toks[7][2])
    genx = _parse_f32_bytes(data, toks[8][1], toks[8][2])
    geny = _parse_f32_bytes(data, toks[9][1], toks[9][2])
    ampl = _parse_f32_bytes(data, toks[10][1], toks[10][2])
    pvel = _parse_f32_bytes(data, toks[11][1], toks[11][2])

    k = _next_event_slot!(ev)
    NaN32 = Float32(NaN)
    @inbounds begin
        ev.time[k] = en
        ev.type[k] = Int16(EVENT_ENDSACC)
        ev.sttime[k] = st
        ev.entime[k] = en
        ev.eye[k] = eye
        ev.hstx[k] = NaN32
        ev.hsty[k] = NaN32
        ev.gstx[k] = gstx
        ev.gsty[k] = gsty
        ev.sta[k] = NaN32
        ev.henx[k] = NaN32
        ev.heny[k] = NaN32
        ev.genx[k] = genx
        ev.geny[k] = geny
        ev.ena[k] = NaN32
        ev.havx[k] = NaN32
        ev.havy[k] = NaN32
        ev.gavx[k] = NaN32
        ev.gavy[k] = NaN32
        ev.ava[k] = NaN32
        ev.ampl[k] = ampl
        ev.pvel[k] = pvel
        ev.svel[k] = NaN32
        ev.evel[k] = NaN32
        ev.supd_x[k] = NaN32
        ev.eupd_x[k] = NaN32
        ev.supd_y[k] = NaN32
        ev.eupd_y[k] = NaN32
    end
    return nothing
end

@inline function _push_asc_eblink_bytes!(
    ev::_EDFEventCols,
    data::Vector{UInt8},
    ls::Int,
    le::Int,
)
    toks, ntok = _asc_tokens7_bytes(data, ls, le)
    ntok < 5 && return nothing
    eye = _eye_code_bytes(data, toks[2][1], toks[2][2])
    st = _parse_u32_bytes(data, toks[3][1], toks[3][2])
    st == typemax(UInt32) && return nothing
    en = _parse_u32_bytes(data, toks[4][1], toks[4][2])
    en == typemax(UInt32) && return nothing

    k = _next_event_slot!(ev)
    @inbounds begin
        ev.time[k] = en
        ev.type[k] = Int16(EVENT_ENDBLINK)
        ev.sttime[k] = st
        ev.entime[k] = en
        ev.eye[k] = eye
    end
    return nothing
end

@inline function _push_asc_input_bytes!(
    ev::_EDFEventCols,
    data::Vector{UInt8},
    ls::Int,
    le::Int,
)
    toks, ntok = _asc_tokens7_bytes(data, ls, le)
    ntok < 3 && return nothing
    ts = _parse_u32_bytes(data, toks[2][1], toks[2][2])
    ts == typemax(UInt32) && return nothing
    val = _parse_u16_bytes(data, toks[3][1], toks[3][2])
    val < 0 && return nothing
    _push_basic_event!(ev, ts, EVENT_INPUTEVENT, Int16(-1); input_val = UInt16(val))
    return nothing
end

@inline function _push_asc_button_bytes!(
    ev::_EDFEventCols,
    data::Vector{UInt8},
    ls::Int,
    le::Int,
)
    toks, ntok = _asc_tokens7_bytes(data, ls, le)
    ntok < 3 && return nothing
    ts = _parse_u32_bytes(data, toks[2][1], toks[2][2])
    ts == typemax(UInt32) && return nothing
    btn = _parse_u16_bytes(data, toks[3][1], toks[3][2])
    btn < 0 && return nothing
    st = ntok >= 4 ? _parse_u16_bytes(data, toks[4][1], toks[4][2]) : Int32(0)
    # Encode EyeLink button number (low byte) + press state bit if present
    packed = st > 0 ? UInt16((btn & 0x00ff) | ((st & 0x00ff) << 8)) : UInt16(btn & 0xffff)
    _push_basic_event!(ev, ts, EVENT_BUTTONEVENT, Int16(-1); btn_val = packed)
    return nothing
end

function _parse_asc_start_bytes(
    data::Vector{UInt8},
    ls::Int,
    le::Int,
    in_trial::Bool,
    trial::Int,
)
    _, _, i2 = _asc_next_token(data, ls, le)
    a2, b2, i = _asc_next_token(data, i2, le)
    a2 > b2 && return nothing
    ts = _parse_u32_bytes(data, a2, b2)
    ts == typemax(UInt32) && return nothing
    has_left = false
    has_right = false
    while i <= le
        a, b, i = _asc_next_token(data, i, le)
        a > b && break
        if _tok_eq_ascii(data, a, b, "LEFT") || _tok_eq_ascii(data, a, b, "L")
            has_left = true
        elseif _tok_eq_ascii(data, a, b, "RIGHT") || _tok_eq_ascii(data, a, b, "R")
            has_right = true
        end
    end
    eye =
        (has_left && has_right) ? UInt8(EYE_BINOCULAR) :
        has_left ? UInt8(EYE_LEFT) : UInt8(EYE_RIGHT)
    return EDFRecording(
        ts,
        Float32(0),
        UInt16(0),
        UInt16(0),
        UInt8(RECORDING_START),
        UInt8(RECORD_BOTH),
        UInt8(PUPIL_AREA),
        UInt8(MODE_CR),
        UInt8(0),
        UInt8(POS_GAZE),
        eye,
        in_trial ? trial : nothing,
    )
end

function _parse_asc_samples_cfg_bytes(data::Vector{UInt8}, ls::Int, le::Int)
    _, _, i = _asc_next_token(data, ls, le)
    has_left = false
    has_right = false
    sr = 0.0f0
    while i <= le
        a, b, next_i = _asc_next_token(data, i, le)
        a > b && break
        if _tok_eq_ascii(data, a, b, "LEFT") || _tok_eq_ascii(data, a, b, "L")
            has_left = true
        elseif _tok_eq_ascii(data, a, b, "RIGHT") || _tok_eq_ascii(data, a, b, "R")
            has_right = true
        elseif _tok_eq_ascii(data, a, b, "RATE")
            ra, rb, after_r = _asc_next_token(data, next_i, le)
            if ra <= rb
                r = _parse_f32_bytes(data, ra, rb)
                !isnan(r) && (sr = r)
                next_i = after_r
            end
        end
        i = next_i
    end
    eye =
        (has_left && has_right) ? UInt8(EYE_BINOCULAR) :
        has_left ? UInt8(EYE_LEFT) : has_right ? UInt8(EYE_RIGHT) : 0xff
    return eye, sr
end

function _parse_asc_end_bytes(data::Vector{UInt8}, ls::Int, le::Int)
    _, _, i2 = _asc_next_token(data, ls, le)
    a2, b2, _ = _asc_next_token(data, i2, le)
    a2 > b2 && return nothing
    ts = _parse_u32_bytes(data, a2, b2)
    ts == typemax(UInt32) && return nothing
    return EDFRecording(
        ts,
        Float32(0),
        UInt16(0),
        UInt16(0),
        UInt8(RECORDING_END),
        UInt8(RECORD_BOTH),
        UInt8(PUPIL_AREA),
        UInt8(MODE_CR),
        UInt8(0),
        UInt8(POS_GAZE),
        UInt8(EYE_LEFT),
        nothing,
    )
end
