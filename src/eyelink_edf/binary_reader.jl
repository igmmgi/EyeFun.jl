"""
Julia EDF binary reader — reads SR Research EDF files directly without libedfapi.so.

Reverse-engineered via help (lots) of Claude/Gemini + trial and error hex dumps, and
edf2asc round-trips :-)

NB. This has not been exhaustively tested, but it works for my files and several others 
I have tested! More test files welcome!

We also have ascii_reader which can read the output of edf2asc.
"""

# ──────────────────────────────────────────────────────────────────────────── #
# Constants for the binary format
# ──────────────────────────────────────────────────────────────────────────── #

const EDF_MAGIC = "SR_RESEARCH_1000" # TODO: check if this is always the same, or only for my files!
const EDF_PREAMBLE_END = "ENDP:\n"

const EYE_FLAG_RIGHT = 0x40
const EYE_FLAG_LEFT = 0x80
const TYPE_MASK = 0x3F
const HEADER_MARKER = 0x21  # Constant byte in record headers

# Sample record flags
const SAMPLE_FULL_TS_FLAG = 0x2000   # Bit 13: full 4-byte timestamp present (vs 1-byte delta)

struct EDFEventBasic
    time::UInt32
    type::Int16
    read::UInt16
    sttime::UInt32
    entime::UInt32
    eye::Int16
    status::UInt16
    flags::UInt16
    input::UInt16
    buttons::UInt16
    parsedby::UInt16
    message::String
end

struct EDFEventPositions
    hstx::Float32
    hsty::Float32
    gstx::Float32
    gsty::Float32
    sta::Float32
    henx::Float32
    heny::Float32
    genx::Float32
    geny::Float32
    ena::Float32
    havx::Float32
    havy::Float32
    gavx::Float32
    gavy::Float32
    ava::Float32
end

struct EDFEventVelocities
    ampl::Float32
    pvel::Float32
    svel::Float32
    evel::Float32
    supd_x::Float32
    eupd_x::Float32
    supd_y::Float32
    eupd_y::Float32
end

struct EDFEvent
    basic::EDFEventBasic
    positions::EDFEventPositions
    velocities::EDFEventVelocities
end

const ZERO_POSITIONS = EDFEventPositions(
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
    0.0f0,
)
const ZERO_VELOCITIES =
    EDFEventVelocities(0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0)

struct EDFSample
    time::UInt32
    pxL::Union{Float32,Nothing}
    pxR::Union{Float32,Nothing}
    pyL::Union{Float32,Nothing}
    pyR::Union{Float32,Nothing}
    hxL::Union{Float32,Nothing}
    hxR::Union{Float32,Nothing}
    hyL::Union{Float32,Nothing}
    hyR::Union{Float32,Nothing}
    paL::Union{Float32,Nothing}
    paR::Union{Float32,Nothing}
    gxL::Union{Float32,Nothing}
    gxR::Union{Float32,Nothing}
    gyL::Union{Float32,Nothing}
    gyR::Union{Float32,Nothing}
    rx::Float32
    ry::Float32
    gxvelL::Union{Float32,Nothing}
    gxvelR::Union{Float32,Nothing}
    gyvelL::Union{Float32,Nothing}
    gyvelR::Union{Float32,Nothing}
    hxvelL::Union{Float32,Nothing}
    hxvelR::Union{Float32,Nothing}
    hyvelL::Union{Float32,Nothing}
    hyvelR::Union{Float32,Nothing}
    rxvelL::Union{Float32,Nothing}
    rxvelR::Union{Float32,Nothing}
    ryvelL::Union{Float32,Nothing}
    ryvelR::Union{Float32,Nothing}
    fgxvelL::Union{Float32,Nothing}
    fgxvelR::Union{Float32,Nothing}
    fgyvelL::Union{Float32,Nothing}
    fgyvelR::Union{Float32,Nothing}
    fhxvelL::Union{Float32,Nothing}
    fhxvelR::Union{Float32,Nothing}
    fhyvelL::Union{Float32,Nothing}
    fhyvelR::Union{Float32,Nothing}
    frxvelL::Union{Float32,Nothing}
    frxvelR::Union{Float32,Nothing}
    fryvelL::Union{Float32,Nothing}
    fryvelR::Union{Float32,Nothing}
    hdata1::Union{Int16,Nothing}
    hdata2::Union{Int16,Nothing}
    hdata3::Union{Int16,Nothing}
    hdata4::Union{Int16,Nothing}
    hdata5::Union{Int16,Nothing}
    hdata6::Union{Int16,Nothing}
    hdata7::Union{Int16,Nothing}
    hdata8::Union{Int16,Nothing}
    flags::UInt16
    input::UInt16
    buttons::UInt16
    htype::Int16
    errors::UInt16
    trial::Union{Int,Nothing}
end


"""Read a big-endian UInt32 from an IO stream."""
@inline function read_be_uint32(io::IO)
    b1 = read(io, UInt8)
    b2 = read(io, UInt8)
    b3 = read(io, UInt8)
    b4 = read(io, UInt8)
    return UInt32(b1) << 24 | UInt32(b2) << 16 | UInt32(b3) << 8 | UInt32(b4)
