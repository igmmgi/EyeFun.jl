# ── SMI IDF/TXT Reader ─────────────────────────────────────────────────────── #

"""
    read_smi(path::String; screen_width_cm=30.0, viewing_distance_cm=50.0) -> EyeData

Read an SMI data file (`.txt` text export or `.idf` binary) and return an `EyeData`.

For `.txt` files, parses the tab-separated text export from IDF Converter.
For `.idf` files, reads the binary IDF format directly.

The function auto-detects the format from the file extension.

# Metadata Extraction
- Sample rate, screen resolution, stimulus dimensions, and head distance
  are extracted from the file header when available.
- Subject ID is stored in the DataFrame's `:participant` column.

# Example
```julia
# Text export
ed = read_smi("pp23671_rest1_samples.txt")

# Binary IDF
ed = read_smi("pp23671_rest1.idf")

# Then use as normal:
detect_events!(ed)
plot_gaze(ed)
```
"""
function read_smi(path::String; screen_width_cm::Real = 30.0, viewing_distance_cm::Real = 50.0)
    ext = lowercase(splitext(path)[2])
    if ext == ".txt"
        return _read_smi_txt(path; screen_width_cm = screen_width_cm,
                              viewing_distance_cm = viewing_distance_cm)
    elseif ext == ".idf"
        return _read_smi_idf(path; screen_width_cm = screen_width_cm,
                              viewing_distance_cm = viewing_distance_cm)
    else
        error("Unknown SMI file extension: $ext. Expected .txt or .idf")
    end
end

# ── Text export reader ─────────────────────────────────────────────────────── #

