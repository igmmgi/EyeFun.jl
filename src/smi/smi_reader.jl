# ── SMI IDF/TXT Reader ─────────────────────────────────────────────────────── #

"""
    read_smi(path::String) -> SMIFile

Read an SMI data file (`.txt` text export or `.idf` binary) and return a raw
`SMIFile` container with parsed sample data and recording metadata.

The function auto-detects the format from the file extension.

Screen geometry (`screen_width_cm`, `viewing_distance_cm`) is extracted directly
from the file header (`Stimulus Dimension [mm]` and `Head Distance [mm]`). If
these header fields are absent, conservative defaults are used (30 cm / 50 cm).

TODO: Can they be missing? Not familiar with SMI files.

To obtain an analysis-ready `EyeData` with events detected, pass the result to
`create_smi_dataframe`:

```julia
raw = read_smi("pp23671_rest1_samples.txt")
ed  = create_smi_dataframe(raw)
fixations(ed)
saccades(ed)
blinks(ed)
plot_gaze(ed)
```
"""
function read_smi(path::String)
    isfile(path) || error("File not found: $path")
    ext = lowercase(splitext(path)[2])
    if ext == ".txt"
        return _read_smi_txt(path)
    elseif ext == ".idf"
        return _read_smi_idf(path)
    else
        error("Unknown SMI file extension: $ext. Expected .txt or .idf")
    end
end


# ── Text export reader ─────────────────────────────────────────────────────── #

