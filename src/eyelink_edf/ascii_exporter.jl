# EyeLink ASCII (.asc) exporter matching SR Research edf2asc output.

using DataFrames
using Dates
using Printf

# Write decimal values into a pre-allocated Vector{UInt8} at position `pos` and return new `pos`.

"""Write a UInt32 as decimal ASCII digits into buf at pos. Returns new pos."""
@inline function _buf_uint32!(buf::Vector{UInt8}, pos::Int, v::UInt32)
    if v == UInt32(0)
        @inbounds buf[pos] = 0x30
        return pos + 1
    end
    ndigits = 0
    tmp = v
    while tmp > UInt32(0)
        ndigits += 1
        tmp ÷= UInt32(10)
    end
    p = pos + ndigits - 1
    tmp = v
    while tmp > UInt32(0)
        @inbounds buf[p] = UInt8(0x30) + UInt8(tmp % UInt32(10))
        tmp ÷= UInt32(10)
        p -= 1
    end
    return pos + ndigits
end

"""Write a Float32 with 1 decimal place into buf at pos. NaN/Inf → '.'. Returns new pos."""
@inline function _buf_float1!(buf::Vector{UInt8}, pos::Int, v::Float32)
    if !(isfinite(v) && -2.0f8 <= v <= 2.0f8)
        @inbounds buf[pos] = UInt8('.')
        return pos + 1
    end
    vi = round(Int32, v * 10.0f0)
    if vi < Int32(0)
        @inbounds buf[pos] = UInt8('-')
        pos += 1
        vi = -vi
    end
    pos = _buf_uint32!(buf, pos, UInt32(vi ÷ Int32(10)))
    @inbounds buf[pos] = UInt8('.')
    @inbounds buf[pos+1] = UInt8(0x30) + UInt8(vi % Int32(10))
    return pos + 2
end

"""Write a Float32 right-aligned in `width` chars into buf at pos. Returns new pos."""
@inline function _buf_float1_field!(buf::Vector{UInt8}, pos::Int, v::Float32, width::Int)
    w = _float1_width(v)
    spaces = width - w
    @inbounds for _ = 1:spaces
        buf[pos] = UInt8(' ')
        pos += 1
    end
    return _buf_float1!(buf, pos, v)
end

"""Return the number of decimal digits in a Float32 value (rounded to 1 dp), minimum 1."""
@inline function _float1_width(v::Float32)::Int
    !(isfinite(v) && -2.0f8 <= v <= 2.0f8) && return 1  # "."
    vi = round(Int32, v * 10.0f0)
    neg = vi < Int32(0) ? 1 : 0
    int_part = abs(vi) ÷ Int32(10)
    d = 1
    x = int_part
    while x >= 10
        x ÷= 10
        d += 1
    end
    return neg + d + 2  # sign? + digits + "." + 1 decimal
end

@inline function _u64_ndigits(v::UInt64)::Int
    v < UInt64(10) && return 1
    v < UInt64(100) && return 2
    v < UInt64(1_000) && return 3
    v < UInt64(10_000) && return 4
    v < UInt64(100_000) && return 5
    d = 6
    x = v ÷ UInt64(100_000)
    while x >= UInt64(10)
        x ÷= UInt64(10)
        d += 1
    end
    return d
end

@inline function _buf_uint64_known!(buf::Vector{UInt8}, pos::Int, v::UInt64, ndigits::Int)
    if v == UInt64(0)
        @inbounds buf[pos] = 0x30
        return pos + 1
    end
    p = pos + ndigits - 1
    tmp = v
    @inbounds while tmp > UInt64(0)
        buf[p] = UInt8(0x30) + UInt8(tmp % UInt64(10))
        tmp ÷= UInt64(10)
        p -= 1
    end
    return pos + ndigits
end

@inline function _buf_int_field!(buf::Vector{UInt8}, pos::Int, v::Int, width::Int)
    neg = v < 0
    u = UInt64(abs(Int64(v)))
    nd = _u64_ndigits(u)
    spaces = width - ((neg ? 1 : 0) + nd)
    @inbounds for _ = 1:spaces
        buf[pos] = UInt8(' ')
        pos += 1
    end
    if neg
        @inbounds buf[pos] = UInt8('-')
        pos += 1
    end
    return _buf_uint64_known!(buf, pos, u, nd)
end

@inline function _buf_f64_0dp_field!(buf::Vector{UInt8}, pos::Int, v::Float64, width::Int)
    if !(isfinite(v) && -1.0e15 <= v <= 1.0e15)
        s = @sprintf("%6.0f", v)
        GC.@preserve buf s unsafe_copyto!(pointer(buf, pos), pointer(s), sizeof(s))
        return pos + sizeof(s)
    end
    r = round(v, digits = 0)
    neg = signbit(r)
    u = round(UInt64, abs(r))
    nd = _u64_ndigits(u)
    spaces = width - ((neg ? 1 : 0) + nd)
    @inbounds for _ = 1:spaces
        buf[pos] = UInt8(' ')
        pos += 1
    end
    if neg
        @inbounds buf[pos] = UInt8('-')
        pos += 1
    end
    return _buf_uint64_known!(buf, pos, u, nd)
end