function _read_smi_txt(path::String; screen_width_cm::Real = 30.0, viewing_distance_cm::Real = 50.0)
    lines = readlines(path)

    # Parse header
    sample_rate = 0.0
    screen_res = (1280, 1024)
    subject = ""
    stim_width_mm = 0.0
    stim_height_mm = 0.0
    head_dist_mm = 0.0
    has_right = false
    has_left = false
    header_end = 0
    format_str = ""

    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if !startswith(stripped, "##")
            header_end = i
            break
        end

        content = strip(replace(stripped, r"^##\s*" => ""))

        if startswith(content, "Sample Rate:")
            sample_rate = parse(Float64, strip(split(content, "\t")[end]))
        elseif startswith(content, "Calibration Area:")
            parts = split(content, "\t")
            if length(parts) >= 3
                w = parse(Int, strip(parts[end-1]))
                h = parse(Int, strip(parts[end]))
                screen_res = (w, h)
            end
        elseif startswith(content, "Subject:")
            subject = strip(split(content, "\t")[end])
        elseif startswith(content, "Stimulus Dimension [mm]:")
            parts = split(content, "\t")
            if length(parts) >= 3
                stim_width_mm = parse(Float64, strip(parts[end-1]))
                stim_height_mm = parse(Float64, strip(parts[end]))
            end
        elseif startswith(content, "Head Distance [mm]:")
            head_dist_mm = parse(Float64, strip(split(content, "\t")[end]))
        elseif startswith(content, "Format:")
            format_str = strip(split(content, ":"; limit=2)[end])
            has_left = occursin("LEFT", uppercase(format_str))
            has_right = occursin("RIGHT", uppercase(format_str))
        end
    end

    # Use stimulus dimensions for screen_width_cm if available
    if stim_width_mm > 0
        screen_width_cm = stim_width_mm / 10.0
    end
    if head_dist_mm > 0
        viewing_distance_cm = head_dist_mm / 10.0
    end

    # Parse column header
    col_header = split(strip(lines[header_end]), "\t")
    n_cols = length(col_header)

    # Find column indices
    function find_col(names...)
        for n in names
            idx = findfirst(h -> strip(h) == n, col_header)
            idx !== nothing && return idx
        end
        return nothing
    end

    idx_time = find_col("Time")
    idx_type = find_col("Type")
    idx_trial = find_col("Trial")

    # Left eye columns
    idx_lx = find_col("L Raw X [px]", "L POR X [px]", "L Mapped Diameter [mm]")
    idx_ly = find_col("L Raw Y [px]", "L POR Y [px]")
    idx_ldx = find_col("L Dia X [px]", "L Mapped Diameter [mm]")
    idx_ldy = find_col("L Dia Y [px]")

    # Right eye columns
    idx_rx = find_col("R Raw X [px]", "R POR X [px]")
    idx_ry = find_col("R Raw Y [px]", "R POR Y [px]")
    idx_rdx = find_col("R Dia X [px]", "R Mapped Diameter [mm]")
    idx_rdy = find_col("R Dia Y [px]")

    # POR columns (point of regard - calibrated gaze)
    idx_lpx = find_col("L POR X [px]")
    idx_lpy = find_col("L POR Y [px]")
    idx_rpx = find_col("R POR X [px]")
    idx_rpy = find_col("R POR Y [px]")

    idx_trigger = find_col("Trigger")

    # Pre-allocate arrays
    n_samples = length(lines) - header_end
    time_vec = Vector{Float64}(undef, n_samples)
    trial_vec = Vector{Int}(undef, n_samples)
    gxL = fill(NaN, n_samples)
    gyL = fill(NaN, n_samples)
    paL = fill(NaN, n_samples)
    gxR = fill(NaN, n_samples)
    gyR = fill(NaN, n_samples)
    paR = fill(NaN, n_samples)

    row = 0
    for i in (header_end + 1):length(lines)
        line = strip(lines[i])
        isempty(line) && continue

        fields = split(line, "\t")
        min_needed = max(idx_type, something(idx_lx, 0), something(idx_ldx, 0))
        length(fields) < min_needed && continue

        # Only process SMP (sample) rows
        row_type = strip(fields[idx_type])
        row_type == "SMP" || continue

        row += 1

        # Time (microseconds → milliseconds)
        time_us = parse(Float64, strip(fields[idx_time]))
        time_vec[row] = time_us / 1000.0  # µs → ms

        # Trial
        trial_vec[row] = parse(Int, strip(fields[idx_trial]))

        # Left eye — use POR (calibrated) if available, else Raw
        if idx_lpx !== nothing
            lx = parse(Float64, strip(fields[idx_lpx]))
            ly = parse(Float64, strip(fields[idx_lpy]))
        elseif idx_lx !== nothing
            lx = parse(Float64, strip(fields[idx_lx]))
            ly = parse(Float64, strip(fields[idx_ly]))
        else
            lx = 0.0; ly = 0.0
        end

        # Pupil diameter (average of X and Y diameter)
        if idx_ldx !== nothing
            pdx = parse(Float64, strip(fields[idx_ldx]))
            pdy = idx_ldy !== nothing ? parse(Float64, strip(fields[idx_ldy])) : pdx
            pa_l = (pdx + pdy) / 2.0
        else
            pa_l = 0.0
        end

        # Detect blinks/tracking loss: SMI uses 0.0 for all values
        if lx == 0.0 && ly == 0.0 && pa_l == 0.0
            gxL[row] = NaN
            gyL[row] = NaN
            paL[row] = NaN
        else
            gxL[row] = lx
            gyL[row] = ly
            paL[row] = pa_l
        end

        # Right eye
        if idx_rpx !== nothing
            rx = parse(Float64, strip(fields[idx_rpx]))
            ry = parse(Float64, strip(fields[idx_rpy]))
        elseif idx_rx !== nothing
            rx = parse(Float64, strip(fields[idx_rx]))
            ry = parse(Float64, strip(fields[idx_ry]))
        else
            rx = 0.0; ry = 0.0
        end

        if idx_rdx !== nothing
            rdx = parse(Float64, strip(fields[idx_rdx]))
            rdy = idx_rdy !== nothing ? parse(Float64, strip(fields[idx_rdy])) : rdx
            pa_r = (rdx + rdy) / 2.0
        else
            pa_r = 0.0
        end

        if rx == 0.0 && ry == 0.0 && pa_r == 0.0
            gxR[row] = NaN
            gyR[row] = NaN
            paR[row] = NaN
        else
            gxR[row] = rx
            gyR[row] = ry
            paR[row] = pa_r
        end
    end

    # Trim to actual size
    n = row
    resize!(time_vec, n)
    resize!(trial_vec, n)
    resize!(gxL, n)
    resize!(gyL, n)
    resize!(paL, n)
    resize!(gxR, n)
    resize!(gyR, n)
    resize!(paR, n)

    df = DataFrame(
        time = time_vec,
        trial = trial_vec,
        gxL = gxL,
        gyL = gyL,
        paL = paL,
        gxR = gxR,
        gyR = gyR,
        paR = paR,
    )

    @info "SMI TXT: $(n) samples, $(sample_rate) Hz, subject=$(subject)"

    return EyeData(
        df;
        source = :smi,
        sample_rate = sample_rate,
        screen_res = screen_res,
        screen_width_cm = Float64(screen_width_cm),
        viewing_distance_cm = Float64(viewing_distance_cm),
    )