function _read_smi_txt(path::String)
    lines = readlines(path)

    # ── Parse header — geometry comes from the file ───────────────────────── #
    sample_rate = 0.0
    screen_res = (1280, 1024)
    subject = ""
    stim_width_mm = 0.0
    head_dist_mm = 0.0
    header_end = 0

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
            end
        elseif startswith(content, "Head Distance [mm]:")
            head_dist_mm = parse(Float64, strip(split(content, "\t")[end]))
        end
    end

    # Screen geometry from file header; fall back to SMI RED typical values
    screen_width_cm = stim_width_mm > 0 ? stim_width_mm / 10.0 : 30.0
    viewing_distance_cm = head_dist_mm > 0 ? head_dist_mm / 10.0 : 50.0

    # ── Parse column header ───────────────────────────────────────────────── #
    col_header = split(strip(lines[header_end]), "\t")

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
    idx_trigger = find_col("Trigger")

    # Left eye: prefer calibrated POR, fall back to Raw
    idx_lpx = find_col("L POR X [px]")
    idx_lpy = find_col("L POR Y [px]")
    idx_lrx = find_col("L Raw X [px]")
    idx_lry = find_col("L Raw Y [px]")
    idx_ldx = find_col("L Dia X [px]")
    idx_ldy = find_col("L Dia Y [px]")

    # Right eye
    idx_rpx = find_col("R POR X [px]")
    idx_rpy = find_col("R POR Y [px]")
    idx_rrx = find_col("R Raw X [px]")
    idx_rry = find_col("R Raw Y [px]")
    idx_rdx = find_col("R Dia X [px]")
    idx_rdy = find_col("R Dia Y [px]")

    has_left = idx_lpx !== nothing || idx_lrx !== nothing
    has_right = idx_rpx !== nothing || idx_rrx !== nothing

    # ── Pre-allocate sample arrays ────────────────────────────────────────── #
    n_samples = length(lines) - header_end
    time_vec = Vector{Float64}(undef, n_samples)
    trial_vec = Vector{Int}(undef, n_samples)
    msg_vec = fill("", n_samples)
    gxL = fill(NaN, n_samples)
    gyL = fill(NaN, n_samples)
    paL = fill(NaN, n_samples)
    gxR = fill(NaN, n_samples)
    gyR = fill(NaN, n_samples)
    paR = fill(NaN, n_samples)
    pupxL = fill(NaN, n_samples)
    pupyL = fill(NaN, n_samples)
    pupxR = fill(NaN, n_samples)
    pupyR = fill(NaN, n_samples)

    # ── Parse SMP rows ────────────────────────────────────────────────────── #
    row = 0
    for i = (header_end+1):length(lines)
        line = strip(lines[i])
        isempty(line) && continue
        fields = split(line, "\t")
        length(fields) < idx_type && continue
        strip(fields[idx_type]) == "SMP" || continue

        row += 1

        # Time: µs → ms
        time_vec[row] = parse(Float64, strip(fields[idx_time])) / 1000.0
        trial_vec[row] = parse(Int, strip(fields[idx_trial]))

        # Trigger → message
        if idx_trigger !== nothing && idx_trigger <= length(fields)
            trig = strip(fields[idx_trigger])
            if trig != "0" && !isempty(trig)
                msg_vec[row] = trig
            end
        end

        # Left raw pupil position (camera coords) — always capture if present
        lrx, lry = NaN, NaN
        if idx_lrx !== nothing && idx_lrx <= length(fields)
            lrx = parse(Float64, strip(fields[idx_lrx]))
            lry = parse(Float64, strip(fields[idx_lry]))
            if lrx == 0.0 && lry == 0.0
                lrx = NaN
                lry = NaN
            end
        end
        pupxL[row] = lrx
        pupyL[row] = lry

        # Left calibrated gaze (POR); fall back to raw if POR absent
        lx, ly = 0.0, 0.0
        if idx_lpx !== nothing && idx_lpx <= length(fields)
            lx = parse(Float64, strip(fields[idx_lpx]))
            ly = parse(Float64, strip(fields[idx_lpy]))
        elseif idx_lrx !== nothing
            lx = isnan(lrx) ? 0.0 : lrx
            ly = isnan(lry) ? 0.0 : lry
        end
        pa_l = 0.0
        if idx_ldx !== nothing && idx_ldx <= length(fields)
            pdx = parse(Float64, strip(fields[idx_ldx]))
            pdy = (idx_ldy !== nothing && idx_ldy <= length(fields)) ?
                  parse(Float64, strip(fields[idx_ldy])) : pdx
            pa_l = (pdx + pdy) / 2.0
        end
        # SMI encodes missing data as explicitly zero. Decouple gaze validity from pupil.
        gxL[row] = (lx == 0.0 && ly == 0.0) ? NaN : lx
        gyL[row] = (lx == 0.0 && ly == 0.0) ? NaN : ly
        paL[row] = pa_l == 0.0 ? NaN : pa_l

        # Right raw pupil position
        rrx, rry = NaN, NaN
        if idx_rrx !== nothing && idx_rrx <= length(fields)
            rrx = parse(Float64, strip(fields[idx_rrx]))
            rry = parse(Float64, strip(fields[idx_rry]))
            if rrx == 0.0 && rry == 0.0
                rrx = NaN
                rry = NaN
            end
        end
        pupxR[row] = rrx
        pupyR[row] = rry

        # Right calibrated gaze (POR); fall back to raw if POR absent
        rx, ry = 0.0, 0.0
        if idx_rpx !== nothing && idx_rpx <= length(fields)
            rx = parse(Float64, strip(fields[idx_rpx]))
            ry = parse(Float64, strip(fields[idx_rpy]))
        elseif idx_rrx !== nothing
            rx = isnan(rrx) ? 0.0 : rrx
            ry = isnan(rry) ? 0.0 : rry
        end
        pa_r = 0.0
        if idx_rdx !== nothing && idx_rdx <= length(fields)
            rdx = parse(Float64, strip(fields[idx_rdx]))
            rdy = (idx_rdy !== nothing && idx_rdy <= length(fields)) ?
                  parse(Float64, strip(fields[idx_rdy])) : rdx
            pa_r = (rdx + rdy) / 2.0
        end
        gxR[row] = (rx == 0.0 && ry == 0.0) ? NaN : rx
        gyR[row] = (rx == 0.0 && ry == 0.0) ? NaN : ry
        paR[row] = pa_r == 0.0 ? NaN : pa_r
    end

    # ── Trim and build DataFrame ──────────────────────────────────────────── #
    n = row
    resize!(time_vec, n)
    resize!(trial_vec, n)
    resize!(msg_vec, n)
    resize!(gxL, n)
    resize!(gyL, n)
    resize!(paL, n)
    resize!(gxR, n)
    resize!(gyR, n)
    resize!(paR, n)
    resize!(pupxL, n)
    resize!(pupyL, n)
    resize!(pupxR, n)
    resize!(pupyR, n)

    df = DataFrame(
        time=time_vec,
        trial=trial_vec,
        participant=fill(subject, n),
        gxL=gxL,
        gyL=gyL,
        paL=paL,
        gxR=gxR,
        gyR=gyR,
        paR=paR,
        pupxL=pupxL,
        pupyL=pupyL,
        pupxR=pupxR,
        pupyR=pupyR,
        message=msg_vec,
    )

    eye_str = has_left && has_right ? "binocular" : has_left ? "left" : "right"
    @info "SMI TXT: $n samples, $sample_rate Hz, $eye_str eye, subject=$subject"

    # ── Build and return SMIFile ──────────────────────────────────────────── #
    smi = SMIFile(path)
    smi.samples = df
    smi.sample_rate = sample_rate
    smi.screen_res = screen_res
    smi.screen_width_cm = Float64(screen_width_cm)
    smi.viewing_distance_cm = Float64(viewing_distance_cm)
    smi.subject = subject
    return smi