@inline function _buf_f64_1dp_field!(buf::Vector{UInt8}, pos::Int, v::Float64, width::Int)
    if !(isfinite(v) && -1.0e14 <= v <= 1.0e14)
        s = @sprintf("%6.1f", v)
        GC.@preserve buf s unsafe_copyto!(pointer(buf, pos), pointer(s), sizeof(s))
        return pos + sizeof(s)
    end
    r = round(v, digits = 1)
    neg = signbit(r)
    mag = round(UInt64, abs(r) * 10.0)
    ip = mag ÷ UInt64(10)
    frac = mag % UInt64(10)
    nd = _u64_ndigits(ip)
    spaces = width - ((neg ? 1 : 0) + nd + 2)
    @inbounds for _ = 1:spaces
        buf[pos] = UInt8(' ')
        pos += 1
    end
    if neg
        @inbounds buf[pos] = UInt8('-')
        pos += 1
    end
    pos = _buf_uint64_known!(buf, pos, ip, nd)
    @inbounds buf[pos] = UInt8('.')
    @inbounds buf[pos+1] = UInt8(0x30) + UInt8(frac)
    return pos + 2
end

@inline function _buf_f64_2dp_field!(buf::Vector{UInt8}, pos::Int, v::Float64, width::Int)
    if !(isfinite(v) && -1.0e13 <= v <= 1.0e13)
        s = @sprintf("%6.2f", v)
        GC.@preserve buf s unsafe_copyto!(pointer(buf, pos), pointer(s), sizeof(s))
        return pos + sizeof(s)
    end
    r = round(v, digits = 2)
    neg = signbit(r)
    mag = round(UInt64, abs(r) * 100.0)
    ip = mag ÷ UInt64(100)
    f1 = (mag ÷ UInt64(10)) % UInt64(10)
    f2 = mag % UInt64(10)
    nd = _u64_ndigits(ip)
    spaces = width - ((neg ? 1 : 0) + nd + 3)
    @inbounds for _ = 1:spaces
        buf[pos] = UInt8(' ')
        pos += 1
    end
    if neg
        @inbounds buf[pos] = UInt8('-')
        pos += 1
    end
    pos = _buf_uint64_known!(buf, pos, ip, nd)
    @inbounds buf[pos] = UInt8('.')
    @inbounds buf[pos+1] = UInt8(0x30) + UInt8(f1)
    @inbounds buf[pos+2] = UInt8(0x30) + UInt8(f2)
    return pos + 3
end

mutable struct _AscEventArena
    buf::Vector{UInt8}
    used::Int
    meta::Vector{NTuple{4,UInt32}} # (timestamp, priority, byte_offset, byte_len)
end

function _AscEventArena(est_events::Int)
    cap_ev = max(est_events, 256)
    return _AscEventArena(
        Vector{UInt8}(undef, max(cap_ev * 48, 8192)),
        0,
        sizehint!(NTuple{4,UInt32}[], cap_ev),
    )
end

@noinline function _grow_asc_arena!(arena::_AscEventArena, needed::Int)
    new_cap = max(length(arena.buf) * 2, needed, 8192)
    resize!(arena.buf, new_cap)
    return nothing
end

@inline function _arena_reserve!(arena::_AscEventArena, extra::Int)::Int
    need = arena.used + extra
    need > length(arena.buf) && _grow_asc_arena!(arena, need)
    return arena.used + 1
end

@inline function _arena_commit!(arena::_AscEventArena, ts::UInt32, prio::UInt32, start_pos::Int, end_pos_excl::Int)
    len = end_pos_excl - start_pos
    arena.used = end_pos_excl - 1
    push!(arena.meta, (ts, prio, UInt32(start_pos), UInt32(len)))
    return nothing
end

@inline function _arena_push_str!(arena::_AscEventArena, ts::UInt32, prio::UInt32, s::AbstractString)
    nb = sizeof(s)
    p = _arena_reserve!(arena, nb)
    if nb > 0
        GC.@preserve arena s unsafe_copyto!(pointer(arena.buf, p), pointer(s), nb)
    end
    _arena_commit!(arena, ts, prio, p, p + nb)
    return nothing
end

@inline function _buf_copy_str!(buf::Vector{UInt8}, pos::Int, s::String)
    nb = sizeof(s)
    @inbounds for k = 1:nb
        buf[pos+k-1] = codeunit(s, k)
    end
    return pos + nb
end

@inline function _flush_chunk!(io::IO_T, buf::Vector{UInt8}, pos::Int) where {IO_T<:IO}
    if pos > 1
        GC.@preserve buf unsafe_write(io, pointer(buf), UInt(pos - 1))
    end
    return 1
end

@inline function _buf_arena_nl!(
    io::IO_T,
    buf::Vector{UInt8},
    pos::Int,
    arena_buf::Vector{UInt8},
    off::Int,
    nb::Int,
) where {IO_T<:IO}
    if pos + nb + 1 > length(buf)
        pos = _flush_chunk!(io, buf, pos)
        if nb + 2 > length(buf)
            GC.@preserve arena_buf unsafe_write(io, pointer(arena_buf, off), UInt(nb))
            write(io, 0x0a)
            return pos
        end
    end
    if nb > 0
        GC.@preserve buf arena_buf unsafe_copyto!(pointer(buf, pos), pointer(arena_buf, off), nb)
        pos += nb
    end
    @inbounds buf[pos] = 0x0a
    return pos + 1