end

"""Read a big-endian Int16 from an IO stream."""
@inline function read_be_int16(io::IO)
    b1 = read(io, UInt8)
    b2 = read(io, UInt8)
    return reinterpret(Int16, UInt16(b1) << 8 | UInt16(b2))
end

"""Read a big-endian UInt16 from an IO stream."""
@inline function read_be_uint16(io::IO)
    b1 = read(io, UInt8)
    b2 = read(io, UInt8)
    return UInt16(b1) << 8 | UInt16(b2)
end

"""Read a big-endian UInt32 from a byte vector at a given offset (1-indexed)."""
function read_be_uint32(data::Vector{UInt8}, offset::Int)
    return UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
           UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
end

"""Read a big-endian Int16 from a byte vector at a given offset (1-indexed)."""
function read_be_int16(data::Vector{UInt8}, offset::Int)
    raw = UInt16(data[offset]) << 8 | UInt16(data[offset+1])
    return reinterpret(Int16, raw)
end


"""
    read_edf_preamble(io::IO) -> String

Read the ASCII preamble from an EDF file. Returns the preamble text
(everything before "ENDP:\\n").
"""
function read_edf_preamble(io::IO)
    buf = IOBuffer()
    endp_marker = collect(UInt8, EDF_PREAMBLE_END)  # [0x45, 0x4e, 0x44, 0x50, 0x3a, 0x0a]
    marker_len = length(endp_marker)
    ring = zeros(UInt8, marker_len)
    ring_pos = 0

    while !eof(io)
        byte = read(io, UInt8)
        write(buf, byte)

        # Track last N bytes in a ring buffer to detect end marker
        ring_pos = mod1(ring_pos + 1, marker_len)
        ring[ring_pos] = byte

        # Check if past bytes match the marker
        if ring_pos >= marker_len || position(buf) >= marker_len
            match = true
            for k = 1:marker_len
                idx = mod1(ring_pos - marker_len + k, marker_len)
                if ring[idx] != endp_marker[k]
                    match = false
                    break
                end
            end
            if match
                # Return text BEFORE the ENDP: marker
                text = String(take!(buf))
                # Strip the ENDP:\n at the end
                return text[1:(end-marker_len)]
            end
        end
    end

    error("EDF preamble end marker (ENDP:) not found")
end


"""
    RecordHeader

Parsed 7-byte record header from the EDF binary stream.
An `event_type` of `-1` is the EOF sentinel (returned instead of `nothing`
to avoid `Union{RecordHeader,Nothing}` heap boxing on every call).
"""
struct RecordHeader
    event_type::Int      # Lower 6 bits of type byte. -1 = EOF sentinel.
    eye::Int             # 0=none, 1=left, 2=right, 3=both (from upper 2 bits)
    flags_byte::UInt8    # Second byte of header (varies per record)
    marker_byte::UInt8   # Third byte (should be 0x21)
    timestamp::UInt32    # Big-endian uint32 timestamp
    raw_type_byte::UInt8 # Full type byte for debugging
end

const EOF_HEADER = RecordHeader(-1, 0, 0x00, 0x00, UInt32(0), 0x00)

"""
    try_read_record_header(io::IO) -> RecordHeader

Try to read one 7-byte record header. Returns `EOF_HEADER` (event_type == -1) at EOF.
Returns a concrete type (never Nothing) to avoid Union heap-boxing on every call.
"""
@inline function try_read_record_header(io::IO)
    eof(io) && return EOF_HEADER
    type_byte = read(io, UInt8)
    eof(io) && return EOF_HEADER
    flags_byte = read(io, UInt8)
    eof(io) && return EOF_HEADER
    marker_byte = read(io, UInt8)
    eof(io) && return EOF_HEADER
    ts = read_be_uint32(io)

    event_type = Int(type_byte & TYPE_MASK)
    eye_bits = (type_byte >> 6) & 0x03
    eye = if eye_bits == 0
        -1
    elseif eye_bits == 1
        EYE_RIGHT
    elseif eye_bits == 2
        EYE_LEFT
    else
        EYE_BINOCULAR
    end

    return RecordHeader(event_type, eye, flags_byte, marker_byte, ts, type_byte)
end

"""Check if a header looks valid (marker byte = 0x21 and known event type)."""
@inline function is_valid_header(h::RecordHeader)
    return h.marker_byte == HEADER_MARKER && h.event_type in (
        EVENT_STARTPARSE,
        EVENT_ENDPARSE,
        EVENT_BREAKPARSE,
        EVENT_STARTBLINK,
        EVENT_ENDBLINK,
        EVENT_STARTSACC,
        EVENT_ENDSACC,
        EVENT_STARTFIX,
        EVENT_ENDFIX,
        EVENT_FIXUPDATE,
        EVENT_STARTSAMPLES,
        EVENT_ENDSAMPLES,
        EVENT_STARTEVENTS,
        EVENT_ENDEVENTS,
        EVENT_MESSAGEEVENT,
        EVENT_BUTTONEVENT,
        EVENT_INPUTEVENT,
        EVENT_LOST_DATA,
    )