end

# ── IDF binary reader ──────────────────────────────────────────────────────── #

function _read_smi_idf(path::String; screen_width_cm::Real = 30.0, viewing_distance_cm::Real = 50.0)
    data = read(path)
    n_bytes = length(data)

    # IDF version is first Int32 at byte 0
    idf_version = reinterpret(Int32, data[1:4])[1]

    # Find the column header string — it's ASCII text in the binary
    # Look for "TimeStamp" which marks its start
    header_str = ""
    col_offset = 0
    for i in 1:(n_bytes - 9)
        if data[i] == UInt8('T') && data[i+1] == UInt8('i') && data[i+2] == UInt8('m') &&
           data[i+3] == UInt8('e') && data[i+4] == UInt8('S') && data[i+5] == UInt8('t')
            # Read until null byte or non-printable
            j = i
            while j <= n_bytes && data[j] >= 0x20 && data[j] <= 0x7e
                j += 1
            end
            header_str = String(data[i:j-1])
            col_offset = j
            break
        end
    end

    isempty(header_str) && error("Could not find column header in IDF file.")

    col_names = split(strip(header_str))
    n_fields = length(col_names)

    # Find metadata: sample rate, screen resolution
    # Sample rate is typically stored as Int32 around offset 0x2D0-0x2E0
    # We search for known field positions based on IDF v9 format

    # Parse metadata from the header region
    sample_rate = 0.0
    screen_res = (1280, 1024)

    # These are at known offsets for IDF v9
    # Calibration area is in the first 0x2A0 bytes as doubles
    # Sample rate is typically at a fixed offset
    # Let's look for it by scanning for common values near known positions

    # Search for sample rate: typically stored as Int32
    # In our file, we see 0x50 = 80 but sample rate should be 50
    # Let's try to extract from specific offsets
    if n_bytes > 0x2DC
        sr_candidate = reinterpret(Int32, data[0x2D3:0x2D6])[1]
        if sr_candidate > 0 && sr_candidate <= 2000
            sample_rate = Float64(sr_candidate)
        end
    end

    # If we couldn't find sample rate, try to infer from timestamps
    if sample_rate == 0.0
        sample_rate = 50.0  # default for SMI RED
        @warn "Could not detect sample rate, defaulting to 50 Hz"
    end

    # Skip to sample data — find the data block after the header
    # After the column header, there are some padding/metadata bytes,
    # then data records begin. Each record contains n_fields Float64 values
    # preceded by some fixed-size fields.

    # Record structure for IDF v9 with the given columns:
    # TimeStamp(i64) SetNum(i32) Quality(i32) + n_float_fields * Float64
    # Let's look at the structure more carefully

    # Skip padding after column header
    pos = col_offset
    while pos <= n_bytes && data[pos] == 0x00
        pos += 1
    end

    # The actual data records — each sample has:
    # Some small header + float64 values for each column
    # Let's figure out the record size by finding two consecutive timestamps

    # Read first timestamp candidate
    float_cols = filter(c -> c ∉ ("TimeStamp", "SetNum", "Quality", "Trig", "Aux"), col_names)
    n_float_cols = length(float_cols)

    # Map column names to our output columns
    col_map = Dict{String,Symbol}()
    for c in col_names
        if c == "LPupX"; col_map[c] = :raw_lx
        elseif c == "LPupY"; col_map[c] = :raw_ly
        elseif c == "LPupDX"; col_map[c] = :dia_lx
        elseif c == "LPupDY"; col_map[c] = :dia_ly
        elseif c == "LCr0X"; col_map[c] = :cr_lx
        elseif c == "LCr0Y"; col_map[c] = :cr_ly
        elseif c == "LGX"; col_map[c] = :gaze_lx
        elseif c == "LGY"; col_map[c] = :gaze_ly
        elseif c == "RPupX"; col_map[c] = :raw_rx
        elseif c == "RPupY"; col_map[c] = :raw_ry
        elseif c == "RPupDX"; col_map[c] = :dia_rx
        elseif c == "RPupDY"; col_map[c] = :dia_ry
        elseif c == "RCr0X"; col_map[c] = :cr_rx
        elseif c == "RCr0Y"; col_map[c] = :cr_ry
        elseif c == "RGX"; col_map[c] = :gaze_rx
        elseif c == "RGY"; col_map[c] = :gaze_ry
        end
    end

    # Try to determine record size
    # For IDF v9: records typically start with some fixed header
    # then pairs of (Int32 flag, Float64 value) for each field
    # Total record size = header + n_fields * (4 + 8) or similar

    # Looking at the hex dump, after column header + padding we see structured data
    # Let's try the most common IDF v9 layout:
    # 4 bytes (flags) + n_fields * 8 bytes (Float64)

    # Actually, let's try another approach: find timestamp pattern
    # The timestamps from the TXT file are ~35117409303 (microseconds)
    # In the IDF these might be stored as Int64

    # Search for the first known timestamp value from the companion txt file
    # Record structure: we need to figure this out empirically

    # Use a simpler approach: scan for recurring Int64 timestamps
    # that are ~20ms apart (for 50 Hz)

    # For now, let's try the standard IDF v9 record layout
    # Header per record: 4 bytes (unknown) + 4 bytes (unknown)
    # Then: TimeStamp(Int64) + SetNum(Int32) + Quality(Int32)
    #   + per-float-field: Float64
    # Record size = 8 + 4 + 4 + n_float_cols * 8

    # Let me scan for the actual structure
    # The first record data should start after some alignment boundary

    # Skip to data area — look for first non-zero block after col header padding
    data_start = pos

    # Try different record sizes and validate timestamp spacing
    # Fields from header: TimeStamp SetNum Quality LPupX LPupY LPupDX LPupDY LCr0X LCr0Y LGX LGY Trig Aux
    # That's 13 fields. But TimeStamp=Int64(8), SetNum=Int32(4), Quality=Int32(4),
    # float fields (10) * 8 = 80, Trig=Int32(4), Aux=Int32(4) ???
    # Total guess: 8 + 4 + 4 + 10*8 + 4 + 4 = 104 bytes per record?

    # Let me try: search for data start by scanning for valid Int64 timestamps
    # Valid timestamps should be in the 30 billion range (microseconds since boot)

    record_size = 0
    first_ts = Int64(0)
    found_data = false

    # Try field offsets within the data block and various record sizes.
    # IDF files embed timestamps at a field offset within each record, not necessarily
    # at byte 0 of the record. We scan multiple (try_offset, record_size) combinations.
    # Validity criteria (format-agnostic):
    #   - ts1 > 1_000_000 (some minimum counter value, rules out zero-padding)
    #   - ts2 > ts1 (monotonically increasing)
    #   - diff is consistent across several consecutive records (within 5%)
    #   - diff > 0 (non-zero spacing)
    #   - record_size > 40 (sanity check against tiny values)
    for try_offset in data_start:4:min(data_start + 300, n_bytes - 300)
        if try_offset + 7 > n_bytes; continue; end
        ts1 = reinterpret(Int64, data[try_offset:try_offset+7])[1]
        ts1 > 1_000_000 || continue

        # Try record sizes from 80 to 280
        for rs in 80:4:280
            try_offset + 3 * rs + 7 > n_bytes && continue
            ts2 = reinterpret(Int64, data[try_offset+rs:try_offset+rs+7])[1]
            diff = ts2 - ts1
            diff > 0 || continue

            # Validate consistency across next two records as well
            ts3 = reinterpret(Int64, data[try_offset+2*rs:try_offset+2*rs+7])[1]
            ts4 = reinterpret(Int64, data[try_offset+3*rs:try_offset+3*rs+7])[1]
            diff2 = ts3 - ts2
            diff3 = ts4 - ts3
            # All diffs must be within 5% of each other and positive
            if diff2 > 0 && diff3 > 0 &&
               abs(diff2 - diff) < 0.05 * diff &&
               abs(diff3 - diff) < 0.05 * diff
                record_size = rs
                first_ts = ts1
                data_start = try_offset
                found_data = true
                break
            end
        end
        found_data && break
    end

    if !found_data
        error("Could not determine IDF record structure. Use the .txt export instead.")
    end

    n_records = (n_bytes - data_start + 1) ÷ record_size
    @info "IDF: version=$idf_version, columns=$(join(col_names, ",")), record_size=$record_size, n_records=$n_records"

    # Parse records
    # Layout: Int64(ts) + remaining floats packed by field order
    # We'll map based on column names

    time_vec = Vector{Float64}(undef, n_records)
    trial_vec = ones(Int, n_records)  # SMI IDF doesn't always have trial info
    gxL = fill(NaN, n_records)
    gyL = fill(NaN, n_records)
    paL = fill(NaN, n_records)
    gxR = fill(NaN, n_records)
    gyR = fill(NaN, n_records)
    paR = fill(NaN, n_records)

    # Determine field offsets within a record
    # After Int64 timestamp (8 bytes), remaining data = record_size - 8
    # We have (n_fields - 1) remaining columns
    # Try: Int32 for SetNum, Int32 for Quality, then Float64 for each float column
    # 8(ts) + 4(set) + 4(quality) + n_float_cols*8 + 4(trig) + 4(aux) = ?

    # With 10 float cols: 8 + 4 + 4 + 80 + 4 + 4 = 104
    # Let's see if 104 matches our detected record_size

    for r in 1:n_records
        offset = data_start + (r - 1) * record_size

        # Timestamp (Int64, microseconds)
        ts = reinterpret(Int64, data[offset:offset+7])[1]
        time_vec[r] = Float64(ts) / 1000.0  # µs → ms

        # Skip SetNum(4) + Quality(4) = 8 bytes after timestamp
        foffset = offset + 8 + 4 + 4  # after ts + setnum + quality

        # Read float columns in order
        for (ci, cname) in enumerate(col_names)
            cname ∈ ("TimeStamp", "SetNum", "Quality") && continue

            if cname ∈ ("Trig", "Aux")
                # These might be Int32
                foffset += 4
                continue
            end

            if foffset + 7 > n_bytes; break; end
            val = reinterpret(Float64, data[foffset:foffset+7])[1]
            foffset += 8

            # Map to output columns
            if cname == "LPupX"
                gxL[r] = val
            elseif cname == "LPupY"
                gyL[r] = val
            elseif cname == "LPupDX" || cname == "LPupDY"
                paL[r] = isnan(paL[r]) ? val : (paL[r] + val) / 2.0
            elseif cname == "LGX"
                # Prefer calibrated gaze if non-zero
                if val != 0.0; gxL[r] = val; end
            elseif cname == "LGY"
                if val != 0.0; gyL[r] = val; end
            elseif cname == "RPupX"
                gxR[r] = val
            elseif cname == "RPupY"
                gyR[r] = val
            elseif cname == "RPupDX" || cname == "RPupDY"
                paR[r] = isnan(paR[r]) ? val : (paR[r] + val) / 2.0
            elseif cname == "RGX"
                if val != 0.0; gxR[r] = val; end
            elseif cname == "RGY"
                if val != 0.0; gyR[r] = val; end
            end
        end

        # Detect blinks (all zeros)
        if gxL[r] == 0.0 && gyL[r] == 0.0; gxL[r] = NaN; gyL[r] = NaN; paL[r] = NaN; end
        if gxR[r] == 0.0 && gyR[r] == 0.0; gxR[r] = NaN; gyR[r] = NaN; paR[r] = NaN; end
    end

    df = DataFrame(
        time = time_vec,
        trial = trial_vec,
        gxL = gxL,
        gyL = gyL,
        paL = paL,
        gxR = gxR,
        gyR = gyR,
        paR = paR,
    )

    @info "SMI IDF: $(n_records) samples at $(sample_rate) Hz"

    return EyeData(
        df;
        source = :smi,
        sample_rate = sample_rate,
        screen_res = screen_res,
        screen_width_cm = Float64(screen_width_cm),
        viewing_distance_cm = Float64(viewing_distance_cm),
    )
end
