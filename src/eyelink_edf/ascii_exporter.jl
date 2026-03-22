"""
ASCII export functionality to create .asc files identical to SR Research's edf2asc tool.
"""

using DataFrames
using Dates
using Printf

# ── Buffer-based digit writers ─────────────────────────────────────────── #
# Write to a pre-allocated Vector{UInt8} at position `pos`, return new pos.
# This avoids per-byte write(io, UInt8) calls which go through dynamic
# dispatch and lock/unlock on IOStream. One sample line is built in the
# buffer, then flushed with a single write(io, @view buf[1:pos-1]).

"""Write a UInt32 as decimal ASCII digits into buf at pos. Returns new pos."""
@inline function _buf_uint32!(buf::Vector{UInt8}, pos::Int, v::UInt32)
    # Count digits first
    if v == UInt32(0)
        @inbounds buf[pos] = 0x30
        return pos + 1
    end
    # Find number of digits
    ndigits = 0
    tmp = v
    while tmp > UInt32(0)
        ndigits += 1
        tmp ÷= UInt32(10)
    end
    # Write digits right-to-left
    p = pos + ndigits - 1
    tmp = v
    while tmp > UInt32(0)
        @inbounds buf[p] = UInt8(0x30) + UInt8(tmp % UInt32(10))
        tmp ÷= UInt32(10)
        p -= 1
    end
    return pos + ndigits
end

"""Write a Float32 with 1 decimal place into buf at pos. NaN → '.'. Returns new pos."""
@inline function _buf_float1!(buf::Vector{UInt8}, pos::Int, v::Float32)
    if isnan(v)
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

# Keep IO-based writers for event formatting (small count, not hot path)
"""Write a UInt32 as decimal ASCII digits to IO."""
@inline function _write_uint32(io::IO, v::UInt32)
    if v < UInt32(10)
        write(io, UInt8(0x30) + UInt8(v))
        return
    end
    _write_uint32(io, v ÷ UInt32(10))
    write(io, UInt8(0x30) + UInt8(v % UInt32(10)))
end

"""Write a Float32 with exactly 1 decimal place to IO.
Missing (NaN) is written as a single dot matching edf2asc convention."""
@inline function _write_float1(io::IO, v::Float32)
    if isnan(v)
        write(io, UInt8('.'))
        return
    end
    vi = round(Int32, v * 10.0f0)
    if vi < Int32(0)
        write(io, UInt8('-'))
        vi = -vi
    end
    _write_uint32(io, UInt32(vi ÷ Int32(10)))
    write(io, UInt8('.'))
    write(io, UInt8(0x30) + UInt8(vi % Int32(10)))
end

"""Return the number of decimal digits in a Float32 value (rounded to 1 dp), minimum 1."""
@inline function _float1_width(v::Float32)::Int
    isnan(v) && return 1  # "."
    vi = abs(round(Int32, v * 10.0f0))
    int_part = vi ÷ Int32(10)
    neg = v < 0.0f0 ? 1 : 0
    # count digits in int_part
    d = 1
    x = int_part
    while x >= 10
        x ÷= 10
        d += 1
    end
    return neg + d + 2  # sign? + digits + "." + 1 decimal
end

"""Write a Float32 right-aligned in a field of `width` chars, tab-separated.
edf2asc uses consistent column widths: gaze x/y → 8 chars, pupil → 8 chars."""
@inline function _write_float1_field(io::IO, v::Float32, field_width::Int)
    w = _float1_width(v)
    spaces = field_width - w
    for _ = 1:spaces
        write(io, UInt8(' '))
    end
    _write_float1(io, v)
end

# Pre-built byte-string constants for the fixed parts of a sample line.
# Written with write(io, ::Vector{UInt8}) — one call, zero allocation.
const _TAB2SP = b"\t  "    # \t + 2 spaces (before gx, gy)
const _TAB1SP = b"\t "     # \t + 1 space  (before pa)
const _TABDOTS = b"\t...\n" # trailing tag + newline

