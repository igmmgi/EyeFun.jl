
# ── Internal helpers ──────────────────────────────────────────────────────── #

# Convert a field string to Float32; returns NaN for missing tokens
# Handles: "." (EDF missing), "..." ".....": all-dots or uppercase flag chars
@inline function _f32(s::AbstractString)
    isempty(s) && return Float32(NaN)
    all(c -> c == '.' || (c >= 'A' && c <= 'Z'), s) && return Float32(NaN)
    v = tryparse(Float32, s)
    isnothing(v) ? Float32(NaN) : v
end

function _eye_code(s::AbstractString)
    s == "R" && return Int16(EYE_RIGHT)
    s == "L" && return Int16(EYE_LEFT)
    return Int16(EYE_BINOCULAR)
end


# ── Hot path: push one sample into column vectors ─────────────────────────── #
# Parses a sample line (tab- or space-delimited) directly into the column vecs.
# Avoids split() allocation: instead walks the string once with a cursor.
@inline function _push_sample!(
    line::String,
    trial::Int,
    in_trial::Bool,
    sam_time,
    sam_gxR,
    sam_gyR,
    sam_paR,
    sam_gxL,
    sam_gyL,
    sam_paL,
    sam_trial,
)

    tokens, ntok = _tokens7(line)
    ntok < 4 && return

    ts = tryparse(UInt32, tokens[1])
    isnothing(ts) && return

    is_binocular = ntok >= 7 && !isnothing(tryparse(Float32, tokens[5]))

    NaN32 = Float32(NaN)
    if is_binocular
        gxL = _f32(tokens[2])
        gyL = _f32(tokens[3])
        paL = _f32(tokens[4])
        gxR = _f32(tokens[5])
        gyR = _f32(tokens[6])
        paR = _f32(tokens[7])
    else
        gxL = NaN32
        gyL = NaN32
        paL = NaN32
        gxR = _f32(tokens[2])
        gyR = _f32(tokens[3])
        paR = _f32(tokens[4])
    end

    push!(sam_time, ts)
    push!(sam_gxR, gxR)
    push!(sam_gyR, gyR)
    push!(sam_paR, paR)
    push!(sam_gxL, gxL)
    push!(sam_gyL, gyL)
    push!(sam_paL, paL)
    MISS = typemin(Int)
    push!(sam_trial, in_trial ? trial : MISS)
    return
end

# Return up to 7 whitespace-delimited tokens as a fixed NTuple (stack-allocated)
# plus the count of tokens actually found — avoids heap-allocating a Vector per call.
@inline function _tokens7(line::String)
    n = ncodeunits(line)
    i = 1
    EMPTY = SubString(line, 1, 0)
    t1 = t2 = t3 = t4 = t5 = t6 = t7 = EMPTY
    count = 0
    @inbounds while i <= n && count < 7
        while i <= n &&
            (codeunit(line, i) == UInt8(' ') || codeunit(line, i) == UInt8('\t'))
            i += 1
        end
        i > n && break
        j = i
        while j <= n && codeunit(line, j) != UInt8(' ') && codeunit(line, j) != UInt8('\t')
            j += 1
        end
        count += 1
        tok = SubString(line, i, j - 1)
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
        i = j
    end
    return (t1, t2, t3, t4, t5, t6, t7), count
end

function _parse_msg(parts)
    length(parts) < 2 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
    text = length(parts) >= 3 ? strip(parts[3]) : ""
    basic = EDFEventBasic(
        ts,
        Int16(EVENT_MESSAGEEVENT),
        UInt16(0),
        ts,
        ts,
        Int16(-1),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        String(text),
    )
    return EDFEvent(basic, ZERO_POSITIONS, ZERO_VELOCITIES)
end

function _parse_efix(line)
    parts = split(line)
    length(parts) < 8 && return nothing
    eye = _eye_code(parts[2])
    st = tryparse(UInt32, parts[3])
    isnothing(st) && return nothing
    en = tryparse(UInt32, parts[4])
    isnothing(en) && return nothing
    gavx = _f32(parts[6])
    gavy = _f32(parts[7])
    ava = _f32(parts[8])
    basic = EDFEventBasic(
        en,
        Int16(EVENT_ENDFIX),
        UInt16(0),
        st,
        en,
        eye,
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        "",
    )
    NaN32 = Float32(NaN)
    pos = EDFEventPositions(
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        gavx,
        gavy,
        ava,
    )
    return EDFEvent(basic, pos, ZERO_VELOCITIES)
end

function _parse_esacc(line)
    parts = split(line)
    length(parts) < 11 && return nothing
    eye = _eye_code(parts[2])
    st = tryparse(UInt32, parts[3])
    isnothing(st) && return nothing
    en = tryparse(UInt32, parts[4])
    isnothing(en) && return nothing
    gstx = _f32(parts[6])
    gsty = _f32(parts[7])
    genx = _f32(parts[8])
    geny = _f32(parts[9])
    ampl = _f32(parts[10])
    pvel = _f32(parts[11])
    basic = EDFEventBasic(
        en,
        Int16(EVENT_ENDSACC),
        UInt16(0),
        st,
        en,
        eye,
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        "",
    )
    NaN32 = Float32(NaN)
    pos = EDFEventPositions(
        NaN32,
        NaN32,
        gstx,
        gsty,
        NaN32,
        NaN32,
        NaN32,
        genx,
        geny,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
        NaN32,
    )
    vel = EDFEventVelocities(ampl, pvel, NaN32, NaN32, NaN32, NaN32, NaN32, NaN32)
    return EDFEvent(basic, pos, vel)
end

function _parse_eblink(line)
    parts = split(line)
    length(parts) < 5 && return nothing
    eye = _eye_code(parts[2])
    st = tryparse(UInt32, parts[3])
    isnothing(st) && return nothing
    en = tryparse(UInt32, parts[4])
    isnothing(en) && return nothing
    basic = EDFEventBasic(
        en,
        Int16(EVENT_ENDBLINK),
        UInt16(0),
        st,
        en,
        eye,
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        UInt16(0),
        "",
    )
    return EDFEvent(basic, ZERO_POSITIONS, ZERO_VELOCITIES)
end

function _parse_input(line)
    parts = split(line)
    length(parts) < 3 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
    val = tryparse(UInt16, parts[3])
    isnothing(val) && return nothing
    basic = EDFEventBasic(
        ts,
        Int16(EVENT_INPUTEVENT),
        UInt16(0),
        ts,
        ts,
        Int16(-1),
        UInt16(0),
        UInt16(0),
        val,
        UInt16(0),
        UInt16(0),
        "",
    )
    return EDFEvent(basic, ZERO_POSITIONS, ZERO_VELOCITIES)
end

function _parse_start(line, in_trial, trial)
    parts = split(line)
    length(parts) < 2 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
    eye_code = length(parts) >= 3 ? _eye_code(parts[3]) : Int16(EYE_RIGHT)
    eye =
        eye_code == Int16(EYE_RIGHT) ? UInt8(EYE_RIGHT) :
        eye_code == Int16(EYE_BINOCULAR) ? UInt8(EYE_BINOCULAR) : UInt8(EYE_LEFT)
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

function _parse_end(line)
    parts = split(line)
    length(parts) < 2 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
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
