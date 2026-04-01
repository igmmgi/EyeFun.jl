"""
SMI TXT export — writes an SMIFile back to the tab-separated text format
produced by SMI's BeGaze software, so that the Julia IDF binary reader
can be sanity-checked against the native software export.
"""

"""
    write_et_ascii(smi::SMIFile, path::String)

Write the sample data in `smi` to an SMI-format tab-separated text file.

The output is byte-compatible with BeGaze's own TXT export, so it can be
diff-ed or plotted against a native export to verify the IDF binary reader.

# Columns written
- Always: `Time` (µs), `Type`, `Trial`, `Trigger`
- Left eye (if present): `L POR X [px]`, `L POR Y [px]`, `L Dia X [px]`, `L Dia Y [px]`
- Left raw pupil (if present): `L Raw X [px]`, `L Raw Y [px]`
- Right eye (if present): `R POR X [px]`, `R POR Y [px]`, `R Dia X [px]`, `R Dia Y [px]`
- Right raw pupil (if present): `R Raw X [px]`, `R Raw Y [px]`

# Tracking loss encoding
SMI encodes tracking loss and blinks as all-zero rows. NaN gaze values are
written as `0.00` to match that convention.

# Example
```julia
raw = read_smi("session.idf")           # reads IDF binary
write_et_ascii(raw, "session_julia.txt")  # write equivalent TXT
```
"""
function write_et_ascii(smi::SMIFile)
    path = replace(smi.filename, r"\.(idf|txt)$"i => "_exported.txt")
    if path == smi.filename
        path = path * "_exported.txt"
    end
    write_et_ascii(smi, path)
end