end

function _stream_ascii_samples!(
    io::IO_T,
    chunk_buf::Vector{UInt8},
    valid_idx::Vector{Int},
    times::Vector{UInt32},
    arena_buf::Vector{UInt8},
    ev_meta::Vector{NTuple{4,UInt32}},
    gx1::Vector{Float32},
    gy1::Vector{Float32},
    pa1::Vector{Float32},
    gx2::Vector{Float32},
    gy2::Vector{Float32},
    pa2::Vector{Float32},
    has_eye1::Bool,
    is_binocular::Bool,
) where {IO_T<:IO}
    n_ev = length(ev_meta)
    ei = 1
    cpos = 1
    flush_thresh = length(chunk_buf) - 160

    @inbounds for i in valid_idx
        ts = times[i]
        # Events strictly before this sample's timestamp
        while ei <= n_ev && ev_meta[ei][1] < ts
            m = ev_meta[ei]
            cpos = _buf_arena_nl!(io, chunk_buf, cpos, arena_buf, Int(m[3]), Int(m[4]))
            ei += 1
        end
        # Priority-0 events at this timestamp (START, MSG, INPUT precede sample)
        while ei <= n_ev && ev_meta[ei][1] == ts && ev_meta[ei][2] == UInt32(0)
            m = ev_meta[ei]
            cpos = _buf_arena_nl!(io, chunk_buf, cpos, arena_buf, Int(m[3]), Int(m[4]))
            ei += 1
        end
        if cpos > flush_thresh
            cpos = _flush_chunk!(io, chunk_buf, cpos)
        end
        cpos = _buf_uint32!(chunk_buf, cpos, ts)
        if has_eye1
            chunk_buf[cpos] = UInt8('\t')
            cpos += 1
            cpos = _buf_float1_field!(chunk_buf, cpos, gx1[i], 7)
            chunk_buf[cpos] = UInt8('\t')
            cpos += 1
            cpos = _buf_float1_field!(chunk_buf, cpos, gy1[i], 7)
            chunk_buf[cpos] = UInt8('\t')
            cpos += 1
            cpos = _buf_float1_field!(chunk_buf, cpos, pa1[i], 7)
            if is_binocular
                chunk_buf[cpos] = UInt8('\t')
                cpos += 1
                cpos = _buf_float1_field!(chunk_buf, cpos, gx2[i], 7)
                chunk_buf[cpos] = UInt8('\t')
                cpos += 1
                cpos = _buf_float1_field!(chunk_buf, cpos, gy2[i], 7)
                chunk_buf[cpos] = UInt8('\t')
                cpos += 1
                cpos = _buf_float1_field!(chunk_buf, cpos, pa2[i], 7)
            end
        end
        chunk_buf[cpos] = UInt8('\t')
        chunk_buf[cpos+1] = UInt8('.')
        chunk_buf[cpos+2] = UInt8('.')
        chunk_buf[cpos+3] = UInt8('.')
        chunk_buf[cpos+4] = UInt8('\n')
        cpos += 5

        # Priority-1 events at this timestamp (EFIX, ESACC, EBLINK follow sample)
        while ei <= n_ev && ev_meta[ei][1] == ts && ev_meta[ei][2] == UInt32(1)
            m = ev_meta[ei]
            cpos = _buf_arena_nl!(io, chunk_buf, cpos, arena_buf, Int(m[3]), Int(m[4]))
            ei += 1
        end
    end

    @inbounds while ei <= n_ev
        m = ev_meta[ei]
        cpos = _buf_arena_nl!(io, chunk_buf, cpos, arena_buf, Int(m[3]), Int(m[4]))
        ei += 1
    end
    _flush_chunk!(io, chunk_buf, cpos)
    return nothing
end

function _coerce_f32_vec(c::AbstractVector)
    c isa Vector{Float32} && return c
    out = Vector{Float32}(undef, length(c))
    @inbounds for i in eachindex(c)
        v = c[i]
        out[i] = (isnothing(v) || ismissing(v)) ? Float32(NaN) : Float32(v)
    end
    return out
end

function _default_asc_output(filename::AbstractString)::String
    isempty(filename) && error("output_file must be specified when edf.filename is empty.")
    if occursin(r"\.(edf|asc)$"i, filename)
        return replace(filename, r"\.(edf|asc)$"i => "_exported.asc")
    end
    return filename * "_exported.asc"
end

"""
    write_et_ascii(edf::EDFFile, output_file::String = _default_asc_output(edf.filename); 
                   include_samples::Bool = true,
                   include_events::Bool = true,
                   include_messages::Bool = true)

Export an EDF file to ASCII format identical to SR Research's edf2asc tool.

# Arguments
- `edf`: The EDFFile object to export
- `output_file`: Path to the output .asc file (defaults to filename with _exported.asc)
- `include_samples`: Whether to include sample data (default: true)
- `include_events`: Whether to include event data (default: true)
- `include_messages`: Whether to include message data (default: true)

# Returns
- `Nothing`: Writes the ASCII file to disk
"""
function write_et_ascii(
    edf::EDFFile,
    output_file::String = _default_asc_output(edf.filename);
    include_samples::Bool = true,
    include_events::Bool = true,
    include_messages::Bool = true,
)
    if !isempty(edf.filename) && abspath(output_file) == abspath(edf.filename)
        error("Refusing to overwrite source file in-place: $output_file")
    end
    open(output_file, "w") do io
        write_header(io, edf)
        if include_messages || include_events || include_samples
            write_chronological_data(
                io,
                edf,
                include_messages,
                include_events,
                include_samples,
            )
        end
    end
    return nothing