end

# ── IDF binary reader ──────────────────────────────────────────────────────── #

function _read_smi_idf(path::String)

    data = read(path)
    n_bytes = length(data)

    # IDF version is first Int32
    idf_version = reinterpret(Int32, data[1:4])[1]

    # Screen geometry defaults (IDF header doesn't reliably encode physical dims)
    screen_width_cm = 30.0
    viewing_distance_cm = 60.0

    # Find the ASCII column-header string starting with "TimeStamp"
    header_str = ""
    col_offset = 0
    for i = 1:(n_bytes-9)
        if data[i] == UInt8('T') && data[i+1] == UInt8('i') &&
           data[i+2] == UInt8('m') && data[i+3] == UInt8('e') &&
           data[i+4] == UInt8('S') && data[i+5] == UInt8('t')
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
    float_cols = filter(c -> c ∉ ("TimeStamp", "SetNum", "Quality", "Trig", "Aux"), col_names)

    # ── Sample rate (heuristic: fixed offset for IDF v9) ─────────────────── #
    sample_rate = 0.0
    screen_res = (1280, 1024)
    if n_bytes > 0x2DC
        sr_candidate = reinterpret(Int32, data[0x2D3:0x2D6])[1]
        if sr_candidate > 0 && sr_candidate <= 2000
            sample_rate = Float64(sr_candidate)
        end
    end
    # Store the result from the header (0.0 if not found). We'll fallback to timestamp diffs later if needed.
    header_sample_rate = sample_rate

    # ── Skip null padding after column header ────────────────────────────── #
    pos = col_offset
    while pos <= n_bytes && data[pos] == 0x00
        pos += 1
    end

    # ── Find true data start via timestamp consistency scan ───────────── #
    # After null padding there is a small preamble (typically 16 bytes)
    # before the 106-byte sub-records begin. We locate the first sub-record
    # by scanning at 4-byte alignment for three consecutive timestamps
    # (at 106-byte intervals) whose differences are consistent.
    sub_record_size = 106
    data_start = 0
    found_data = false

    for try_offset = pos:4:min(pos + 64, n_bytes - 4 * sub_record_size)
        ts1 = reinterpret(UInt32, data[try_offset+4:try_offset+7])[1]
        ts1 > 1_000_000 || continue

        ts2 = reinterpret(UInt32, data[try_offset+sub_record_size+4:try_offset+sub_record_size+7])[1]
        ts3 = reinterpret(UInt32, data[try_offset+2*sub_record_size+4:try_offset+2*sub_record_size+7])[1]

        d1 = (ts2 >= ts1) ? (ts2 - ts1) : ((0xFFFFFFFF - ts1) + ts2 + 1)
        d2 = (ts3 >= ts2) ? (ts3 - ts2) : ((0xFFFFFFFF - ts2) + ts3 + 1)

        if d1 > 0 && d2 > 0 && abs(Int64(d2) - Int64(d1)) < 0.05 * Int64(d1)
            data_start = try_offset
            found_data = true
            break
        end
    end

    found_data || error("Could not locate IDF sub-record data. Use the .txt export instead.")

    # ── Sub-record layout (106 bytes each) ───────────────────────────────── #
    # Bytes 1-4  : record header / set number (LE UInt32)
    # Bytes 5-8  : timestamp in 1/256 µs units (LE UInt32)
    # Bytes 24-31: PupX  Float64  (raw camera-space pupil X)
    # Bytes 32-39: PupY  Float64  (raw camera-space pupil Y)
    # Bytes 40-47: DiaX  Float64  (pupil diameter X)
    # Bytes 48-55: DiaY  Float64  (pupil diameter Y)
    # Bytes 56-63: Cr0X  Float64  (corneal reflex X)
    # Bytes 64-71: Cr0Y  Float64  (corneal reflex Y)
    # Bytes 72-79: GX    Float64  (calibrated gaze X)
    # Bytes 80-87: GY    Float64  (calibrated gaze Y)
    # Bytes 102  : trigger units (0-99)
    # Bytes 103  : trigger hundreds digit (0-9)
    # Byte  106  : eye marker (0x53 = 'S')
    n_sub_records = (n_bytes - data_start) ÷ sub_record_size

    time_vec = Vector{Float64}(undef, n_sub_records)
    trial_vec = ones(Int, n_sub_records)
    msg_vec = fill("", n_sub_records)
    gxL = fill(NaN, n_sub_records)
    gyL = fill(NaN, n_sub_records)
    paL = fill(NaN, n_sub_records)
    gxR = fill(NaN, n_sub_records)
    gyR = fill(NaN, n_sub_records)
    paR = fill(NaN, n_sub_records)
    pupxL = fill(NaN, n_sub_records)
    pupyL = fill(NaN, n_sub_records)
    pupxR = fill(NaN, n_sub_records)
    pupyR = fill(NaN, n_sub_records)
    diaxL = fill(NaN, n_sub_records)
    diayL = fill(NaN, n_sub_records)
    diaxR = fill(NaN, n_sub_records)
    diayR = fill(NaN, n_sub_records)
    crxL = fill(NaN, n_sub_records)
    cryL = fill(NaN, n_sub_records)
    crxR = fill(NaN, n_sub_records)
    cryR = fill(NaN, n_sub_records)

    # Determine eye assignment from column header.
    # If only L-eye columns are present (monocular), both sub-records → gxL.
    has_right_cols = any(startswith(c, "R") && c ∉ ("Trig",) for c in col_names)

    row = 0
    last_raw_ts = UInt32(0)
    time_high_bits = Int64(0)

    for s = 0:(n_sub_records - 1)
        sub_off = data_start + s * sub_record_size
        sub_off + sub_record_size - 1 > n_bytes && break

        row += 1

        # Timestamp: bytes 5-8 of sub-record (LE UInt32, units of 1/256 µs)
        # The scan uses reinterpret(UInt32, data[try_offset+4:try_offset+7]),
        # and manual LE assembly from the same bytes:
        raw_ts = reinterpret(UInt32, data[sub_off+4:sub_off+7])[1]

        # Wrap protection for UInt32 overflow
        if row > 1 && raw_ts < last_raw_ts
            time_high_bits += 0x100000000
        end
        last_raw_ts = raw_ts
        # Convert: raw / 256 → µs, / 1000 → ms
        time_vec[row] = Float64(time_high_bits | Int64(raw_ts)) / 256_000.0

        # Calibrated gaze, raw pupil position, and pupil size
        # These offsets are 1-indexed from sub_off matching the original
        # working convention (verified against BeGaze exports)
        gx = reinterpret(Float64, data[sub_off+72:sub_off+79])[1]
        gy = reinterpret(Float64, data[sub_off+80:sub_off+87])[1]
        px = reinterpret(Float64, data[sub_off+24:sub_off+31])[1]   # PupX (camera)
        py = reinterpret(Float64, data[sub_off+32:sub_off+39])[1]   # PupY (camera)
        pupdx = reinterpret(Float64, data[sub_off+40:sub_off+47])[1]
        pupdy = reinterpret(Float64, data[sub_off+48:sub_off+55])[1]
        cx = reinterpret(Float64, data[sub_off+56:sub_off+63])[1]   # CR X
        cy = reinterpret(Float64, data[sub_off+64:sub_off+71])[1]   # CR Y
        pa = (pupdx + pupdy) / 2.0

        # ── Trigger value from bytes 102-103 (BCD encoding: 4 packed decimal digits)
        # byte102: low nibble = units, high nibble = tens
        # byte103: low nibble = hundreds, high nibble = thousands
        b102 = data[sub_off + 102]
        b103 = data[sub_off + 103]
        trig_val = Int(b103 >> 4) * 1000 + Int(b103 & 0x0F) * 100 +
                   Int(b102 >> 4) * 10 + Int(b102 & 0x0F)
        if trig_val > 0
            msg_vec[row] = string(trig_val)
        end

        # Decouple missing gaze coords from missing pupil attributes
        gaze_missing = (gx == 0.0 && gy == 0.0)
        pupil_missing = (pa == 0.0)

        # Alternating sub-records: even indices → left eye, odd → right (if binocular)
        to_left = (s % 2 == 0) || !has_right_cols
        if to_left
            gxL[row] = gaze_missing ? NaN : gx
            gyL[row] = gaze_missing ? NaN : gy
            paL[row] = pupil_missing ? NaN : pa
            pupxL[row] = (pupil_missing || px == 0.0) ? NaN : px
            pupyL[row] = (pupil_missing || py == 0.0) ? NaN : py
            diaxL[row] = pupil_missing ? NaN : pupdx
            diayL[row] = pupil_missing ? NaN : pupdy
            crxL[row] = cx == 0.0 ? NaN : cx
            cryL[row] = cy == 0.0 ? NaN : cy
        else
            gxR[row] = gaze_missing ? NaN : gx
            gyR[row] = gaze_missing ? NaN : gy
            paR[row] = pupil_missing ? NaN : pa
            pupxR[row] = (pupil_missing || px == 0.0) ? NaN : px
            pupyR[row] = (pupil_missing || py == 0.0) ? NaN : py
            diaxR[row] = pupil_missing ? NaN : pupdx
            diayR[row] = pupil_missing ? NaN : pupdy
            crxR[row] = cx == 0.0 ? NaN : cx
            cryR[row] = cy == 0.0 ? NaN : cy
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

    # ── Auto-detect sample rate from timestamps if header heuristic failed ── #
    if header_sample_rate == 0.0 && row > 1
        # Use unique timestamps since L/R sub-record pairs share the same timestamp
        n_check = min(row, 2000)
        unique_ts = unique(time_vec[1:n_check])
        if length(unique_ts) > 1
            ts_diffs = diff(unique_ts)
            valid_diffs = filter(>(0.0), ts_diffs)
            if !isempty(valid_diffs)
                sample_rate = round(1000.0 / median(valid_diffs))
            else
                sample_rate = 50.0
                @warn "Could not detect IDF sample rate from timestamps, defaulting to 50 Hz"
            end
        else
            sample_rate = 50.0
            @warn "Could not detect IDF sample rate from timestamps, defaulting to 50 Hz"
        end
    elseif header_sample_rate > 0.0
        sample_rate = header_sample_rate
    else
        sample_rate = 50.0
    end

    # ── Build events DataFrame from non-empty trigger messages ────────────── #
    evt_mask = msg_vec .!= ""
    evt_times = time_vec[evt_mask]
    evt_msgs = msg_vec[evt_mask]

    df = DataFrame(
        time=time_vec,
        trial=trial_vec,
        participant=fill("", row),
        gxL=gxL,
        gyL=gyL,
        paL=paL,
        gxR=gxR,
        gyR=gyR,
        paR=paR,
        pupxL=pupxL,
        pupyL=pupyL,
        pupxR=pupxR,
        pupyR=pupyR,
        diaxL=diaxL,
        diayL=diayL,
        diaxR=diaxR,
        diayR=diayR,
        crxL=crxL,
        cryL=cryL,
        crxR=crxR,
        cryR=cryR,
        message=msg_vec,
    )

    @info "SMI IDF: $row samples ($n_sub_records sub-records) at $sample_rate Hz"
    @info "SMI IDF Events: $(length(evt_times)) hardware triggers parsed."

    smi = SMIFile(path)
    smi.samples = df
    smi.events  = DataFrame(time=evt_times, type=fill("MSG", length(evt_times)), message=evt_msgs)
    smi.sample_rate = sample_rate
    smi.screen_res = screen_res
    smi.screen_width_cm = Float64(screen_width_cm)
    smi.viewing_distance_cm = Float64(viewing_distance_cm)
    return smi
end
