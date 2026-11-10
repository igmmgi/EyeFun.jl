# SR Research EyeLink binary (.edf) reader.

const EYE_FLAG_RIGHT = 0x40
const EYE_FLAG_LEFT = 0x80
const TYPE_MASK = 0x3F
const HEADER_MARKER = 0x21  # Constant byte in record headers

# Sample record flags
const SAMPLE_FULL_TS_FLAG = 0x2000   # Bit 13: full 4-byte timestamp present (vs 1-byte delta)

function _extract_edf_preamble(data::Vector{UInt8})
    n = length(data)
    @inbounds for i = 1:(n-5)
        if data[i] == 0x45 &&
           data[i+1] == 0x4e &&
           data[i+2] == 0x44 &&
           data[i+3] == 0x50 &&
           data[i+4] == 0x3a &&
           data[i+5] == 0x0a
            pre = i > 1 ? GC.@preserve(data, unsafe_string(pointer(data), i - 1)) : ""
            return pre, i + 6
        end
    end
    error("EDF preamble end marker (ENDP:) not found")
end

@inline function read_be_uint32(data::Vector{UInt8}, offset::Int)
    return GC.@preserve data bswap(unsafe_load(Ptr{UInt32}(pointer(data, offset))))
end

@inline function read_be_int16(data::Vector{UInt8}, offset::Int)
    return GC.@preserve data bswap(unsafe_load(Ptr{Int16}(pointer(data, offset))))
end

@inline function read_be_uint16(data::Vector{UInt8}, offset::Int)
    return GC.@preserve data bswap(unsafe_load(Ptr{UInt16}(pointer(data, offset))))
end

@inline function _is_ascii_ident_cont(b::UInt8)::Bool
    return (UInt8('A') <= b <= UInt8('Z')) ||
           (UInt8('a') <= b <= UInt8('z')) ||
           b == UInt8('_')
end

@inline function _matches_marker_bytes(
    data::Vector{UInt8},
    lo::Int,
    hi::Int,
    marker::String,
)::Bool
    mlen = sizeof(marker)
    mlen == 0 && return false
    @inbounds while lo <= hi && (data[lo] == UInt8(' ') || data[lo] == UInt8('\t'))
        lo += 1
    end
    rem = hi - lo + 1
    rem < mlen && return false
    @inbounds for k = 1:mlen
        data[lo+k-1] == codeunit(marker, k) || return false
    end
    rem == mlen && return true
    last_m = codeunit(marker, mlen)
    if (UInt8('A') <= last_m <= UInt8('Z')) || (UInt8('a') <= last_m <= UInt8('z'))
        next_b = @inbounds data[lo+mlen]
        _is_ascii_ident_cont(next_b) && return false
    end
    return true
end

"""Locate MESSAGEEVENT payload byte span from a byte vector. Returns (text_start, text_end, new_pos)."""
@inline function _msg_span_bytes(data::Vector{UInt8}, pos::Int)
    n = length(data)
    pos + 2 > n && return (1, 0, pos)
    # extra_byte(1) + uint16_be msg_len(2) + text(msg_len) + null + padding
    msg_len = Int(read_be_uint16(data, pos + 1))
    text_start = pos + 3
    raw_end = min(text_start + msg_len - 1, n)
    next_pos = raw_end + 1
    while next_pos <= n && @inbounds(data[next_pos]) == 0x00
        next_pos += 1
    end
    text_end = raw_end
    while text_end >= text_start && @inbounds(data[text_end]) == 0x00
        text_end -= 1
    end
    text_end < text_start && return (1, 0, next_pos)
    return (text_start, text_end, next_pos)
end

"""Parse an INPUT/BUTTON payload from a byte vector. Returns (value, new_pos)."""
function _input_bytes(data::Vector{UInt8}, pos::Int)
    n = length(data)
    pos + 2 > n && return (0, pos)
    val = Int(read_be_uint16(data, pos + 1)) # extra(1) + uint16_be value(2)
    pos += 4                                 # always consume the mandatory trailing pad byte too
    while pos <= n && data[pos] == 0x00
        pos += 1
    end
    return val, pos
end