end

"""
    write_header(io::IO, edf::EDFFile)

Write the ASCII file header with conversion info and metadata.
"""
function write_header(io::IO, edf::EDFFile)
    println(io, "** CONVERTED FROM $(basename(edf.filename)) using EyeFun.jl on $(now())")
    # Prefix unprefixed raw EDF preamble lines ("DATE: ...", "TYPE: ...") with "** " like edf2asc
    for line in split(edf.preamble, '\n')
        clean = rstrip(line, '\r')
        isempty(strip(clean)) && continue
        startswith(clean, "ENDP") && continue          # preamble end marker
        startswith(clean, "SR_RESEARCH") && continue   # internal EDF file magic, not written by edf2asc
        if startswith(clean, "**")
            println(io, clean)                         # already prefixed
        else
            println(io, "** $(clean)")
        end
    end
    println(io, "**")
    println(io)
end

"""Map recording eye code to the long name used in START/EVENTS/SAMPLES header lines."""
function _eye_long(eye_code::Integer)
    eye_code == EYE_RIGHT && return "RIGHT"
    eye_code == EYE_BINOCULAR && return "LEFT\tRIGHT"  # tab-separated as in reference
    return "LEFT"  # EYE_LEFT or unknown
end

"""Map recording eye code to the single-letter used in event lines (SFIX, ESACC, ...)."""
function _eye_letter(eye_code::Integer)
    eye_code == EYE_RIGHT && return "R"
    return "L"
end

"""Map pupil_type code to the keyword used in the PUPIL line."""
function _pupil_keyword(pupil_type::Integer)
    pupil_type == PUPIL_DIAMETER && return "DIAMETER"
    return "AREA"
end

function _compute_min_rec_time_typed(
    times::AbstractVector,
    states::AbstractVector,
    rates::AbstractVector,
)::UInt32
    min_valid = typemax(UInt32)
    min_any = typemax(UInt32)
    @inbounds for i in eachindex(times)
        ti = times[i]
        ismissing(ti) && continue
        t = UInt32(ti)
        t < min_any && (min_any = t)
        st = states[i]
        sr = rates[i]
        if !ismissing(st) && st == RECORDING_START && !ismissing(sr) && 100.0f0 <= sr <= 2000.0f0
            t < min_valid && (min_valid = t)
        end
    end
    return min_valid != typemax(UInt32) ? min_valid :
           (min_any != typemax(UInt32) ? min_any : UInt32(0))
end

function _compute_max_valid_ts_typed(
    times::AbstractVector,
    states::AbstractVector,
    min_rec_time::UInt32,
)::UInt32
    max_end = UInt32(0)
    found_end = false
    @inbounds for i in eachindex(times)
        st = states[i]
        ti = times[i]
        if !ismissing(st) && st == RECORDING_END && !ismissing(ti)
            t = UInt32(ti)
            if t > min_rec_time
                found_end = true
                t > max_end && (max_end = t)
            end
        end
    end
    if found_end
        return UInt32(min(UInt64(max_end) + 5_000, typemax(UInt32)))
    end
    return UInt32(min(UInt64(min_rec_time) + 3_600_000, typemax(UInt32)))
end

function _max_u32_col(col::AbstractVector)::UInt32
    mx = UInt32(0)
    @inbounds for i in eachindex(col)
        v = col[i]
        ismissing(v) && continue
        u = UInt32(v)
        u > mx && (mx = u)
    end
    return mx
end

@inline _eye_byte(eye_code::Integer)::UInt8 = eye_code == EYE_RIGHT ? UInt8('R') : UInt8('L')

function _append_rec_start_lines!(
    arena::_AscEventArena,
    rec_times::AbstractVector,
    rec_states::AbstractVector,
    rec_rates::AbstractVector,
    rec_eyes::AbstractVector,
    rec_ptypes::AbstractVector,
)
    last_start_ts = typemax(UInt32)
    @inbounds for i in eachindex(rec_times)
        st = rec_states[i]
        (ismissing(st) || st != RECORDING_START) && continue
        sr_i = rec_rates[i]
        (ismissing(sr_i) || sr_i < 100.0f0 || sr_i > 2000.0f0) && continue
        t = UInt32(rec_times[i])
        t == last_start_ts && continue
        last_start_ts = t

        eye_code = Int(rec_eyes[i])
        eye_long = _eye_long(eye_code)
        pupil_kw = _pupil_keyword(Int(rec_ptypes[i]))
        rate_str = isinteger(sr_i) ? "$(Int(sr_i)).00" : @sprintf("%.2f", sr_i)
        _arena_push_str!(arena, t, UInt32(0), "START\t$(t) \t$(eye_long)\tSAMPLES\tEVENTS")
        _arena_push_str!(arena, t, UInt32(0), "PRESCALER\t1")
        _arena_push_str!(arena, t, UInt32(0), "VPRESCALER\t1")
        _arena_push_str!(arena, t, UInt32(0), "PUPIL\t$(pupil_kw)")
        _arena_push_str!(
            arena,
            t,
            UInt32(0),
            "EVENTS\tGAZE\t$(eye_long)\tRATE\t$(rate_str)\tTRACKING\tCR\tFILTER\t2",
        )
        _arena_push_str!(
            arena,
            t,
            UInt32(0),
            "SAMPLES\tGAZE\t$(eye_long)\tRATE\t$(rate_str)\tTRACKING\tCR\tFILTER\t2",
        )
    end
    return nothing