end


"""
    read_message_payload(io::IO) -> (msg_text::String, msg_len::Int)

Read the payload of a MESSAGEEVENT record.
Format after header: extra_byte(1) + 0x00(1) + msg_len(1) + text(msg_len) + null + optional padding
"""
function read_message_payload(io::IO)
    read(io, UInt8)  # extra_byte (discarded)
    read(io, UInt8)  # zero_byte (discarded)
    msg_len = Int(read(io, UInt8))

    text_bytes = read(io, msg_len)
    # Read trailing null terminator
    if !eof(io)
        read(io, UInt8)  # null terminator (discarded)
    end
    # Skip padding null bytes (records are sometimes 2-byte aligned)
    while !eof(io)
        next_byte = read(io, UInt8)
        if next_byte != 0x00
            # Not padding — seek back one byte
            skip(io, -1)
            break
        end
    end

    # Convert to string, stripping null chars
    text = String(text_bytes)
    text = replace(text, '\0' => "")

    return text, msg_len
end

"""
    read_input_payload(io::IO) -> Int

Read the payload of an INPUTEVENT record.
Format after header: extra_byte(1) + 0x00(1) + value(1) + padding
"""
function read_input_payload(io::IO)
    read(io, UInt8)  # extra_byte (discarded)
    read(io, UInt8)  # zero_byte (discarded)
    input_value = Int(read(io, UInt8))
    # Read trailing null/padding byte
    if !eof(io)
        read(io, UInt8)  # pad (discarded)
    end
    # Skip additional padding
    while !eof(io)
        next_byte = read(io, UInt8)
        if next_byte != 0x00
            skip(io, -1)
            break
        end
    end

    return input_value
end

"""
    read_button_payload(io::IO) -> Int

Read the payload of a BUTTONEVENT record (similar to INPUT).
"""
function read_button_payload(io::IO)
    # Same structure as INPUT for now
    return read_input_payload(io)
end