"""Parse a RECORDING_INFO block from a byte vector. Returns (EDFRecording|nothing, new_pos)."""
function _recording_bytes(
    data::Vector{UInt8},
    pos::Int,
    timestamp::UInt32,
    trial_val::Union{Int,Nothing},
)
    n = length(data)
    pos > n && return nothing, pos

    state_byte = data[pos]
    is_start = (state_byte & 0x01) == 0x01

    if !is_start
        # END recording block: payload is effectively 1 byte (state_byte only).
        # Consuming more would overwrite the next ENDSAMPLES/ENDEVENTS header.
        return EDFRecording(
            timestamp,
            0.0f0,
            UInt16(0),
            UInt16(0),
            UInt8(RECORDING_END),
            UInt8(RECORD_BOTH),
            UInt8(PUPIL_AREA),
            UInt8(MODE_CR),
            UInt8(2),
            UInt8(POS_GAZE),
            UInt8(EYE_LEFT),
            trial_val,
        ),
        pos + 1
    end

    # START recording block is 29 bytes total:
    BLOCK_SIZE = 29
    avail = min(BLOCK_SIZE, n - pos + 1)
    avail < 1 && return nothing, pos

    sample_rate =
        avail >= 3 ? Float32(UInt16(data[pos+1]) << 8 | UInt16(data[pos+2])) : 0.0f0
    eflags = avail >= 5 ? UInt16(data[pos+3]) << 8 | UInt16(data[pos+4]) : UInt16(0)
    eye_byte = avail >= 13 ? data[pos+12] : UInt8(0)
    sflags = avail >= 28 ? UInt16(data[pos+26]) << 8 | UInt16(data[pos+27]) : UInt16(0)
    pos += avail

    pupil_type = (eflags & UInt16(0x0001)) != 0 ? UInt8(PUPIL_DIAMETER) : UInt8(PUPIL_AREA)

    # Determine recorded eye.
    # sflags bits 0x8000 (Left) and 0x4000 (Right) are the most reliable indicators of sample content.
    has_left_sflags = (sflags & UInt16(0x8000)) != 0
    has_right_sflags = (sflags & UInt16(0x4000)) != 0

    rec_eye = if has_left_sflags && has_right_sflags
        UInt8(EYE_BINOCULAR)
    elseif has_right_sflags
        UInt8(EYE_RIGHT)
    elseif has_left_sflags
        UInt8(EYE_LEFT)
    else
        # fallback to eye_byte when sflags are zero
        if eye_byte == UInt8(2)
            UInt8(EYE_BINOCULAR)
        elseif eye_byte == UInt8(1)
            UInt8(EYE_RIGHT)
        else
            UInt8(EYE_LEFT)
        end
    end

    return EDFRecording(
        timestamp,
        sample_rate,
        eflags,
        sflags,
        UInt8(RECORDING_START),
        UInt8(RECORD_BOTH),
        pupil_type,
        UInt8(MODE_CR),
        UInt8(2),
        UInt8(POS_GAZE),
        rec_eye,
        trial_val,
    ),
    pos
end


mutable struct _EDFEventCols
    len::Int
    cap::Int
    msg_used::Int
    msg_arena::Vector{UInt8}
    msg_off::Vector{UInt32}
    msg_len::Vector{UInt32}
    time::Vector{UInt32}
    type::Vector{Int16}
    read::Vector{UInt16}
    sttime::Vector{UInt32}
    entime::Vector{UInt32}
    eye::Vector{Int16}
    status::Vector{UInt16}
    flags::Vector{UInt16}
    input::Vector{UInt16}
    buttons::Vector{UInt16}
    parsedby::Vector{UInt16}
    hstx::Vector{Float32}
    hsty::Vector{Float32}
    gstx::Vector{Float32}
    gsty::Vector{Float32}
    sta::Vector{Float32}
    henx::Vector{Float32}
    heny::Vector{Float32}
    genx::Vector{Float32}
    geny::Vector{Float32}
    ena::Vector{Float32}
    havx::Vector{Float32}
    havy::Vector{Float32}
    gavx::Vector{Float32}
    gavy::Vector{Float32}
    ava::Vector{Float32}
    ampl::Vector{Float32}
    pvel::Vector{Float32}
    svel::Vector{Float32}
    evel::Vector{Float32}
    supd_x::Vector{Float32}
    eupd_x::Vector{Float32}
    supd_y::Vector{Float32}
    eupd_y::Vector{Float32}
end