end

@inline function _msg_ascii_status(s::AbstractString)::Int
    # 1 = clean single-line printable ASCII; 0 = needs slow path (Unicode / newline / nul); -1 = non-printable
    nb = ncodeunits(s)
    @inbounds for i = 1:nb
        b = codeunit(s, i)
        if (0x20 <= b <= 0x7e) || b == 0x09
            continue
        elseif b == 0x0a || b == 0x00 || b >= 0x80
            return 0
        else
            return -1
        end
    end
    return 1
end

function _append_raw_event_lines!(
    arena::_AscEventArena,
    ev_st::AbstractVector{<:Integer},
    ev_type::AbstractVector{<:Integer},
    ev_eye::AbstractVector{<:Integer},
    has_eye::Bool,
    ev_inp::AbstractVector{<:Integer},
    has_inp::Bool,
    ev_msg::AbstractVector{<:AbstractString},
    include_events::Bool,
    include_messages::Bool,
    min_rec_time::UInt32,
    max_valid_ts::UInt32,
)
    @inbounds for idx in eachindex(ev_st)
        t = UInt32(ev_st[idx])
        t_et = ev_type[idx]

        if include_events &&
           t_et == EVENT_INPUTEVENT &&
           has_inp &&
           ev_inp[idx] > 0 &&
           t > UInt32(0) &&
           t <= max_valid_ts
            start_p = _arena_reserve!(arena, 32)
            buf = arena.buf
            p = _buf_copy_str!(buf, start_p, "INPUT\t")
            p = _buf_uint32!(buf, p, t)
            buf[p] = UInt8('\t')
            p = _buf_uint32!(buf, p + 1, UInt32(ev_inp[idx]))
            _arena_commit!(arena, t, UInt32(0), start_p, p)
        end

        if include_messages &&
           t_et == EVENT_MESSAGEEVENT &&
           t > UInt32(0) &&
           t <= max_valid_ts
            raw_m = ev_msg[idx]
            st_code = _msg_ascii_status(raw_m)
            if st_code == 1
                nb = sizeof(raw_m)
                start_p = _arena_reserve!(arena, 20 + nb)
                buf = arena.buf
                p = _buf_copy_str!(buf, start_p, "MSG\t")
                p = _buf_uint32!(buf, p, t)
                buf[p] = UInt8(' ')
                p += 1
                if nb > 0
                    GC.@preserve buf raw_m unsafe_copyto!(pointer(buf, p), pointer(raw_m), nb)
                    p += nb
                end
                _arena_commit!(arena, t, UInt32(0), start_p, p)
            elseif st_code == 0
                clean = occursin('\0', raw_m) ? replace(raw_m, '\0' => "") : raw_m
                if all(c -> isprint(c) || c == '\n' || c == '\t', clean)
                    if !occursin('\n', clean)
                        nb = sizeof(clean)
                        start_p = _arena_reserve!(arena, 20 + nb)
                        buf = arena.buf
                        p = _buf_copy_str!(buf, start_p, "MSG\t")
                        p = _buf_uint32!(buf, p, t)
                        buf[p] = UInt8(' ')
                        p += 1
                        if nb > 0
                            GC.@preserve buf clean unsafe_copyto!(pointer(buf, p), pointer(clean), nb)
                            p += nb
                        end
                        _arena_commit!(arena, t, UInt32(0), start_p, p)
                    else
                        for (i, ln) in enumerate(eachsplit(clean, '\n'))
                            if i == 1
                                nb = sizeof(ln)
                                start_p = _arena_reserve!(arena, 20 + nb)
                                buf = arena.buf
                                p = _buf_copy_str!(buf, start_p, "MSG\t")
                                p = _buf_uint32!(buf, p, t)
                                buf[p] = UInt8(' ')
                                p += 1
                                if nb > 0
                                    GC.@preserve buf ln unsafe_copyto!(pointer(buf, p), pointer(ln), nb)
                                    p += nb
                                end
                                _arena_commit!(arena, t, UInt32(0), start_p, p)
                            elseif !isempty(strip(ln))
                                _arena_push_str!(arena, t, UInt32(0), ln)
                            end
                        end
                    end
                end
            end
        end

        if include_events && t <= max_valid_ts && t >= min_rec_time
            if t_et == EVENT_STARTSACC || t_et == EVENT_STARTFIX || t_et == EVENT_STARTBLINK
                eb = has_eye ? _eye_byte(ev_eye[idx]) : UInt8('L')
                start_p = _arena_reserve!(arena, 24)
                buf = arena.buf
                if t_et == EVENT_STARTSACC
                    p = _buf_copy_str!(buf, start_p, "SSACC ")
                    buf[p] = eb
                    buf[p+1] = UInt8(' ')
                    buf[p+2] = UInt8(' ')
                    p += 3
                elseif t_et == EVENT_STARTFIX
                    p = _buf_copy_str!(buf, start_p, "SFIX ")
                    buf[p] = eb
                    buf[p+1] = UInt8(' ')
                    buf[p+2] = UInt8(' ')
                    buf[p+3] = UInt8(' ')
                    p += 4
                else
                    p = _buf_copy_str!(buf, start_p, "SBLINK ")
                    buf[p] = eb
                    buf[p+1] = UInt8(' ')
                    p += 2
                end
                p = _buf_uint32!(buf, p, t)
                _arena_commit!(arena, t, UInt32(0), start_p, p)
            end
        end
    end
    return nothing