function write_et_ascii(smi::SMIFile, path::String)
    df = smi.samples
    nrow(df) > 0 || error("SMIFile has no sample data to write.")

    # ── Detect which eye columns are present and contain data ────────────── #
    has_left = hasproperty(df, :gxL) && any(!isnan, df.gxL)
    has_right = hasproperty(df, :gxR) && any(!isnan, df.gxR)
    has_pupxL = hasproperty(df, :pupxL) && any(!isnan, df.pupxL)
    has_pupxR = hasproperty(df, :pupxR) && any(!isnan, df.pupxR)
    has_trial = hasproperty(df, :trial)
    has_message = hasproperty(df, :message)

    # ── Helper: NaN → 0.0  (SMI tracking-loss convention) ───────────────── #
    _px(v::Real) = isnan(v) ? 0.0 : v

    open(path, "w") do io
        # ── Header ───────────────────────────────────────────────────────── #
        sr_str = isinteger(smi.sample_rate) ? "$(Int(smi.sample_rate))" :
                 @sprintf("%.4f", smi.sample_rate)

        w_px, h_px = smi.screen_res
        w_mm = round(Int, smi.screen_width_cm * 10)
        # Approximate height from aspect ratio if not explicitly stored
        h_mm = round(Int, smi.screen_width_cm * 10 * h_px / w_px)
        d_mm = round(Int, smi.viewing_distance_cm * 10)

        subject = isempty(smi.subject) ? splitext(basename(smi.filename))[1] : smi.subject

        println(io, "## [BeGaze TXT Export — recreated by EyeFun.jl from $(basename(smi.filename))]")
        println(io, "## ")
        println(io, "## Subject:\t$(subject)")
        println(io, "## Sample Rate:\t$(sr_str)")
        println(io, "## Calibration Area:\t$(w_px)\t$(h_px)")
        println(io, "## Stimulus Dimension [mm]:\t$(w_mm)\t$(h_mm)")
        println(io, "## Head Distance [mm]:\t$(d_mm)")
        println(io, "## [Filter Settings]")
        println(io, "## Heuristic:\tFalse")
        println(io, "## Heuristic Stage:\t0")
        println(io, "## Bilateral:\tTrue")
        println(io, "## Gaze Cursor Filter:\tTrue")
        println(io, "## Saccade Length [px]:\t80")
        println(io, "## Filter Depth [ms]:\t20")

        fmt_comps = String[]
        (has_left || has_pupxL) && push!(fmt_comps, "LEFT")
        (has_right || has_pupxR) && push!(fmt_comps, "RIGHT")
        append!(fmt_comps, ["RAW", "DIAMETER", "CR", "POR", "QUALITY", "TRIGGER", "MSG", "FRAMECOUNTER"])
        println(io, "## Format:\t" * join(fmt_comps, ", "))
        println(io, "## ")

        # ── Column header row ─────────────────────────────────────────────── #
        cols = String["Time", "Type", "Trial"]
        if has_left || has_pupxL
            append!(cols, ["L Raw X [px]", "L Raw Y [px]", "L Dia X [px]", "L Dia Y [px]",
                "L CR1 X [px]", "L CR1 Y [px]", "L POR X [px]", "L POR Y [px]"])
        end
        if has_right || has_pupxR
            append!(cols, ["R Raw X [px]", "R Raw Y [px]", "R Dia X [px]", "R Dia Y [px]",
                "R CR1 X [px]", "R CR1 Y [px]", "R POR X [px]", "R POR Y [px]"])
        end
        append!(cols, ["Timing", "Pupil Confidence", "Trigger", "Frame", "Aux1"])
        println(io, join(cols, "\t"))

        # ── Sample rows ───────────────────────────────────────────────────── #
        n = nrow(df)
        for i = 1:n
            # Time: ms → µs (original SMI resolution), integer
            t_us = round(Int64, df.time[i] * 1000.0)
            trial = has_trial ? df.trial[i] : 0
            trig = has_message && !isempty(df.message[i]) ? df.message[i] : "0"

            print(io, t_us, "\tSMP\t", trial)

            if has_left || has_pupxL
                px = has_pupxL ? _px(df.pupxL[i]) : 0.0
                py = has_pupxL ? _px(df.pupyL[i]) : 0.0
                dx = hasproperty(df, :diaxL) && !isnan(df.diaxL[i]) ? df.diaxL[i] : 0.0
                dy = hasproperty(df, :diayL) && !isnan(df.diayL[i]) ? df.diayL[i] : 0.0
                cx = hasproperty(df, :crxL) && !isnan(df.crxL[i]) ? df.crxL[i] : 0.0
                cy = hasproperty(df, :cryL) && !isnan(df.cryL[i]) ? df.cryL[i] : 0.0
                gx = has_left ? _px(df.gxL[i]) : 0.0
                gy = has_left ? _px(df.gyL[i]) : 0.0
                @printf(io, "\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f", px, py, dx, dy, cx, cy, gx, gy)
            end

            if has_right || has_pupxR
                px = has_pupxR ? _px(df.pupxR[i]) : 0.0
                py = has_pupxR ? _px(df.pupyR[i]) : 0.0
                dx = hasproperty(df, :diaxR) && !isnan(df.diaxR[i]) ? df.diaxR[i] : 0.0
                dy = hasproperty(df, :diayR) && !isnan(df.diayR[i]) ? df.diayR[i] : 0.0
                cx = hasproperty(df, :crxR) && !isnan(df.crxR[i]) ? df.crxR[i] : 0.0
                cy = hasproperty(df, :cryR) && !isnan(df.cryR[i]) ? df.cryR[i] : 0.0
                gx = has_right ? _px(df.gxR[i]) : 0.0
                gy = has_right ? _px(df.gyR[i]) : 0.0
                @printf(io, "\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f", px, py, dx, dy, cx, cy, gx, gy)
            end

            # Trailing columns: Timing, Confidence, Trigger, Frame, Aux1
            print(io, "\t0\t0\t", trig, "\t0\t")
            println(io)
        end
    end

    @info "SMI TXT: wrote $(nrow(df)) samples → $path"
    return nothing
end