"""
    export_to_ascii(edf::EDFFile, output_file::String; 
                   include_samples::Bool = true,
                   include_events::Bool = true,
                   include_messages::Bool = true)

Export an EDF file to ASCII format identical to SR Research's edf2asc tool.

# Arguments
- `edf`: The EDFFile object to export
- `output_file`: Path to the output .asc file
- `include_samples`: Whether to include sample data (default: true)
- `include_events`: Whether to include event data (default: true)
- `include_messages`: Whether to include message data (default: true)

# Returns
- `Nothing`: Writes the ASCII file to disk
"""
function export_to_ascii(
    edf::EDFFile,
    output_file::String;
    include_samples::Bool = true,
    include_events::Bool = true,
    include_messages::Bool = true,
)
    # Write to an in-memory buffer first — IOBuffer has no per-byte lock
    # overhead, unlike IOStream which acquires/releases a lock on every
    # write(io, UInt8(…)) call. Then flush to disk in one shot.
    buf = IOBuffer(; sizehint = 50_000_000)  # ~50 MB hint for typical files
    write_header(buf, edf)
    if include_messages || include_events || include_samples
        write_chronological_data(
            buf,
            edf,
            include_messages,
            include_events,
            include_samples,
        )
    end
    open(output_file, "w") do io
        write(io, take!(buf))
    end
end

"""
    write_header(io::IO, edf::EDFFile)

Write the ASCII file header with conversion info and metadata.
"""
function write_header(io::IO, edf::EDFFile)
    println(io, "** CONVERTED FROM $(basename(edf.filename)) using EyeFun.jl on $(now())")
    # Raw EDF preamble has lines like "DATE: ...", "TYPE: ...", "EYELINK II CL..."
    # without "**" prefix — edf2asc adds that. We do the same.
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

# ── Eye / pupil helpers ────────────────────────────────────────────────────── #

"""Map recording eye code to the long name used in START/EVENTS/SAMPLES header lines."""
function _eye_long(eye_code::Integer)
    eye_code == EYE_RIGHT && return "RIGHT"
    eye_code == EYE_BINOCULAR && return "LEFT\tRIGHT"  # tab-separated as in reference
    return "LEFT"  # EYE_LEFT or unknown
end

"""Map recording eye code to the single-letter used in event lines (SFIX, ESACC …)."""
function _eye_letter(eye_code::Integer)
    eye_code == EYE_RIGHT && return "R"
    return "L"
end

"""Map pupil_type code to the keyword used in the PUPIL line."""
function _pupil_keyword(pupil_type::Integer)
    pupil_type == PUPIL_DIAMETER && return "DIAMETER"
    return "AREA"
end