end

function _append_sacc_lines!(
    arena::_AscEventArena,
    s_st::AbstractVector{<:Integer},
    s_en::AbstractVector{<:Integer},
    s_eye::AbstractVector{<:Integer},
    has_s_eye::Bool,
    s_gstx::AbstractVector{<:Real},
    s_gsty::AbstractVector{<:Real},
    s_genx::AbstractVector{<:Real},
    s_geny::AbstractVector{<:Real},
    s_ampl::AbstractVector{<:Real},
    s_pvel::AbstractVector{<:Real},
    min_rec_time::UInt32,
    max_valid_ts::UInt32,
)
    @inbounds for idx in eachindex(s_st)
        st_i = UInt32(s_st[idx])
        en_i = UInt32(s_en[idx])
        (st_i >= min_rec_time && en_i <= max_valid_ts) || continue
        eb = has_s_eye ? _eye_byte(s_eye[idx]) : UInt8('L')
        dur = en_i - st_i + UInt32(1)
        gstx = round(!isempty(s_gstx) ? Float64(s_gstx[idx]) : 0.0, digits = 1)
        gsty = round(!isempty(s_gsty) ? Float64(s_gsty[idx]) : 0.0, digits = 1)
        genx = round(!isempty(s_genx) ? Float64(s_genx[idx]) : 0.0, digits = 1)
        geny = round(!isempty(s_geny) ? Float64(s_geny[idx]) : 0.0, digits = 1)
        stored_ampl = !isempty(s_ampl) ? Float64(s_ampl[idx]) : 0.0
        stored_pvel = !isempty(s_pvel) ? Float64(s_pvel[idx]) : 0.0
        ampl =
            stored_ampl != 0.0 ? stored_ampl :
            round(sqrt((genx - gstx)^2 + (geny - gsty)^2) / 10.0, digits = 2)
        pvel = round(stored_pvel, digits = 0)

        start_p = _arena_reserve!(arena, 128)
        buf = arena.buf
        p = _buf_copy_str!(buf, start_p, "ESACC ")
        buf[p] = eb
        buf[p+1] = UInt8(' ')
        buf[p+2] = UInt8(' ')
        p = _buf_uint32!(buf, p + 3, st_i)
        buf[p] = UInt8('\t')
        p = _buf_uint32!(buf, p + 1, en_i)
        buf[p] = UInt8('\t')
        p = _buf_uint32!(buf, p + 1, dur)
        buf[p] = UInt8('\t')
        p = _buf_f64_1dp_field!(buf, p + 1, gstx, 6)
        buf[p] = UInt8('\t')
        p = _buf_f64_1dp_field!(buf, p + 1, gsty, 6)
        buf[p] = UInt8('\t')
        p = _buf_f64_1dp_field!(buf, p + 1, genx, 6)
        buf[p] = UInt8('\t')
        p = _buf_f64_1dp_field!(buf, p + 1, geny, 6)
        buf[p] = UInt8('\t')
        p = _buf_f64_2dp_field!(buf, p + 1, ampl, 6)
        buf[p] = UInt8('\t')
        p = _buf_f64_0dp_field!(buf, p + 1, pvel, 6)
        _arena_commit!(arena, en_i, UInt32(1), start_p, p)
    end
    return nothing
end