"""
    read_fevent_payload(io::IO, event_type::Int) -> NamedTuple

Read the payload of an eye event record (ENDFIX, ENDSACC, ENDBLINK, etc.).
Returns a NamedTuple with decoded fields.

Payload sizes confirmed empirically (next-header alignment, verified against oA_1.asc):
  ENDSACC  (type=6): 48 bytes — gstx/gsty at +12/+14, genx/geny at +22/+24 (×10 int16 BE)
  ENDFIX   (type=8): 67 bytes — gavx/gavy at +12/+14 (×10), ava at +37 (int16 BE)
  ENDBLINK (type=3):  0 bytes — header ts = sttime; entime = sttime (duration unavailable
                               from binary alone; entime equals the concurrent ENDSACC entime)
  FIXUPDATE(type=9): 67 bytes — same layout as ENDFIX

All start events and parse/sample/event control records have ZERO payload bytes.
"""
function read_fevent_payload(io::IO, event_type::Int)
    # Start events and control records have NO payload — return early
    if event_type in (
        EVENT_STARTSACC,
        EVENT_STARTFIX,
        EVENT_STARTBLINK,
        EVENT_STARTPARSE,
        EVENT_ENDPARSE,
        EVENT_BREAKPARSE,
        EVENT_STARTSAMPLES,
        EVENT_ENDSAMPLES,
        EVENT_STARTEVENTS,
        EVENT_ENDEVENTS,
    )
        return (
            sttime=UInt32(0),
            entime=UInt32(0),
            hstx=0.0f0,
            hsty=0.0f0,
            gstx=0.0f0,
            gsty=0.0f0,
            sta=0.0f0,
            henx=0.0f0,
            heny=0.0f0,
            genx=0.0f0,
            geny=0.0f0,
            ena=0.0f0,
            havx=0.0f0,
            havy=0.0f0,
            gavx=0.0f0,
            gavy=0.0f0,
            ava=0.0f0,
            ampl=0.0f0,
            pvel=0.0f0,
            svel=0.0f0,
            evel=0.0f0,
            supd_x=0.0f0,
            eupd_x=0.0f0,
            supd_y=0.0f0,
            eupd_y=0.0f0,
        )
    end

    # Fixed payload sizes (confirmed from binary analysis against oA_1.asc ground truth)
    payload_size = if event_type == EVENT_ENDSACC
        48
    elseif event_type == EVENT_ENDFIX || event_type == EVENT_FIXUPDATE
        67
    elseif event_type == EVENT_ENDBLINK
        # ENDBLINK payload size: the bytes immediately following are recording-end
        # control data (not a standard event payload). Set to 0 — entime is handled
        # by pairing with the surrounding STARTBLINK and ENDSACC context.
        0
    else
        0
    end

    if payload_size == 0
        return (
            sttime=UInt32(0),
            entime=UInt32(0),
            hstx=0.0f0,
            hsty=0.0f0,
            gstx=0.0f0,
            gsty=0.0f0,
            sta=0.0f0,
            henx=0.0f0,
            heny=0.0f0,
            genx=0.0f0,
            geny=0.0f0,
            ena=0.0f0,
            havx=0.0f0,
            havy=0.0f0,
            gavx=0.0f0,
            gavy=0.0f0,
            ava=0.0f0,
            ampl=0.0f0,
            pvel=0.0f0,
            svel=0.0f0,
            evel=0.0f0,
            supd_x=0.0f0,
            eupd_x=0.0f0,
            supd_y=0.0f0,
            eupd_y=0.0f0,
        )
    end

    # Read exact fixed number of payload bytes
    payload_bytes = read(io, payload_size)
    n = length(payload_bytes)

    # All end events share: payload[1]=flags, payload[2..5]=entime (BE uint32)
    entime = n >= 5 ? read_be_uint32(payload_bytes, 2) : UInt32(0)

    if event_type == EVENT_ENDSACC
        # ENDSACC confirmed layout (48 bytes total):
        #   +6/+7   : hstx * 10 (int16 BE) — head-ref start x
        #   +8/+9   : hsty * 10 (int16 BE) — head-ref start y
        #   +12/+13 : gstx * 10 (int16 BE) — gaze start x  ← verified
        #   +14/+15 : gsty * 10 (int16 BE) — gaze start y  ← verified
        #   +18/+19 : henx * 10 (int16 BE) — head-ref end x
        #   +20/+21 : heny * 10 (int16 BE) — head-ref end y
        #   +22/+23 : genx * 10 (int16 BE) — gaze end x    ← verified
        #   +24/+25 : geny * 10 (int16 BE) — gaze end y    ← verified
        hstx = n >= 8 ? Float32(read_be_int16(payload_bytes, 6)) / 10.0f0 : 0.0f0
        hsty = n >= 10 ? Float32(read_be_int16(payload_bytes, 8)) / 10.0f0 : 0.0f0
        gstx = n >= 14 ? Float32(read_be_int16(payload_bytes, 12)) / 10.0f0 : 0.0f0
        gsty = n >= 16 ? Float32(read_be_int16(payload_bytes, 14)) / 10.0f0 : 0.0f0
        henx = n >= 20 ? Float32(read_be_int16(payload_bytes, 18)) / 10.0f0 : 0.0f0
        heny = n >= 22 ? Float32(read_be_int16(payload_bytes, 20)) / 10.0f0 : 0.0f0
        genx = n >= 24 ? Float32(read_be_int16(payload_bytes, 22)) / 10.0f0 : 0.0f0
        geny = n >= 26 ? Float32(read_be_int16(payload_bytes, 24)) / 10.0f0 : 0.0f0
        return (
            sttime=UInt32(0),
            entime=entime,
            hstx=hstx,
            hsty=hsty,
            gstx=gstx,
            gsty=gsty,
            sta=0.0f0,
            henx=henx,
            heny=heny,
            genx=genx,
            geny=geny,
            ena=0.0f0,
            havx=hstx,
            havy=hsty,
            gavx=gstx,
            gavy=gsty,
            ava=0.0f0,
            ampl=0.0f0,
            pvel=0.0f0,
            svel=0.0f0,
            evel=0.0f0,
            supd_x=0.0f0,
            eupd_x=0.0f0,
            supd_y=0.0f0,
            eupd_y=0.0f0,
        )

    elseif event_type == EVENT_ENDFIX || event_type == EVENT_FIXUPDATE
        # ENDFIX confirmed layout (67 bytes total):
        #   +6/+7   : hstx * 10 (int16 BE) — head-ref avg x (approx)
        #   +8/+9   : hsty * 10 (int16 BE) — head-ref avg y (approx)
        #   +12/+13 : gavx * 10 (int16 BE) — average gaze x  ← verified (130.7)
        #   +14/+15 : gavy * 10 (int16 BE) — average gaze y  ← verified (164.3)
        #   +37/+38 : ava         (int16 BE) — average pupil  ← verified (5245)
        hstx = n >= 8 ? Float32(read_be_int16(payload_bytes, 6)) / 10.0f0 : 0.0f0
        hsty = n >= 10 ? Float32(read_be_int16(payload_bytes, 8)) / 10.0f0 : 0.0f0
        gavx = n >= 14 ? Float32(read_be_int16(payload_bytes, 12)) / 10.0f0 : 0.0f0
        gavy = n >= 16 ? Float32(read_be_int16(payload_bytes, 14)) / 10.0f0 : 0.0f0
        ava = n >= 39 ? Float32(read_be_int16(payload_bytes, 37)) : 0.0f0
        return (
            sttime=UInt32(0),
            entime=entime,
            hstx=hstx,
            hsty=hsty,
            gstx=gavx,
            gsty=gavy,
            sta=ava,
            henx=hstx,
            heny=hsty,
            genx=gavx,
            geny=gavy,
            ena=ava,
            havx=hstx,
            havy=hsty,
            gavx=gavx,
            gavy=gavy,
            ava=ava,
            ampl=0.0f0,
            pvel=0.0f0,
            svel=0.0f0,
            evel=0.0f0,
            supd_x=0.0f0,
            eupd_x=0.0f0,
            supd_y=0.0f0,
            eupd_y=0.0f0,
        )

    else  # ENDBLINK — only timing matters, no position data
        return (
            sttime=UInt32(0),
            entime=entime,
            hstx=0.0f0,
            hsty=0.0f0,
            gstx=0.0f0,
            gsty=0.0f0,
            sta=0.0f0,
            henx=0.0f0,
            heny=0.0f0,
            genx=0.0f0,
            geny=0.0f0,
            ena=0.0f0,
            havx=0.0f0,
            havy=0.0f0,
            gavx=0.0f0,
            gavy=0.0f0,
            ava=0.0f0,
            ampl=0.0f0,
            pvel=0.0f0,
            svel=0.0f0,
            evel=0.0f0,
            supd_x=0.0f0,
            eupd_x=0.0f0,
            supd_y=0.0f0,
            eupd_y=0.0f0,
        )
    end
