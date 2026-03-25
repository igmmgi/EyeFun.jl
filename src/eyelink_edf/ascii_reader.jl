
# ── Internal helpers ──────────────────────────────────────────────────────── #

# Convert a field string to Float32; returns NaN for missing tokens
# Handles: "." (EDF missing), "..." ".....": all-dots or uppercase flag chars
@inline function _f32(s::AbstractString)
    isempty(s) && return Float32(NaN)
    all(c -> c == '.' || (c >= 'A' && c <= 'Z'), s) && return Float32(NaN)
    v = tryparse(Float32, s)
    isnothing(v) ? Float32(NaN) : v
end
_u32(s::AbstractString) = parse(UInt32, s)
_i64(s::AbstractString) = parse(Int64, s)

function _eye_code(s::AbstractString)
    s == "R" && return Int16(EYE_RIGHT)
    s == "L" && return Int16(EYE_LEFT)
    return Int16(EYE_BINOCULAR)
end

@inline function _trial_val(trial::Int, in_trial::Bool)
    in_trial ? trial : missing
end

# Collect NamedTuples into a DataFrame
# Handles heterogeneous schemas: builds column-by-column using keys from all rows
function _rows_to_df(rows::Vector)
    isempty(rows) && return DataFrame()
    all_keys = Symbol[]
    seen = Set{Symbol}()
    for row in rows
        for k in keys(row)
            if k ∉ seen
                push!(all_keys, k)
                push!(seen, k)
            end
        end
    end
    d = Dict{Symbol,Any}()
    for k in all_keys
        d[k] = [get(row, k, missing) for row in rows]
    end
    return DataFrame(d; copycols = false)
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

function _parse_msg(parts, trial, in_trial)
    length(parts) < 2 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
    text = length(parts) >= 3 ? strip(parts[3]) : ""
    tr_val = _trial_val(trial, in_trial)
    return (
        type = Int16(EVENT_MESSAGEEVENT),
        time = ts,
        sttime = ts,
        entime = ts,
        eye = Int16(-1),
        message = String(text),
        trial = tr_val,
        input = Int32(0),
    )
end

function _parse_efix(line, trial, in_trial)
    parts = split(line)
    length(parts) < 8 && return nothing
    eye = _eye_code(parts[2])
    st = tryparse(UInt32, parts[3])
    isnothing(st) && return nothing
    en = tryparse(UInt32, parts[4])
    isnothing(en) && return nothing
    dur = _i64(parts[5])
    gavx = _f32(parts[6])
    gavy = _f32(parts[7])
    ava = _f32(parts[8])
    tr_val = _trial_val(trial, in_trial)
    return (
        type = Int16(EVENT_ENDFIX),
        time = en,
        sttime = st,
        entime = en,
        duration = dur,
        gavx = gavx,
        gavy = gavy,
        ava = ava,
        eye = eye,
        message = "",
        trial = tr_val,
        input = Int32(0),
        gstx = Float32(NaN),
        gsty = Float32(NaN),
        genx = Float32(NaN),
        geny = Float32(NaN),
        hstx = Float32(NaN),
        hsty = Float32(NaN),
        henx = Float32(NaN),
        heny = Float32(NaN),
        havx = Float32(NaN),
        havy = Float32(NaN),
        avel = Float32(NaN),
        pvel = Float32(NaN),
        svel = Float32(NaN),
        evel = Float32(NaN),
    )
end

function _parse_esacc(line, trial, in_trial)
    parts = split(line)
    length(parts) < 11 && return nothing
    eye = _eye_code(parts[2])
    st = tryparse(UInt32, parts[3])
    isnothing(st) && return nothing
    en = tryparse(UInt32, parts[4])
    isnothing(en) && return nothing
    dur = _i64(parts[5])
    gstx = _f32(parts[6])
    gsty = _f32(parts[7])
    genx = _f32(parts[8])
    geny = _f32(parts[9])
    ampl = _f32(parts[10])
    pvel = _f32(parts[11])
    tr_val = _trial_val(trial, in_trial)
    return (
        type = Int16(EVENT_ENDSACC),
        time = en,
        sttime = st,
        entime = en,
        duration = dur,
        gstx = gstx,
        gsty = gsty,
        genx = genx,
        geny = geny,
        ampl = ampl,
        pvel = pvel,
        hstx = Float32(NaN),
        hsty = Float32(NaN),
        henx = Float32(NaN),
        heny = Float32(NaN),
        havx = Float32(NaN),
        havy = Float32(NaN),
        svel = Float32(NaN),
        evel = Float32(NaN),
        gavx = Float32(NaN),
        gavy = Float32(NaN),
        ava = Float32(NaN),
        eye = eye,
        message = "",
        trial = tr_val,
        input = Int32(0),
    )