"""
    write_chronological_data(io, edf, include_messages, include_events, include_samples)

Streams events and samples to IO in timestamp order.
Events (~thousands) are collected into a small sorted list.
Samples (~millions) are streamed directly column-by-column - never collected
into a temp array - so memory is O(events), not O(samples).
"""
function write_chronological_data(
    io::IO,
    edf::EDFFile,
    include_messages::Bool,
    include_events::Bool,
    include_samples::Bool,
)

    # ── Determine first real recording start time ──────────────────────────── #
    # Garbage recordings have implausible sample_rates; real ones are 100-2000Hz.
    min_rec_time = if nrow(edf.recordings) > 0
        valid_starts = filter(
            r ->
                !ismissing(r.state) &&
                r.state == RECORDING_START &&
                !ismissing(r.sample_rate) &&
                r.sample_rate >= 100.0f0 &&
                r.sample_rate <= 2000.0f0,
            edf.recordings,
        )
        nrow(valid_starts) > 0 ? minimum(valid_starts.time) : minimum(edf.recordings.time)
    else
        UInt32(0)
    end

    # ── Valid timestamp range: from ENDSAMPLES/ENDEVENTS recording block ──────── #
    # END recordings have state=RECORDING_END. Find the one with timestamp > min_rec_time.
    # (Garbage end-recordings exist but have timestamps far from min_rec_time.)
    max_valid_ts = begin
        end_candidates = if nrow(edf.recordings) > 0
            filter(
                r ->
                    !ismissing(r.state) &&
                    r.state == RECORDING_END &&
                    !ismissing(r.time) &&
                    r.time > min_rec_time,
                edf.recordings,
            )
        else
            DataFrame()
        end
        if nrow(end_candidates) > 0
            # Use the max END timestamp + 5ms slack for final blink-period samples
            UInt32(min(UInt64(maximum(end_candidates.time)) + 5_000, typemax(UInt32)))
        else
            # No reliable END: bound by min_rec_time + 1 hour
            UInt32(min(UInt64(min_rec_time) + 3_600_000, typemax(UInt32)))
        end
    end
    valid_ts(ts) = ts <= max_valid_ts
    # Events must be at or after the first real recording start.
    # Subtract 10ms slack so system messages that arrive just before START are included
    # (e.g. RECCFG at t=975865 vs START at t=975866).
    # Messages are included if they have a non-zero, valid timestamp.
    # edf2asc includes ALL messages in the file (pre/post recording calibration etc.).
    # We only exclude ts=0 garbage from binary parse artifacts.
    min_msg_time = UInt32(1)  # include everything with a non-zero timestamp
    in_recording(ts) = ts >= min_rec_time
    in_msg_range(ts) = ts > UInt32(0) && valid_ts(ts)

    # ── Build a small sorted list of (timestamp, priority, line_string) ─────── #
    # priority=0 → before the sample at this ts (START events, MSG, INPUT, recording headers)
    # priority=1 → after  the sample at this ts (EFIX, ESACC, EBLINK)
    ev_lines = Tuple{UInt32,Int,String}[]

    if include_events && nrow(edf.recordings) > 0
        trial_groups = groupby(edf.recordings, :trial)
        for group in trial_groups
            r = first(group)
            t = r.time
            # Only emit START blocks for real recording-start rows
            r.state != RECORDING_START && continue

            eye_code = Int(r.eye)
            eye_long = _eye_long(eye_code)
            eye_letter = _eye_letter(eye_code)
            pupil_kw = _pupil_keyword(Int(r.pupil_type))
            rate_str =
                isinteger(r.sample_rate) ? "$(Int(r.sample_rate)).00" :
                @sprintf("%.2f", r.sample_rate)
            push!(ev_lines, (t, 0, "START\t$(t) \t$(eye_long)\tSAMPLES\tEVENTS"))
            push!(ev_lines, (t, 0, "PRESCALER\t1"))
            push!(ev_lines, (t, 0, "VPRESCALER\t1"))
            push!(ev_lines, (t, 0, "PUPIL\t$(pupil_kw)"))
            push!(
                ev_lines,
                (
                    t,
                    0,
                    "EVENTS\tGAZE\t$(eye_long)\tRATE\t$(rate_str)\tTRACKING\tCR\tFILTER\t2",
                ),
            )
            push!(
                ev_lines,
                (
                    t,
                    0,
                    "SAMPLES\tGAZE\t$(eye_long)\tRATE\t$(rate_str)\tTRACKING\tCR\tFILTER\t2",
                ),
            )
        end
    end

    # INPUT events — must appear before MSG at the same timestamp (edf2asc order)
    if include_events && nrow(edf.events) > 0
        for row in eachrow(
            filter(
                r ->
                    r.type == EVENT_INPUTEVENT &&
                    r.input > 0 &&
                    in_msg_range(r.sttime) &&
                    valid_ts(r.sttime),
                edf.events,
            ),
        )
            push!(ev_lines, (row.sttime, 0, "INPUT\t$(row.sttime)\t$(row.input)"))
        end
    end

    if include_messages && nrow(edf.events) > 0
        # Include all MSG events from the recording start onward (no max_valid_ts filter
        # so that system messages at recording start are always included)
        msg_events = filter(
            r ->
                r.type == EVENT_MESSAGEEVENT &&
                in_msg_range(r.sttime) &&
                valid_ts(r.sttime),
            edf.events,
        )
        for row in eachrow(msg_events)
            clean = replace(row.message, '\0' => "")
            # Skip messages with non-printable/garbage content
            all(c -> isprint(c) || c == '\n' || c == '\t', clean) || continue
            lines = split(clean, '\n')
            for (i, ln) in enumerate(lines)
                if i == 1
                    push!(ev_lines, (row.sttime, 0, "MSG\t$(row.sttime) $(ln)"))
                elseif strip(ln) != ""
                    push!(ev_lines, (row.sttime, 0, ln))
                end
            end
        end
    end

    if include_events && nrow(edf.events) > 0
        valid_event(ts) = valid_ts(ts) && in_recording(ts)

        # Start events — must be in a real recording
        # Reference format: label left-padded to 9 chars, then ts directly (no intervening tab)
        for row in eachrow(
            filter(r -> r.type == EVENT_STARTSACC && valid_event(r.sttime), edf.events),
        )
            eye = hasproperty(row, :eye) ? _eye_letter(row.eye) : "L"
            push!(ev_lines, (row.sttime, 0, @sprintf("%-9s%d", "SSACC $(eye)", row.sttime)))
        end
        for row in eachrow(
            filter(r -> r.type == EVENT_STARTFIX && valid_event(r.sttime), edf.events),
        )
            eye = hasproperty(row, :eye) ? _eye_letter(row.eye) : "L"
            push!(ev_lines, (row.sttime, 0, @sprintf("%-9s%d", "SFIX $(eye)", row.sttime)))
        end
        for row in eachrow(
            filter(r -> r.type == EVENT_STARTBLINK && valid_event(r.sttime), edf.events),
        )
            eye = hasproperty(row, :eye) ? _eye_letter(row.eye) : "L"
            push!(
                ev_lines,
                (row.sttime, 0, @sprintf("%-9s%d", "SBLINK $(eye)", row.sttime)),
            )
        end
    end

    # End events — use parsed sub-DataFrames (correct sttime/entime/duration)
    if include_events
        sacc_df = saccades(edf)
        if nrow(sacc_df) > 0
            for row in eachrow(sacc_df)
                in_recording(row.sttime) && valid_ts(row.entime) || continue
                eye = hasproperty(row, :eye) ? _eye_letter(row.eye) : "L"
                dur = row.entime - row.sttime + 1  # inclusive interval
                gstx = round(hasproperty(row, :gstx) ? Float64(row.gstx) : 0.0, digits = 1)
                gsty = round(hasproperty(row, :gsty) ? Float64(row.gsty) : 0.0, digits = 1)
                genx = round(hasproperty(row, :genx) ? Float64(row.genx) : 0.0, digits = 1)
                geny = round(hasproperty(row, :geny) ? Float64(row.geny) : 0.0, digits = 1)
                stored_ampl = hasproperty(row, :ampl) ? Float64(row.ampl) : 0.0
                stored_pvel = hasproperty(row, :pvel) ? Float64(row.pvel) : 0.0
                ampl =
                    stored_ampl != 0.0 ? stored_ampl :
                    round(sqrt((genx - gstx)^2 + (geny - gsty)^2) / 10.0, digits = 2)
                pvel = round(stored_pvel, digits = 0)
                push!(
                    ev_lines,
                    (
                        row.entime,
                        1,
                        @sprintf(
                            "%-9s%d\t%d\t%d\t%6.1f\t%6.1f\t%6.1f\t%6.1f\t%6.2f\t%6.0f",
                            "ESACC $(eye)",
                            row.sttime,
                            row.entime,
                            dur,
                            gstx,
                            gsty,
                            genx,
                            geny,
                            ampl,
                            pvel
                        )
                    ),
                )
            end
        end
        fix_df = fixations(edf)
        if nrow(fix_df) > 0
            for row in eachrow(fix_df)
                in_recording(row.sttime) && valid_ts(row.entime) || continue
                eye = hasproperty(row, :eye) ? _eye_letter(row.eye) : "L"
                dur = row.entime - row.sttime + 1  # inclusive interval
                gavx = round(hasproperty(row, :gavx) ? Float64(row.gavx) : 0.0, digits = 1)
                gavy = round(hasproperty(row, :gavy) ? Float64(row.gavy) : 0.0, digits = 1)
                ava = hasproperty(row, :ava) ? Int(round(Float64(row.ava))) : 0
                push!(
                    ev_lines,
                    (
                        row.entime,
                        1,
                        @sprintf(
                            "%-9s%d\t%d\t%d\t%6.1f\t%6.1f\t%6d",
                            "EFIX $(eye)",
                            row.sttime,
                            row.entime,
                            dur,
                            gavx,
                            gavy,
                            ava
                        )
                    ),
                )
            end
        end
        blink_df = blinks(edf)
        if nrow(blink_df) > 0
            for row in eachrow(blink_df)
                in_recording(row.sttime) && valid_ts(row.entime) || continue
                eye = hasproperty(row, :eye) ? _eye_letter(row.eye) : "L"
                dur = row.entime - row.sttime + 1  # inclusive interval
                push!(
                    ev_lines,
                    (
                        row.entime,
                        1,
                        @sprintf(
                            "%-9s%d\t%d\t%d",
                            "EBLINK $(eye)",
                            row.sttime,
                            row.entime,
                            dur
                        )
                    ),
                )
            end
        end
    end

    sort!(ev_lines, by = x -> x[1])

    # END marker added after sort so it just needs inserting at sorted position
    # Placed at last_sample+1 so it appears before subsequent INPUT/MSG events at higher timestamps
    if include_events
        end_ts = if edf.samples !== nothing && nrow(edf.samples) > 0
            UInt32(min(UInt64(maximum(edf.samples.time)) + 1, typemax(UInt32)))
        elseif nrow(edf.recordings) > 0
            maximum(edf.recordings.time)
        else
            UInt32(0)
        end
        # Insert at sorted position (searchsortedfirst on first element of tuples)
        insert_pos = searchsortedfirst(ev_lines, (end_ts, 0, ""), by = x -> (x[1], x[2]))
        insert!(
            ev_lines,
            insert_pos,
            (end_ts, 0, "END\t$(end_ts)\tSAMPLES\tEVENTS\tRES\t0.0\t0.0"),
        )
    end
    n_ev = length(ev_lines)
    n_sam = edf.samples !== nothing ? nrow(edf.samples) : 0
    ei = 1  # index into ev_lines

    if include_samples && edf.samples !== nothing && n_sam > 0
        sam = edf.samples
        has_gxL = hasproperty(sam, :gxL)
        has_gxR = hasproperty(sam, :gxR)
        # Columns from binary reader are concrete Float32[] with NaN for missing.
        # Columns from ASC reader may be Union{Float32,Nothing} — coerce if needed.
        _col(c) =
            eltype(c) == Float32 ? c :
            Float32[v === nothing || ismissing(v) ? Float32(NaN) : Float32(v) for v in c]
        times = Vector{UInt32}(sam.time)

        # Determine which eye columns to use.
        # For monocular LEFT → gxL; for monocular RIGHT → gxR; for binocular → both.
        use_left = has_gxL && !all(isnan, sam.gxL)
        use_right = has_gxR && !all(isnan, sam.gxR)
        is_binocular = use_left && use_right

        # Left-eye columns (or sole monocular columns when not binocular)
        gxcol = use_left ? _col(sam.gxL) : (use_right ? _col(sam.gxR) : nothing)
        gycol = use_left ? _col(sam.gyL) : (use_right ? _col(sam.gyR) : nothing)
        pacol = use_left ? _col(sam.paL) : (use_right ? _col(sam.paR) : nothing)

        # Right-eye columns (only used in binocular mode)
        gxcol2 = is_binocular ? _col(sam.gxR) : nothing
        gycol2 = is_binocular ? _col(sam.gyR) : nothing
        pacol2 = is_binocular ? _col(sam.paR) : nothing

        # ── Filter to valid timestamp range and sort ──────────────────────────── #
        # Garbage samples from pre/post recording binary noise can have any timestamp.
        # Out-of-order timestamps break the chronological event-interleaving loop
        # (a high garbage ts advances ei past all events; real samples then get none).
        # Solution: build a filtered, sorted index of valid sample positions.
        valid_mask = [t >= min_rec_time && t <= max_valid_ts for t in times]
        valid_idx = findall(valid_mask)
        # Sort by timestamp (valid samples should already be monotonic, but
        # garbage interleaved entries may have broken the order)
        sort!(valid_idx, by = i -> times[i])

        # Pre-allocate a line buffer for sample writing (max ~80 bytes per line)
        linebuf = Vector{UInt8}(undef, 128)

        for i in valid_idx
            ts = times[i]
            # 1. Flush events strictly before this sample's timestamp
            while ei <= n_ev && ev_lines[ei][1] < ts
                ln = ev_lines[ei][3]
                write(io, ln)
                write(io, 0x0a)
                ei += 1
            end
            # 2. Flush priority-0 events AT this timestamp (START, MSG, INPUT — before sample)
            while ei <= n_ev && ev_lines[ei][1] == ts && ev_lines[ei][2] == 0
                ln = ev_lines[ei][3]
                write(io, ln)
                write(io, 0x0a)
                ei += 1
            end
            # 3. Write sample line using pre-allocated buffer (one write per line
            # instead of ~30 individual byte writes going through dynamic dispatch)
            p = _buf_uint32!(linebuf, 1, ts)
            if gxcol !== nothing
                @inbounds linebuf[p] = UInt8('\t');
                p += 1
                p = _buf_float1_field!(linebuf, p, gxcol[i], 7)
                @inbounds linebuf[p] = UInt8('\t');
                p += 1
                p = _buf_float1_field!(linebuf, p, gycol[i], 7)
                @inbounds linebuf[p] = UInt8('\t');
                p += 1
                p = _buf_float1_field!(linebuf, p, pacol[i], 7)
                if is_binocular && gxcol2 !== nothing
                    @inbounds linebuf[p] = UInt8('\t');
                    p += 1
                    p = _buf_float1_field!(linebuf, p, gxcol2[i], 7)
                    @inbounds linebuf[p] = UInt8('\t');
                    p += 1
                    p = _buf_float1_field!(linebuf, p, gycol2[i], 7)
                    @inbounds linebuf[p] = UInt8('\t');
                    p += 1
                    p = _buf_float1_field!(linebuf, p, pacol2[i], 7)
                end
            end
            # Append "\t...\n"
            @inbounds linebuf[p] = UInt8('\t');
            p += 1
            @inbounds linebuf[p] = UInt8('.');
            p += 1
            @inbounds linebuf[p] = UInt8('.');
            p += 1
            @inbounds linebuf[p] = UInt8('.');
            p += 1
            @inbounds linebuf[p] = UInt8('\n');
            p += 1
            unsafe_write(io, pointer(linebuf), UInt(p - 1))
            # 4. Flush priority-1 events AT this timestamp (EFIX, ESACC, EBLINK — after sample)
            while ei <= n_ev && ev_lines[ei][1] == ts && ev_lines[ei][2] == 1
                ln = ev_lines[ei][3]
                write(io, ln)
                write(io, 0x0a)
                ei += 1
            end
        end

    end

    # Flush any remaining events after last sample
    while ei <= n_ev
        ln = ev_lines[ei][3]
        write(io, ln)
        write(io, 0x0a)
        ei += 1
    end
end