end





"""
    is_event_header(data::Vector{UInt8}) -> Bool

Check if 7 bytes look like a valid event record header (not sample data).
"""
function is_event_header(data::Vector{UInt8})
    length(data) < 7 && return false
    et = Int(data[1] & TYPE_MASK)
    marker = data[3]
    marker != HEADER_MARKER && return false
    et in (
        EVENT_STARTPARSE,
        EVENT_ENDPARSE,
        EVENT_BREAKPARSE,
        EVENT_STARTBLINK,
        EVENT_ENDBLINK,
        EVENT_STARTSACC,
        EVENT_ENDSACC,
        EVENT_STARTFIX,
        EVENT_ENDFIX,
        EVENT_FIXUPDATE,
        EVENT_STARTSAMPLES,
        EVENT_ENDSAMPLES,
        EVENT_STARTEVENTS,
        EVENT_ENDEVENTS,
        EVENT_MESSAGEEVENT,
        EVENT_BUTTONEVENT,
        EVENT_INPUTEVENT,
        EVENT_LOST_DATA,
    ) || return false
    ts =
        UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 |
        UInt32(data[7])
    return ts > 1000000
end

"""
    read_sample_record!(io, current_ts, eye_code, in_trial, trial,
                        col_time, col_gxR, col_gyR, col_paR, col_gxL, col_gyL, col_paL,
                        col_hxR, col_hyR, col_hxL, col_hyL, col_rx, col_ry,
                        col_flags, col_input, col_status, col_trial) -> new_ts::UInt32

Read one sample record and push decoded values directly into pre-allocated column vectors.
Returns the updated timestamp. Uses NaN for missing values instead of Nothing, so all
vectors hold concrete Float32/UInt32 — no per-element boxing, no EDFSample allocation.
"""
@inline function read_sample_record!(
    io::IO,
    current_ts::UInt32,
    eye_code::Int,
    in_trial::Bool,
    trial::Int,
    col_time,
    col_gxR,
    col_gyR,
    col_paR,
    col_gxL,
    col_gyL,
    col_paL,
    col_hxR,
    col_hyR,
    col_hxL,
    col_hyL,
    col_rx,
    col_ry,
    col_flags,
    col_input,
    col_status,
    col_trial,
)
    flags = read_be_uint16(io)
    return _push_sample!(
        io,
        flags,
        current_ts,
        eye_code,
        in_trial,
        trial,
        col_time,
        col_gxR,
        col_gyR,
        col_paR,
        col_gxL,
        col_gyL,
        col_paL,
        col_hxR,
        col_hyR,
        col_hxL,
        col_hyL,
        col_rx,
        col_ry,
        col_flags,
        col_input,
        col_status,
        col_trial,
    )
end