function _append_fix_lines!(
    arena::_AscEventArena,
    f_st::AbstractVector{<:Integer},
    f_en::AbstractVector{<:Integer},
    f_eye::AbstractVector{<:Integer},
    has_f_eye::Bool,
    f_gavx::AbstractVector{<:Real},
    f_gavy::AbstractVector{<:Real},
    f_ava::AbstractVector{<:Real},
    min_rec_time::UInt32,
    max_valid_ts::UInt32,
)
    @inbounds for idx in eachindex(f_st)
        st_i = UInt32(f_st[idx])
        en_i = UInt32(f_en[idx])
        (st_i >= min_rec_time && en_i <= max_valid_ts) || continue
        eb = has_f_eye ? _eye_byte(f_eye[idx]) : UInt8('L')
        dur = en_i - st_i + UInt32(1)
        gavx = round(!isempty(f_gavx) ? Float64(f_gavx[idx]) : 0.0, digits = 1)
        gavy = round(!isempty(f_gavy) ? Float64(f_gavy[idx]) : 0.0, digits = 1)
        ava = !isempty(f_ava) && isfinite(f_ava[idx]) ? round(Int, Float64(f_ava[idx])) : 0

        start_p = _arena_reserve!(arena, 96)
        buf = arena.buf
        p = _buf_copy_str!(buf, start_p, "EFIX ")
        buf[p] = eb
        buf[p+1] = UInt8(' ')
        buf[p+2] = UInt8(' ')
        buf[p+3] = UInt8(' ')
        p = _buf_uint32!(buf, p + 4, st_i)
        buf[p] = UInt8('\t')
        p = _buf_uint32!(buf, p + 1, en_i)
        buf[p] = UInt8('\t')
        p = _buf_uint32!(buf, p + 1, dur)
        buf[p] = UInt8('\t')
        p = _buf_f64_1dp_field!(buf, p + 1, gavx, 6)
        buf[p] = UInt8('\t')
        p = _buf_f64_1dp_field!(buf, p + 1, gavy, 6)
        buf[p] = UInt8('\t')
        p = _buf_int_field!(buf, p + 1, ava, 6)
        _arena_commit!(arena, en_i, UInt32(1), start_p, p)
    end
    return nothing
end

function _append_blink_lines!(
    arena::_AscEventArena,
    b_st::AbstractVector{<:Integer},
    b_en::AbstractVector{<:Integer},
    b_eye::AbstractVector{<:Integer},
    has_b_eye::Bool,
    min_rec_time::UInt32,
    max_valid_ts::UInt32,
)
    @inbounds for idx in eachindex(b_st)
        st_i = UInt32(b_st[idx])
        en_i = UInt32(b_en[idx])
        (st_i >= min_rec_time && en_i <= max_valid_ts) || continue
        eb = has_b_eye ? _eye_byte(b_eye[idx]) : UInt8('L')
        dur = en_i - st_i + UInt32(1)

        start_p = _arena_reserve!(arena, 64)
        buf = arena.buf
        p = _buf_copy_str!(buf, start_p, "EBLINK ")
        buf[p] = eb
        buf[p+1] = UInt8(' ')
        p = _buf_uint32!(buf, p + 2, st_i)
        buf[p] = UInt8('\t')
        p = _buf_uint32!(buf, p + 1, en_i)
        buf[p] = UInt8('\t')
        p = _buf_uint32!(buf, p + 1, dur)
        _arena_commit!(arena, en_i, UInt32(1), start_p, p)
    end
    return nothing
end

