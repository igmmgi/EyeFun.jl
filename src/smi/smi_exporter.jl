"""
    write_et_ascii(smi::SMIFile, path::String)

Write the sample data in `smi` to an SMI-format tab-separated text file.

The output is compatible with BeGaze's TXT export format so it can be re-imported
or compared against a BeGaze export.

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
function write_et_ascii(smi::SMIFile; verbose::Bool = false)
    path = replace(smi.filename, r"\.(idf|txt)$"i => "_exported.txt")
    if path == smi.filename
        path = path * "_exported.txt"
    end
    write_et_ascii(smi, path; verbose = verbose)
end

function write_et_ascii(smi::SMIFile, path::String; verbose::Bool = false)
    if !isempty(smi.filename) && abspath(path) == abspath(smi.filename)
        error("Refusing to overwrite source file in-place: $path")
    end
    df = smi.samples
    nrow(df) > 0 || error("SMIFile has no sample data to write.")

    has_left = hasproperty(df, :gxL) && any(!isnan, df.gxL)
    has_right = hasproperty(df, :gxR) && any(!isnan, df.gxR)
    has_pupxL = hasproperty(df, :pupxL) && any(!isnan, df.pupxL)
    has_pupxR = hasproperty(df, :pupxR) && any(!isnan, df.pupxR)
    has_paL = hasproperty(df, :paL) && any(!isnan, df.paL)
    has_paR = hasproperty(df, :paR) && any(!isnan, df.paR)
    has_diaxL = hasproperty(df, :diaxL) && any(!isnan, df.diaxL)
    has_diayL = hasproperty(df, :diayL) && any(!isnan, df.diayL)
    has_diaxR = hasproperty(df, :diaxR) && any(!isnan, df.diaxR)
    has_diayR = hasproperty(df, :diayR) && any(!isnan, df.diayR)
    has_crxL = hasproperty(df, :crxL) && any(!isnan, df.crxL)
    has_cryL = hasproperty(df, :cryL) && any(!isnan, df.cryL)
    has_crxR = hasproperty(df, :crxR) && any(!isnan, df.crxR)
    has_cryR = hasproperty(df, :cryR) && any(!isnan, df.cryR)
    write_left = has_left || has_pupxL || has_paL || has_diaxL
    write_right = has_right || has_pupxR || has_paR || has_diaxR
    has_trial = hasproperty(df, :trial)
    has_message = hasproperty(df, :message)

    _px(v::Real) = isnan(v) ? 0.0 : v

    open(path, "w") do io
        sr_str =
            isinteger(smi.sample_rate) ? "$(Int(smi.sample_rate))" :
            @sprintf("%.4f", smi.sample_rate)

        w_px, h_px = smi.screen_res
        w_mm = round(Int, smi.screen_width_cm * 10)
        # Approximate height from aspect ratio if not explicitly stored
        h_mm = round(Int, smi.screen_width_cm * 10 * h_px / w_px)
        d_mm = round(Int, smi.viewing_distance_cm * 10)

        subject = isempty(smi.subject) ? splitext(basename(smi.filename))[1] : smi.subject

        println(
            io,
            "## [BeGaze TXT Export — recreated by EyeFun.jl from $(basename(smi.filename))]",
        )
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
        write_left && push!(fmt_comps, "LEFT")
        write_right && push!(fmt_comps, "RIGHT")
        append!(
            fmt_comps,
            ["RAW", "DIAMETER", "CR", "POR", "QUALITY", "TRIGGER", "MSG", "FRAMECOUNTER"],
        )
        println(io, "## Format:\t" * join(fmt_comps, ", "))
        println(io, "## ")

        cols = String["Time", "Type", "Trial"]
        if write_left
            append!(
                cols,
                [
                    "L Raw X [px]",
                    "L Raw Y [px]",
                    "L Dia X [px]",
                    "L Dia Y [px]",
                    "L CR1 X [px]",
                    "L CR1 Y [px]",
                    "L POR X [px]",
                    "L POR Y [px]",
                ],
            )
        end
        if write_right
            append!(
                cols,
                [
                    "R Raw X [px]",
                    "R Raw Y [px]",
                    "R Dia X [px]",
                    "R Dia Y [px]",
                    "R CR1 X [px]",
                    "R CR1 Y [px]",
                    "R POR X [px]",
                    "R POR Y [px]",
                ],
            )
        end
        append!(cols, ["Timing", "Pupil Confidence", "Trigger", "Frame", "Aux1"])
        println(io, join(cols, "\t"))

        n = nrow(df)
        for i = 1:n
            # Time: ms → µs (original SMI resolution), integer
            t_us = round(Int64, df.time[i] * 1000.0)
            trial = has_trial && !ismissing(df.trial[i]) ? df.trial[i] : 0
            trig = "0"
            if has_message && !ismissing(df.message[i]) && !isempty(df.message[i])
                raw_m = df.message[i]
                for part in eachsplit(raw_m, "; ")
                    sp = strip(part)
                    isempty(sp) && continue
                    if all(b -> UInt8('0') <= b <= UInt8('9'), codeunits(sp))
                        trig = sp
                    else
                        println(io, t_us, "\tMSG\t", trial, "\t# Message: ", sp)
                    end
                end
            end

            print(io, t_us, "\tSMP\t", trial)

            if write_left
                px = has_pupxL ? _px(df.pupxL[i]) : 0.0
                py = has_pupxL ? _px(df.pupyL[i]) : 0.0
                dx = has_diaxL ? _px(df.diaxL[i]) : (has_paL ? _px(df.paL[i]) : 0.0)
                dy = has_diayL ? _px(df.diayL[i]) : (has_paL ? _px(df.paL[i]) : 0.0)
                cx = has_crxL ? _px(df.crxL[i]) : 0.0
                cy = has_cryL ? _px(df.cryL[i]) : 0.0
                gx = has_left ? _px(df.gxL[i]) : 0.0
                gy = has_left ? _px(df.gyL[i]) : 0.0
                @printf(
                    io,
                    "\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f",
                    px,
                    py,
                    dx,
                    dy,
                    cx,
                    cy,
                    gx,
                    gy
                )
            end

            if write_right
                px = has_pupxR ? _px(df.pupxR[i]) : 0.0
                py = has_pupxR ? _px(df.pupyR[i]) : 0.0
                dx = has_diaxR ? _px(df.diaxR[i]) : (has_paR ? _px(df.paR[i]) : 0.0)
                dy = has_diayR ? _px(df.diayR[i]) : (has_paR ? _px(df.paR[i]) : 0.0)
                cx = has_crxR ? _px(df.crxR[i]) : 0.0
                cy = has_cryR ? _px(df.cryR[i]) : 0.0
                gx = has_right ? _px(df.gxR[i]) : 0.0
                gy = has_right ? _px(df.gyR[i]) : 0.0
                @printf(
                    io,
                    "\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f",
                    px,
                    py,
                    dx,
                    dy,
                    cx,
                    cy,
                    gx,
                    gy
                )
            end

            # Trailing columns: Timing, Confidence, Trigger, Frame, Aux1
            print(io, "\t0\t0\t", trig, "\t0\t")
            println(io)
        end
    end

    verbose && @info "SMI TXT: wrote $(nrow(df)) samples to $path"
    return nothing
end