# Accepts already-read flags word — called by the sample-first main loop.
@inline function _push_sample!(
    io::IO,
    flags::UInt16,
    current_ts::UInt32,
    eye_code::Int,
    in_trial::Bool,
    trial::Int,
    col_time,
    col_gxR,
    col_gyR,
    col_paR,
    col_gxL,
    col_gyL,
    col_paL,
    col_hxR,
    col_hyR,
    col_hxL,
    col_hyL,
    col_rx,
    col_ry,
    col_flags,
    col_input,
    col_status,
    col_trial,
)

    if (flags & SAMPLE_FULL_TS_FLAG) != 0
        current_ts = read_be_uint32(io)
    else
        current_ts += UInt32(read(io, UInt8))
    end

    hx_raw = read_be_int16(io)
    hy_raw = read_be_int16(io)
    gx_raw = read_be_int16(io)
    gy_raw = read_be_int16(io)
    rx_raw = read_be_int16(io)
    ry_raw = read_be_int16(io)
    pa_raw = read_be_int16(io)
    status = read_be_uint16(io)
    read(io, UInt8)
    input_val = read(io, UInt8)

    MISS = Int16(-32768)
    NAN = Float32(NaN)
    gx = gx_raw == MISS ? NAN : Float32(gx_raw) / 10.0f0
    gy = gy_raw == MISS ? NAN : Float32(gy_raw) / 10.0f0
    hx = hx_raw == MISS ? NAN : Float32(hx_raw)
    hy = hy_raw == MISS ? NAN : Float32(hy_raw)
    pa = pa_raw == MISS ? NAN : Float32(pa_raw)
    rx = Float32(rx_raw) / 10.0f0
    ry = Float32(ry_raw) / 10.0f0

    push!(col_time, current_ts)
    if eye_code == EYE_LEFT || eye_code == 0
        push!(col_gxL, gx)
        push!(col_gyL, gy)
        push!(col_paL, pa)
        push!(col_hxL, hx)
        push!(col_hyL, hy)
        push!(col_gxR, NAN)
        push!(col_gyR, NAN)
        push!(col_paR, NAN)
        push!(col_hxR, NAN)
        push!(col_hyR, NAN)
    else
        push!(col_gxR, gx)
        push!(col_gyR, gy)
        push!(col_paR, pa)
        push!(col_hxR, hx)
        push!(col_hyR, hy)
        push!(col_gxL, NAN)
        push!(col_gyL, NAN)
        push!(col_paL, NAN)
        push!(col_hxL, NAN)
        push!(col_hyL, NAN)
    end
    push!(col_rx, rx)
    push!(col_ry, ry)
    push!(col_flags, UInt16(flags))
    push!(col_input, UInt16(input_val))
    push!(col_status, UInt16(status))
    push!(col_trial, in_trial ? Int(trial) : typemin(Int))
    return current_ts
end


"""
    skip_sample_data(io::IO) -> Int

Skip over compressed sample data until the next valid record header is found.
Returns the number of bytes skipped.
"""
function skip_sample_data(io::IO)
    skipped = 0
    while !eof(io)
        pos_before = position(io)
        # Check if current position is a valid record header
        if bytesavailable(io) >= 7
            test = read(io, 7)
            seek(io, pos_before)

            test_type = test[1] & TYPE_MASK
            test_marker = test[3]

            if test_marker == HEADER_MARKER &&
               test_type <= 30 &&
               test_type in (
                   EVENT_STARTPARSE,
                   EVENT_ENDPARSE,
                   EVENT_BREAKPARSE,
                   EVENT_STARTBLINK,
                   EVENT_ENDBLINK,
                   EVENT_STARTSACC,
                   EVENT_ENDSACC,
                   EVENT_STARTFIX,
                   EVENT_ENDFIX,
                   EVENT_FIXUPDATE,
                   EVENT_STARTSAMPLES,
                   EVENT_ENDSAMPLES,
                   EVENT_STARTEVENTS,
                   EVENT_ENDEVENTS,
                   EVENT_MESSAGEEVENT,
                   EVENT_BUTTONEVENT,
                   EVENT_INPUTEVENT,
               )
                # Verify timestamp is reasonable
                ts =
                    UInt32(test[4]) << 24 | UInt32(test[5]) << 16 | UInt32(test[6]) << 8 |
                    UInt32(test[7])
                if ts > 1000000
                    return skipped
                end
            end
        else
            break
        end

        # Not a valid header, skip one byte
        read(io, UInt8)
        skipped += 1
    end
    return skipped
end





# ──────────────────────────────────────────────────────────────────────────── #
# In-memory (byte-array) record parsers
# These work on a pre-loaded Vector{UInt8} with a  pos::Int  cursor.
# No IO dispatch, no eof() syscalls, no seeks — pure array indexing.
# ──────────────────────────────────────────────────────────────────────────── #

"""Read a big-endian UInt16 from a byte vector at a 1-indexed offset."""
@inline function read_be_uint16(data::Vector{UInt8}, offset::Int)
    return UInt16(data[offset]) << 8 | UInt16(data[offset+1])
end

"""Parse a MESSAGEEVENT payload from a byte vector. Returns (text, new_pos)."""
@inline function _msg_bytes(data::Vector{UInt8}, pos::Int)
    n = length(data)
    pos + 2 > n && return ("", pos)
    # extra_byte(1) + zero_byte(1) + msg_len(1) + text(msg_len) + null + padding
    msg_len = Int(data[pos+2])
    text_start = pos + 3
    text_end = text_start + msg_len - 1
    text_end > n && (text_end = n)
    text_len = text_end - text_start + 1
    # Construct String directly from pointer — avoids allocating an intermediate sub-array
    text = unsafe_string(pointer(data, text_start), text_len)
    pos = text_end + 1
    # null terminator
    pos <= n && data[pos] == 0x00 && (pos += 1)
    # padding nulls
    while pos <= n && data[pos] == 0x00
        pos += 1
    end
    # Only allocate a replacement string when nulls are actually present (rare)
    has_null = false
    @inbounds for i = text_start:(text_start+text_len-1)
        if data[i] == 0x00
            has_null = true
            break
        end
    end
    return has_null ? replace(text, '\0' => "") : text, pos
end