end

function _parse_eblink(line, trial, in_trial)
    parts = split(line)
    length(parts) < 5 && return nothing
    eye = _eye_code(parts[2])
    st = tryparse(UInt32, parts[3])
    isnothing(st) && return nothing
    en = tryparse(UInt32, parts[4])
    isnothing(en) && return nothing
    dur = _i64(parts[5])
    tr_val = _trial_val(trial, in_trial)
    return (
        type = Int16(EVENT_ENDBLINK),
        time = en,
        sttime = st,
        entime = en,
        duration = dur,
        eye = eye,
        message = "",
        trial = tr_val,
        input = Int32(0),
        gavx = Float32(NaN),
        gavy = Float32(NaN),
        ava = Float32(NaN),
        gstx = Float32(NaN),
        gsty = Float32(NaN),
        genx = Float32(NaN),
        geny = Float32(NaN),
        hstx = Float32(NaN),
        hsty = Float32(NaN),
        henx = Float32(NaN),
        heny = Float32(NaN),
        havx = Float32(NaN),
        havy = Float32(NaN),
        avel = Float32(NaN),
        pvel = Float32(NaN),
        svel = Float32(NaN),
        evel = Float32(NaN),
    )
end

function _parse_input(line, trial, in_trial)
    parts = split(line)
    length(parts) < 3 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
    val = tryparse(Int32, parts[3])
    isnothing(val) && return nothing
    tr_val = _trial_val(trial, in_trial)
    return (
        type = Int16(EVENT_INPUTEVENT),
        time = ts,
        sttime = ts,
        entime = ts,
        duration = Int64(0),
        eye = Int16(-1),
        message = "",
        trial = tr_val,
        input = val,
        gavx = Float32(NaN),
        gavy = Float32(NaN),
        ava = Float32(NaN),
        gstx = Float32(NaN),
        gsty = Float32(NaN),
        genx = Float32(NaN),
        geny = Float32(NaN),
        hstx = Float32(NaN),
        hsty = Float32(NaN),
        henx = Float32(NaN),
        heny = Float32(NaN),
        havx = Float32(NaN),
        havy = Float32(NaN),
        avel = Float32(NaN),
        pvel = Float32(NaN),
        svel = Float32(NaN),
        evel = Float32(NaN),
    )
end

function _parse_start(line)
    parts = split(line)
    length(parts) < 2 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
    eye = length(parts) >= 3 ? _eye_code(parts[3]) : Int16(EYE_RIGHT)
    return (
        time = ts,
        state = UInt8(RECORDING_START),
        eye = eye,
        sample_rate = Float32(0),
        eflags = UInt16(0),
        sflags = UInt16(0),
        record_type = UInt8(RECORD_BOTH),
        pupil_type = UInt8(PUPIL_AREA),
        recording_mode = UInt8(MODE_CR),
        filter_type = UInt8(0),
        pos_type = UInt8(POS_GAZE),
        trial = missing,
    )
end

function _parse_end(line)
    parts = split(line)
    length(parts) < 2 && return nothing
    ts = tryparse(UInt32, parts[2])
    isnothing(ts) && return nothing
    return (
        time = ts,
        state = UInt8(RECORDING_END),
        eye = Int16(-1),
        sample_rate = Float32(0),
        eflags = UInt16(0),
        sflags = UInt16(0),
        record_type = UInt8(RECORD_BOTH),
        pupil_type = UInt8(PUPIL_AREA),
        recording_mode = UInt8(MODE_CR),
        filter_type = UInt8(0),
        pos_type = UInt8(POS_GAZE),
        trial = missing,
    )
end