"""
    write_chronological_data(io, edf, include_messages, include_events, include_samples)

Stream events and samples from `edf` to `io` in chronological timestamp order.
"""
function write_chronological_data(
    io::IO_T,
    edf::EDFFile,
    include_messages::Bool,
    include_events::Bool,
    include_samples::Bool,
) where {IO_T<:IO}
    rec = edf.recordings
    min_rec_time =
        nrow(rec) > 0 ?
        _compute_min_rec_time_typed(rec[!, :time], rec[!, :state], rec[!, :sample_rate]) :
        UInt32(0)
    max_valid_ts =
        nrow(rec) > 0 ?
        _compute_max_valid_ts_typed(rec[!, :time], rec[!, :state], min_rec_time) :
        UInt32(min(UInt64(min_rec_time) + 3_600_000, typemax(UInt32)))

    evs = edf.events
    arena = _AscEventArena(nrow(evs) + 32)

    if include_events && nrow(rec) > 0
        _append_rec_start_lines!(
            arena,
            rec[!, :time],
            rec[!, :state],
            rec[!, :sample_rate],
            rec[!, :eye],
            rec[!, :pupil_type],
        )
    end

    if nrow(evs) > 0
        has_eye = hasproperty(evs, :eye)
        has_inp = hasproperty(evs, :input)
        _append_raw_event_lines!(
            arena,
            evs[!, :sttime],
            evs[!, :type],
            has_eye ? evs[!, :eye] : Int16[],
            has_eye,
            has_inp ? evs[!, :input] : UInt16[],
            has_inp,
            evs[!, :message],
            include_events,
            include_messages,
            min_rec_time,
            max_valid_ts,
        )
    end

    if include_events
        sacc_df = parse_saccades(evs)
        if nrow(sacc_df) > 0
            has_s_eye = hasproperty(sacc_df, :eye)
            _append_sacc_lines!(
                arena,
                sacc_df[!, :sttime],
                sacc_df[!, :entime],
                has_s_eye ? sacc_df[!, :eye] : Int16[],
                has_s_eye,
                hasproperty(sacc_df, :gstx) ? sacc_df[!, :gstx] : Float32[],
                hasproperty(sacc_df, :gsty) ? sacc_df[!, :gsty] : Float32[],
                hasproperty(sacc_df, :genx) ? sacc_df[!, :genx] : Float32[],
                hasproperty(sacc_df, :geny) ? sacc_df[!, :geny] : Float32[],
                hasproperty(sacc_df, :ampl) ? sacc_df[!, :ampl] : Float32[],
                hasproperty(sacc_df, :pvel) ? sacc_df[!, :pvel] : Float32[],
                min_rec_time,
                max_valid_ts,
            )
        end
        fix_df = parse_fixations(evs)
        if nrow(fix_df) > 0
            has_f_eye = hasproperty(fix_df, :eye)
            _append_fix_lines!(
                arena,
                fix_df[!, :sttime],
                fix_df[!, :entime],
                has_f_eye ? fix_df[!, :eye] : Int16[],
                has_f_eye,
                hasproperty(fix_df, :gavx) ? fix_df[!, :gavx] : Float32[],
                hasproperty(fix_df, :gavy) ? fix_df[!, :gavy] : Float32[],
                hasproperty(fix_df, :ava) ? fix_df[!, :ava] : Float32[],
                min_rec_time,
                max_valid_ts,
            )
        end
        blink_df = parse_blinks(evs; samples = edf.samples)
        if nrow(blink_df) > 0
            has_b_eye = hasproperty(blink_df, :eye)
            _append_blink_lines!(
                arena,
                blink_df[!, :sttime],
                blink_df[!, :entime],
                has_b_eye ? blink_df[!, :eye] : Int16[],
                has_b_eye,
                min_rec_time,
                max_valid_ts,
            )
        end
    end

    ev_meta = arena.meta
    sort!(ev_meta; by = x -> (x[1], x[2]))

    # END marker added after sort so it just needs inserting at sorted position
    if include_events
        end_ts = if !isnothing(edf.samples) && nrow(edf.samples) > 0
            UInt32(min(UInt64(_max_u32_col(edf.samples[!, :time])) + 1, typemax(UInt32)))
        elseif nrow(rec) > 0
            _max_u32_col(rec[!, :time])
        else
            UInt32(0)
        end
        start_p = _arena_reserve!(arena, 48)
        p = _buf_copy_str!(arena.buf, start_p, "END\t")
        p = _buf_uint32!(arena.buf, p, end_ts)
        p = _buf_copy_str!(arena.buf, p, "\tSAMPLES\tEVENTS\tRES\t0.0\t0.0")
        arena.used = p - 1
        end_entry = (end_ts, UInt32(0), UInt32(start_p), UInt32(p - start_p))
        insert_pos = searchsortedfirst(ev_meta, end_entry; by = x -> (x[1], x[2]))
        insert!(ev_meta, insert_pos, end_entry)
    end

    n_sam = !isnothing(edf.samples) ? nrow(edf.samples) : 0
    chunk_buf = Vector{UInt8}(undef, 65536)

    if include_samples && !isnothing(edf.samples) && n_sam > 0
        sam = edf.samples
        has_gxL = hasproperty(sam, :gxL)
        has_gxR = hasproperty(sam, :gxR)
        raw_t = sam[!, :time]
        times = raw_t isa Vector{UInt32} ? raw_t : _as_u32_vec(raw_t)

        empty_f32 = Float32[]
        gxL_v = has_gxL ? _coerce_f32_vec(sam[!, :gxL]) : empty_f32
        gxR_v = has_gxR ? _coerce_f32_vec(sam[!, :gxR]) : empty_f32
        use_left = has_gxL && any(!isnan, gxL_v)
        use_right = has_gxR && any(!isnan, gxR_v)
        is_binocular = use_left && use_right
        has_eye1 = use_left || use_right

        gx1 = use_left ? gxL_v : (use_right ? gxR_v : empty_f32)
        gy1 =
            use_left ? _coerce_f32_vec(sam[!, :gyL]) :
            (use_right ? _coerce_f32_vec(sam[!, :gyR]) : empty_f32)
        pa1 =
            use_left ? _coerce_f32_vec(sam[!, :paL]) :
            (use_right ? _coerce_f32_vec(sam[!, :paR]) : empty_f32)

        gx2 = is_binocular ? gxR_v : empty_f32
        gy2 = is_binocular ? _coerce_f32_vec(sam[!, :gyR]) : empty_f32
        pa2 = is_binocular ? _coerce_f32_vec(sam[!, :paR]) : empty_f32

        valid_idx = Vector{Int}(undef, n_sam)
        n_valid = 0
        is_mono_ts = true
        prev_ts = UInt32(0)
        @inbounds for i = 1:n_sam
            ti = times[i]
            if ti >= min_rec_time && ti <= max_valid_ts
                if n_valid > 0 && ti < prev_ts
                    is_mono_ts = false
                end
                prev_ts = ti
                n_valid += 1
                valid_idx[n_valid] = i
            end
        end
        resize!(valid_idx, n_valid)
        !is_mono_ts && sort!(valid_idx, by = i -> @inbounds(times[i]))

        _stream_ascii_samples!(
            io,
            chunk_buf,
            valid_idx,
            times,
            arena.buf,
            ev_meta,
            gx1,
            gy1,
            pa1,
            gx2,
            gy2,
            pa2,
            has_eye1,
            is_binocular,
        )
    else
        cpos = 1
        arena_buf = arena.buf
        @inbounds for ei = 1:length(ev_meta)
            m = ev_meta[ei]
            cpos = _buf_arena_nl!(io, chunk_buf, cpos, arena_buf, Int(m[3]), Int(m[4]))
        end
        _flush_chunk!(io, chunk_buf, cpos)
    end
end