"""Parse an INPUT/BUTTON payload from a byte vector. Returns (value, new_pos)."""
function _input_bytes(data::Vector{UInt8}, pos::Int)
    n = length(data)
    pos + 2 > n && return (0, pos)
    val = Int(data[pos+2])   # extra(1) + zero(1) + value(1)
    pos += 4                 # always consume the mandatory trailing pad byte too
    while pos <= n && data[pos] == 0x00
        pos += 1
    end
    return val, pos
end

"""Parse a FEVENT payload from a byte vector. Returns (NamedTuple, new_pos)."""
function _fevent_bytes(data::Vector{UInt8}, pos::Int, event_type::Int)
    payload_size =
        (event_type == EVENT_ENDSACC) ? 48 :
        (event_type == EVENT_ENDFIX || event_type == EVENT_FIXUPDATE) ? 67 : 0
    _zero = (
        sttime=UInt32(0),
        entime=UInt32(0),
        hstx=0.0f0,
        hsty=0.0f0,
        gstx=0.0f0,
        gsty=0.0f0,
        sta=0.0f0,
        henx=0.0f0,
        heny=0.0f0,
        genx=0.0f0,
        geny=0.0f0,
        ena=0.0f0,
        havx=0.0f0,
        havy=0.0f0,
        gavx=0.0f0,
        gavy=0.0f0,
        ava=0.0f0,
        ampl=0.0f0,
        pvel=0.0f0,
        svel=0.0f0,
        evel=0.0f0,
        supd_x=0.0f0,
        eupd_x=0.0f0,
        supd_y=0.0f0,
        eupd_y=0.0f0,
    )
    payload_size == 0 && return _zero, pos
    n = length(data)
    pl = min(pos + payload_size - 1, n)   # last valid index in payload
    # payload[1]=flags, payload[2..5]=entime
    entime = pl >= pos + 4 ? read_be_uint32(data, pos + 1) : UInt32(0)
    if event_type == EVENT_ENDSACC
        # gaze fields at payload offsets 12-25 (1-indexed within payload)
        hstx = pl >= pos + 6 ? Float32(read_be_int16(data, pos + 5)) / 10.0f0 : 0.0f0
        hsty = pl >= pos + 8 ? Float32(read_be_int16(data, pos + 7)) / 10.0f0 : 0.0f0
        gstx = pl >= pos + 12 ? Float32(read_be_int16(data, pos + 11)) / 10.0f0 : 0.0f0
        gsty = pl >= pos + 14 ? Float32(read_be_int16(data, pos + 13)) / 10.0f0 : 0.0f0
        henx = pl >= pos + 18 ? Float32(read_be_int16(data, pos + 17)) / 10.0f0 : 0.0f0
        heny = pl >= pos + 20 ? Float32(read_be_int16(data, pos + 19)) / 10.0f0 : 0.0f0
        genx = pl >= pos + 22 ? Float32(read_be_int16(data, pos + 21)) / 10.0f0 : 0.0f0
        geny = pl >= pos + 24 ? Float32(read_be_int16(data, pos + 23)) / 10.0f0 : 0.0f0
        # Peak velocity at payload offset 35 (int16/10, deg/s)
        pvel = pl >= pos + 36 ? Float32(read_be_int16(data, pos + 35)) / 10.0f0 : 0.0f0
        # Pixels-per-degree (resolution) at payload offsets 43 and 45
        ppd_x = pl >= pos + 44 ? Float32(read_be_int16(data, pos + 43)) / 10.0f0 : 0.0f0
        ppd_y = pl >= pos + 46 ? Float32(read_be_int16(data, pos + 45)) / 10.0f0 : 0.0f0
        # Compute amplitude in degrees from gaze coordinates and ppd
        ppd_mean = (ppd_x + ppd_y) / 2.0f0
        pixel_dist = sqrt((genx - gstx)^2 + (geny - gsty)^2)
        ampl = ppd_mean > 0.0f0 ? pixel_dist / ppd_mean : 0.0f0
        return (
            sttime=UInt32(0),
            entime=entime,
            hstx=hstx,
            hsty=hsty,
            gstx=gstx,
            gsty=gsty,
            sta=0.0f0,
            henx=henx,
            heny=heny,
            genx=genx,
            geny=geny,
            ena=0.0f0,
            havx=hstx,
            havy=hsty,
            gavx=gstx,
            gavy=gsty,
            ava=0.0f0,
            ampl=ampl,
            pvel=pvel,
            svel=0.0f0,
            evel=0.0f0,
            supd_x=ppd_x,
            eupd_x=ppd_x,
            supd_y=ppd_y,
            eupd_y=ppd_y,
        ),
        pos + payload_size
    else  # ENDFIX / FIXUPDATE
        hstx = pl >= pos + 6 ? Float32(read_be_int16(data, pos + 5)) / 10.0f0 : 0.0f0
        hsty = pl >= pos + 8 ? Float32(read_be_int16(data, pos + 7)) / 10.0f0 : 0.0f0
        gavx = pl >= pos + 12 ? Float32(read_be_int16(data, pos + 11)) / 10.0f0 : 0.0f0
        gavy = pl >= pos + 14 ? Float32(read_be_int16(data, pos + 13)) / 10.0f0 : 0.0f0
        ava = pl >= pos + 37 ? Float32(read_be_int16(data, pos + 36)) : 0.0f0
        return (
            sttime=UInt32(0),
            entime=entime,
            hstx=hstx,
            hsty=hsty,
            gstx=gavx,
            gsty=gavy,
            sta=ava,
            henx=hstx,
            heny=hsty,
            genx=gavx,
            geny=gavy,
            ena=ava,
            havx=hstx,
            havy=hsty,
            gavx=gavx,
            gavy=gavy,
            ava=ava,
            ampl=0.0f0,
            pvel=0.0f0,
            svel=0.0f0,
            evel=0.0f0,
            supd_x=0.0f0,
            eupd_x=0.0f0,
            supd_y=0.0f0,
            eupd_y=0.0f0,
        ),
        pos + payload_size
    end