function _EDFEventCols(cap::Int)
    return _EDFEventCols(
        0,
        cap,
        0,
        Vector{UInt8}(undef, max(cap * 16, 4096)),
        zeros(UInt32, cap),
        zeros(UInt32, cap),
        Vector{UInt32}(undef, cap),
        Vector{Int16}(undef, cap),
        zeros(UInt16, cap),
        Vector{UInt32}(undef, cap),
        Vector{UInt32}(undef, cap),
        Vector{Int16}(undef, cap),
        zeros(UInt16, cap),
        zeros(UInt16, cap),
        zeros(UInt16, cap),
        zeros(UInt16, cap),
        zeros(UInt16, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
        zeros(Float32, cap),
    )
end

@noinline function _grow_f32_group!(cols::Tuple{Vararg{Vector{Float32}}}, old_cap::Int, new_cap::Int)
    for v in cols
        resize!(v, new_cap)
        @inbounds fill!(view(v, (old_cap+1):new_cap), 0.0f0)
    end
    return nothing
end

@noinline function _grow_event_cols!(ev::_EDFEventCols)
    old_cap = ev.cap
    new_cap = max(old_cap * 2, 256)
    ev.cap = new_cap
    resize!(ev.time, new_cap)
    resize!(ev.type, new_cap)
    resize!(ev.sttime, new_cap)
    resize!(ev.entime, new_cap)
    resize!(ev.eye, new_cap)
    resize!(ev.msg_off, new_cap)
    @inbounds fill!(view(ev.msg_off, (old_cap+1):new_cap), UInt32(0))
    resize!(ev.msg_len, new_cap)
    @inbounds fill!(view(ev.msg_len, (old_cap+1):new_cap), UInt32(0))
    for v in (ev.read, ev.status, ev.flags, ev.input, ev.buttons, ev.parsedby)
        resize!(v, new_cap)
        @inbounds fill!(view(v, (old_cap+1):new_cap), UInt16(0))
    end
    _grow_f32_group!(
        (
            ev.hstx,
            ev.hsty,
            ev.gstx,
            ev.gsty,
            ev.sta,
            ev.henx,
            ev.heny,
            ev.genx,
            ev.geny,
            ev.ena,
            ev.havx,
            ev.havy,
        ),
        old_cap,
        new_cap,
    )
    _grow_f32_group!(
        (
            ev.gavx,
            ev.gavy,
            ev.ava,
            ev.ampl,
            ev.pvel,
            ev.svel,
            ev.evel,
            ev.supd_x,
            ev.eupd_x,
            ev.supd_y,
            ev.eupd_y,
        ),
        old_cap,
        new_cap,
    )
    return nothing
end

@noinline function _grow_msg_arena!(ev::_EDFEventCols, needed::Int)
    new_cap = max(length(ev.msg_arena) * 2, needed, 4096)
    resize!(ev.msg_arena, new_cap)
    return nothing
end

@inline function _append_msg_bytes_to_arena!(
    ev::_EDFEventCols,
    k::Int,
    data::Vector{UInt8},
    lo::Int,
    hi::Int,
)
    lo > hi && return nothing
    nb = hi - lo + 1
    used = ev.msg_used
    need = used + nb + 1
    need > length(ev.msg_arena) && _grow_msg_arena!(ev, need)
    arena = ev.msg_arena
    start_off = used + 1
    w = start_off
    @inbounds for i = lo:hi
        b = data[i]
        if b != 0x00
            arena[w] = b
            w += 1
        end
    end
    actual_len = w - start_off
    if actual_len > 0
        @inbounds arena[w] = 0x00 # ASCII boundary prevents multi-byte UTF-8 fusion across messages
        ev.msg_used = w
        @inbounds ev.msg_off[k] = UInt32(start_off)
        @inbounds ev.msg_len[k] = UInt32(actual_len)
    end
    return nothing
end

@inline function _next_event_slot!(ev::_EDFEventCols)::Int
    k = ev.len + 1
    if k > ev.cap
        _grow_event_cols!(ev)
    end
    ev.len = k
    return k
end

@inline function _push_basic_event!(
    ev::_EDFEventCols,
    ts::UInt32,
    et::Int,
    eye_val::Int16;
    msg::String = "",
    input_val::UInt16 = UInt16(0),
    btn_val::UInt16 = UInt16(0),
)
    k = _next_event_slot!(ev)
    @inbounds begin
        ev.time[k] = ts
        ev.type[k] = Int16(et)
        ev.sttime[k] = ts
        ev.entime[k] = ts
        ev.eye[k] = eye_val
        input_val != UInt16(0) && (ev.input[k] = input_val)
        btn_val != UInt16(0) && (ev.buttons[k] = btn_val)
    end
    if !isempty(msg)
        nb = sizeof(msg)
        used = ev.msg_used
        need = used + nb + 1
        need > length(ev.msg_arena) && _grow_msg_arena!(ev, need)
        start_off = used + 1
        GC.@preserve ev msg unsafe_copyto!(pointer(ev.msg_arena, start_off), pointer(msg), nb)
        @inbounds ev.msg_arena[start_off+nb] = 0x00
        ev.msg_used = start_off + nb
        @inbounds ev.msg_off[k] = UInt32(start_off)
        @inbounds ev.msg_len[k] = UInt32(nb)
    end
    return nothing
end

@inline function _push_msg_event_bytes!(
    ev::_EDFEventCols,
    ts::UInt32,
    eye_val::Int16,
    data::Vector{UInt8},
    lo::Int,
    hi::Int,
)
    k = _next_event_slot!(ev)
    @inbounds begin
        ev.time[k] = ts
        ev.type[k] = Int16(EVENT_MESSAGEEVENT)
        ev.sttime[k] = ts
        ev.entime[k] = ts
        ev.eye[k] = eye_val
    end
    _append_msg_bytes_to_arena!(ev, k, data, lo, hi)
    return nothing
end

@inline function _push_fevent_bytes!(
    ev::_EDFEventCols,
    data::Vector{UInt8},
    pos::Int,
    ts::UInt32,
    et::Int,
    eye_val::Int16,
)::Int
    k = _next_event_slot!(ev)
    @inbounds begin
        ev.time[k] = ts
        ev.type[k] = Int16(et)
        ev.sttime[k] = ts
        ev.eye[k] = eye_val
    end
    if et == EVENT_ENDBLINK
        @inbounds ev.entime[k] = ts
        return pos
    end
    payload_size = et == EVENT_ENDSACC ? 48 : 67
    n = length(data)
    pl = min(pos + payload_size - 1, n)
    entime = pl >= pos + 4 ? read_be_uint32(data, pos + 1) : UInt32(0)
    @inbounds ev.entime[k] = entime
    if et == EVENT_ENDSACC
        hstx = pl >= pos + 6 ? Float32(read_be_int16(data, pos + 5)) / 10.0f0 : 0.0f0
        hsty = pl >= pos + 8 ? Float32(read_be_int16(data, pos + 7)) / 10.0f0 : 0.0f0
        gstx = pl >= pos + 12 ? Float32(read_be_int16(data, pos + 11)) / 10.0f0 : 0.0f0
        gsty = pl >= pos + 14 ? Float32(read_be_int16(data, pos + 13)) / 10.0f0 : 0.0f0
        henx = pl >= pos + 18 ? Float32(read_be_int16(data, pos + 17)) / 10.0f0 : 0.0f0
        heny = pl >= pos + 20 ? Float32(read_be_int16(data, pos + 19)) / 10.0f0 : 0.0f0
        genx = pl >= pos + 22 ? Float32(read_be_int16(data, pos + 21)) / 10.0f0 : 0.0f0
        geny = pl >= pos + 24 ? Float32(read_be_int16(data, pos + 23)) / 10.0f0 : 0.0f0
        pvel = pl >= pos + 36 ? Float32(read_be_int16(data, pos + 35)) / 10.0f0 : 0.0f0
        ppd_x = pl >= pos + 44 ? Float32(read_be_int16(data, pos + 43)) / 10.0f0 : 0.0f0
        ppd_y = pl >= pos + 46 ? Float32(read_be_int16(data, pos + 45)) / 10.0f0 : 0.0f0
        ppd_mean = (ppd_x + ppd_y) / 2.0f0
        pixel_dist = sqrt((genx - gstx)^2 + (geny - gsty)^2)
        ampl = ppd_mean > 0.0f0 ? pixel_dist / ppd_mean : 0.0f0
        @inbounds begin
            ev.hstx[k] = hstx
            ev.hsty[k] = hsty
            ev.gstx[k] = gstx
            ev.gsty[k] = gsty
            ev.henx[k] = henx
            ev.heny[k] = heny
            ev.genx[k] = genx
            ev.geny[k] = geny
            ev.havx[k] = hstx
            ev.havy[k] = hsty
            ev.gavx[k] = gstx
            ev.gavy[k] = gsty
            ev.ampl[k] = ampl
            ev.pvel[k] = pvel
            ev.supd_x[k] = ppd_x
            ev.eupd_x[k] = ppd_x
            ev.supd_y[k] = ppd_y
            ev.eupd_y[k] = ppd_y
        end
    else
        hstx = pl >= pos + 6 ? Float32(read_be_int16(data, pos + 5)) / 10.0f0 : 0.0f0
        hsty = pl >= pos + 8 ? Float32(read_be_int16(data, pos + 7)) / 10.0f0 : 0.0f0
        gavx = pl >= pos + 12 ? Float32(read_be_int16(data, pos + 11)) / 10.0f0 : 0.0f0
        gavy = pl >= pos + 14 ? Float32(read_be_int16(data, pos + 13)) / 10.0f0 : 0.0f0
        ava = pl >= pos + 37 ? Float32(read_be_int16(data, pos + 36)) : 0.0f0
        @inbounds begin
            ev.hstx[k] = hstx
            ev.hsty[k] = hsty
            ev.gstx[k] = gavx
            ev.gsty[k] = gavy
            ev.sta[k] = ava
            ev.henx[k] = hstx
            ev.heny[k] = hsty
            ev.genx[k] = gavx
            ev.geny[k] = gavy
            ev.ena[k] = ava
            ev.havx[k] = hstx
            ev.havy[k] = hsty
            ev.gavx[k] = gavx
            ev.gavy[k] = gavy
            ev.ava[k] = ava
        end
    end
    return pos + payload_size
end

function _resize_f32_group!(cols::Tuple{Vararg{Vector{Float32}}}, n::Int)
    for v in cols
        resize!(v, n)
    end
    return nothing
end

function _finalize_events_df!(ev::_EDFEventCols)::DataFrame
    n = ev.len
    n == 0 && return DataFrame()
    if n < ev.cap
        resize!(ev.time, n)
        resize!(ev.type, n)
        resize!(ev.sttime, n)
        resize!(ev.entime, n)
        resize!(ev.eye, n)
        for v in (ev.read, ev.status, ev.flags, ev.input, ev.buttons, ev.parsedby)
            resize!(v, n)
        end
        _resize_f32_group!(
            (
                ev.hstx,
                ev.hsty,
                ev.gstx,
                ev.gsty,
                ev.sta,
                ev.henx,
                ev.heny,
                ev.genx,
                ev.geny,
                ev.ena,
                ev.havx,
                ev.havy,
            ),
            n,
        )
        _resize_f32_group!(
            (
                ev.gavx,
                ev.gavy,
                ev.ava,
                ev.ampl,
                ev.pvel,
                ev.svel,
                ev.evel,
                ev.supd_x,
                ev.eupd_x,
                ev.supd_y,
                ev.eupd_y,
            ),
            n,
        )
    end

    arena_str = if ev.msg_used > 0
        resize!(ev.msg_arena, ev.msg_used)
        String(ev.msg_arena)
    else
        ""
    end
    empty_sub = SubString(arena_str, 1, 0)
    msgs = Vector{SubString{String}}(undef, n)
    offs = ev.msg_off
    lens = ev.msg_len
    @inbounds for i = 1:n
        ml = Int(lens[i])
        if ml == 0
            msgs[i] = empty_sub
        else
            off = Int(offs[i])
            end_b = off + ml - 1
            last_i = codeunit(arena_str, end_b) < 0x80 ? end_b : thisind(arena_str, end_b)
            msgs[i] = SubString(arena_str, off, last_i)
        end
    end

    return DataFrame(
        time = ev.time,
        type = ev.type,
        read = ev.read,
        sttime = ev.sttime,
        entime = ev.entime,
        eye = ev.eye,
        status = ev.status,
        flags = ev.flags,
        input = ev.input,
        buttons = ev.buttons,
        parsedby = ev.parsedby,
        message = msgs,
        hstx = ev.hstx,
        hsty = ev.hsty,
        gstx = ev.gstx,
        gsty = ev.gsty,
        sta = ev.sta,
        henx = ev.henx,
        heny = ev.heny,
        genx = ev.genx,
        geny = ev.geny,
        ena = ev.ena,
        havx = ev.havx,
        havy = ev.havy,
        gavx = ev.gavx,
        gavy = ev.gavy,
        ava = ev.ava,
        ampl = ev.ampl,
        pvel = ev.pvel,
        svel = ev.svel,
        evel = ev.evel,
        supd_x = ev.supd_x,
        eupd_x = ev.eupd_x,
        supd_y = ev.supd_y,
        eupd_y = ev.eupd_y;
        copycols = false,
    )
end

function _edf_sample_body_bytes(sflags::UInt16)::Int
    n_eyes = ((sflags & UInt16(0x8000)) != 0 ? 1 : 0) + ((sflags & UInt16(0x4000)) != 0 ? 1 : 0)
    b = 0
    (sflags & UInt16(0x1000)) != 0 && (b += 4 * n_eyes)
    (sflags & UInt16(0x0800)) != 0 && (b += 4 * n_eyes)
    (sflags & UInt16(0x0400)) != 0 && (b += 4 * n_eyes)
    (sflags & UInt16(0x0200)) != 0 && (b += 4)
    (sflags & UInt16(0x0100)) != 0 && (b += 2 * n_eyes)
    (sflags & UInt16(0x0040)) != 0 && (b += 2)
    (sflags & UInt16(0x0080)) != 0 && (b += 2)
    (sflags & UInt16(0x0020)) != 0 && (b += 2)
    (sflags & UInt16(0x0010)) != 0 && (b += 2)
    return b
end

mutable struct _EDFSampleCols
    len::Int
    cap::Int
    time::Vector{UInt32}
    gxR::Vector{Float32}
    gyR::Vector{Float32}
    paR::Vector{Float32}
    gxL::Vector{Float32}
    gyL::Vector{Float32}
    paL::Vector{Float32}
    hxR::Vector{Float32}
    hyR::Vector{Float32}
    hxL::Vector{Float32}
    hyL::Vector{Float32}
    rx::Vector{Float32}
    ry::Vector{Float32}
    flags::Vector{UInt16}
    input::Vector{UInt16}
    status::Vector{UInt16}
    trial::Vector{Union{Int,Missing}}
end

function _EDFSampleCols(cap::Int)
    return _EDFSampleCols(
        0,
        cap,
        Vector{UInt32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{Float32}(undef, cap),
        Vector{UInt16}(undef, cap),
        Vector{UInt16}(undef, cap),
        Vector{UInt16}(undef, cap),
        Vector{Union{Int,Missing}}(missing, cap),
    )
end

@noinline function _grow_sample_cols!(sc::_EDFSampleCols, new_cap::Int)
    old_cap = sc.cap
    new_cap <= old_cap && return nothing
    sc.cap = new_cap
    resize!(sc.time, new_cap)
    resize!(sc.gxR, new_cap)
    resize!(sc.gyR, new_cap)
    resize!(sc.paR, new_cap)
    resize!(sc.gxL, new_cap)
    resize!(sc.gyL, new_cap)
    resize!(sc.paL, new_cap)
    resize!(sc.hxR, new_cap)
    resize!(sc.hyR, new_cap)
    resize!(sc.hxL, new_cap)
    resize!(sc.hyL, new_cap)
    resize!(sc.rx, new_cap)
    resize!(sc.ry, new_cap)
    resize!(sc.flags, new_cap)
    resize!(sc.input, new_cap)
    resize!(sc.status, new_cap)
    resize!(sc.trial, new_cap)
    @inbounds fill!(view(sc.trial, (old_cap+1):new_cap), missing)
    return nothing
end

function _finalize_samples_df!(sc::_EDFSampleCols)::DataFrame
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
        resize!(sc.hxR, n)
        resize!(sc.hyR, n)
        resize!(sc.hxL, n)
        resize!(sc.hyL, n)
        resize!(sc.rx, n)
        resize!(sc.ry, n)
        resize!(sc.flags, n)
        resize!(sc.input, n)
        resize!(sc.status, n)
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
        hxR = sc.hxR,
        hyR = sc.hyR,
        hxL = sc.hxL,
        hyL = sc.hyL,
        rx = sc.rx,
        ry = sc.ry,
        flags = sc.flags,
        input = sc.input,
        errors = sc.status,
        trial = sc.trial;
        copycols = false,
    )
end

"""
Push one decoded sample from a byte array into `_EDFSampleCols`.
`pos` points to the first byte AFTER the already-consumed flags word.
Returns `(new_pos, new_timestamp)`.
"""
@inline function _push_sample_bytes!(
    data::Vector{UInt8},
    pos::Int,
    flags::UInt16,
    sflags::UInt16,
    current_ts::UInt32,
    in_trial::Bool,
    trial::Int,
    sc::_EDFSampleCols,
)
    if (flags & SAMPLE_FULL_TS_FLAG) != 0
        current_ts = read_be_uint32(data, pos)
        pos += 4
    else
        current_ts += UInt32(@inbounds data[pos])
        pos += 1
    end

    MISS = Int16(-32768)
    NaN32 = Float32(NaN)

    has_left = (sflags & UInt16(0x8000)) != 0
    has_right = (sflags & UInt16(0x4000)) != 0

    hxL = hxR = hyL = hyR = MISS
    gxL = gxR = gyL = gyR = MISS
    paL = paR = MISS
    rx = ry = MISS

    # 0x1000 = PUPILXY (skip bytes)
    if (sflags & UInt16(0x1000)) != 0
        has_left && (pos += 4)
        has_right && (pos += 4)
    end

    # 0x0800 = HREFXY
    if (sflags & UInt16(0x0800)) != 0
        if has_left
            hxL = read_be_int16(data, pos)
            pos += 2
            hyL = read_be_int16(data, pos)
            pos += 2
        end
        if has_right
            hxR = read_be_int16(data, pos)
            pos += 2
            hyR = read_be_int16(data, pos)
            pos += 2
        end
    end

    # 0x0400 = GAZEXY
    if (sflags & UInt16(0x0400)) != 0
        if has_left
            gxL = read_be_int16(data, pos)
            pos += 2
            gyL = read_be_int16(data, pos)
            pos += 2
        end
        if has_right
            gxR = read_be_int16(data, pos)
            pos += 2
            gyR = read_be_int16(data, pos)
            pos += 2
        end
    end

    # 0x0200 = REALRES
    if (sflags & UInt16(0x0200)) != 0
        rx = read_be_int16(data, pos)
        pos += 2
        ry = read_be_int16(data, pos)
        pos += 2
    end

    # 0x0100 = PUPILSIZE
    if (sflags & UInt16(0x0100)) != 0
        if has_left
            paL = read_be_int16(data, pos)
            pos += 2
        end
        if has_right
            paR = read_be_int16(data, pos)
            pos += 2
        end
    end

    status = UInt16(0)
    input_val = UInt8(0)

    if (sflags & UInt16(0x0040)) != 0 # STATUS
        status = read_be_uint16(data, pos)
        pos += 2
    end
    if (sflags & UInt16(0x0080)) != 0 # INPUT / INTERP
        pos += 1
        input_val = @inbounds data[pos]
        pos += 1
    end
    if (sflags & UInt16(0x0020)) != 0 # HTARGET
        pos += 2
    end
    if (sflags & UInt16(0x0010)) != 0 # COLOR / HMARKER
        pos += 2
    end

    k = sc.len + 1
    if k > sc.cap
        _grow_sample_cols!(sc, max(sc.cap * 2, 1024))
    end
    sc.len = k

    @inbounds begin
        sc.time[k] = current_ts
        sc.gxL[k] = gxL == MISS ? NaN32 : Float32(gxL) / 10.0f0
        sc.gyL[k] = gyL == MISS ? NaN32 : Float32(gyL) / 10.0f0
        sc.paL[k] = paL == MISS ? NaN32 : Float32(paL)
        sc.hxL[k] = hxL == MISS ? NaN32 : Float32(hxL)
        sc.hyL[k] = hyL == MISS ? NaN32 : Float32(hyL)
        sc.gxR[k] = gxR == MISS ? NaN32 : Float32(gxR) / 10.0f0
        sc.gyR[k] = gyR == MISS ? NaN32 : Float32(gyR) / 10.0f0
        sc.paR[k] = paR == MISS ? NaN32 : Float32(paR)
        sc.hxR[k] = hxR == MISS ? NaN32 : Float32(hxR)
        sc.hyR[k] = hyR == MISS ? NaN32 : Float32(hyR)
        sc.rx[k] = rx == MISS ? NaN32 : Float32(rx) / 10.0f0
        sc.ry[k] = ry == MISS ? NaN32 : Float32(ry) / 10.0f0
        sc.flags[k] = flags
        sc.input[k] = UInt16(input_val)
        sc.status[k] = status
        in_trial && (sc.trial[k] = trial)
    end

    return pos, current_ts
end