end

"""Parse a RECORDING_INFO block from a byte vector. Returns (EDFRecording|nothing, new_pos)."""
function _recording_bytes(data::Vector{UInt8}, pos::Int, timestamp::UInt32, trial_val::Union{Int,Nothing})
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
        # fallback to eye_byte if sflags are surprisingly empty
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


"""
Push one decoded sample from a byte array into the column accumulators.
`pos` points to the first byte AFTER the already-consumed flags word.
Returns (new_pos, new_timestamp).
"""
@inline function _push_sample_bytes!(
    data::Vector{UInt8},
    pos::Int,
    flags::UInt16,
    sflags::UInt16,
    current_ts::UInt32,
    eye_code::Int,
    in_trial::Bool,
    trial::Int,
    col_time::Vector{UInt32},
    col_gxR::Vector{Float32},
    col_gyR::Vector{Float32},
    col_paR::Vector{Float32},
    col_gxL::Vector{Float32},
    col_gyL::Vector{Float32},
    col_paL::Vector{Float32},
    col_hxR::Vector{Float32},
    col_hyR::Vector{Float32},
    col_hxL::Vector{Float32},
    col_hyL::Vector{Float32},
    col_rx::Vector{Float32},
    col_ry::Vector{Float32},
    col_flags::Vector{UInt16},
    col_input::Vector{UInt16},
    col_status::Vector{UInt16},
    col_trial::Vector{Int},
)

    if (flags & SAMPLE_FULL_TS_FLAG) != 0
        current_ts = read_be_uint32(data, pos)
        pos += 4
    else
        current_ts += UInt32(data[pos])
        pos += 1
    end

    MISS = Int16(-32768)
    NaN32 = Float32(NaN)

    has_left = (sflags & UInt16(0x8000)) != 0
    has_right = (sflags & UInt16(0x4000)) != 0

    pxL = pxR = pyL = pyR = MISS
    hxL = hxR = hyL = hyR = MISS
    gxL = gxR = gyL = gyR = MISS
    paL = paR = MISS
    rx = ry = MISS

    # 0x1000 = PUPILXY
    if (sflags & UInt16(0x1000)) != 0
        if has_left
            pxL = read_be_int16(data, pos)
            pos += 2
            pyL = read_be_int16(data, pos)
            pos += 2
        end
        if has_right
            pxR = read_be_int16(data, pos)
            pos += 2
            pyR = read_be_int16(data, pos)
            pos += 2
        end
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
        input_val = data[pos]
        pos += 1
    end
    if (sflags & UInt16(0x0020)) != 0 # HTARGET
        pos += 2
    end
    if (sflags & UInt16(0x0010)) != 0 # COLOR / HMARKER
        pos += 2
    end

    push!(col_time, current_ts)

    push!(col_gxL, gxL == MISS ? NaN32 : Float32(gxL) / 10.0f0)
    push!(col_gyL, gyL == MISS ? NaN32 : Float32(gyL) / 10.0f0)
    push!(col_paL, paL == MISS ? NaN32 : Float32(paL))
    push!(col_hxL, hxL == MISS ? NaN32 : Float32(hxL))
    push!(col_hyL, hyL == MISS ? NaN32 : Float32(hyL))

    push!(col_gxR, gxR == MISS ? NaN32 : Float32(gxR) / 10.0f0)
    push!(col_gyR, gyR == MISS ? NaN32 : Float32(gyR) / 10.0f0)
    push!(col_paR, paR == MISS ? NaN32 : Float32(paR))
    push!(col_hxR, hxR == MISS ? NaN32 : Float32(hxR))
    push!(col_hyR, hyR == MISS ? NaN32 : Float32(hyR))

    push!(col_rx, rx == MISS ? NaN32 : Float32(rx) / 10.0f0)
    push!(col_ry, ry == MISS ? NaN32 : Float32(ry) / 10.0f0)

    push!(col_flags, UInt16(flags))
    push!(col_input, UInt16(input_val))
    push!(col_status, UInt16(status))
    push!(col_trial, in_trial ? Int(trial) : typemin(Int))

    return pos, current_ts
end
