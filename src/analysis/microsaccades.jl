# ── detect_microsaccades! ──────────────────────────────────────────────────── #

"""
    detect_microsaccades!(df::EyeData; eye=:auto, lambda=6.0,
                           min_duration_ms=6, max_amplitude=2.0, group_by=:trial)

Detect microsaccades using the Engbert & Kliegl (2003) velocity-based algorithm.
Adds columns to the DataFrame:

- `in_msacc` — Bool, true during a microsaccade
- `msacc_dx`, `msacc_dy` — microsaccade direction (start → end, in pixels)
- `msacc_ampl` — microsaccade amplitude (pixels)
- `msacc_pvel` — microsaccade peak velocity (px/sample)

# Parameters
- `lambda`: velocity threshold multiplier (default: 6σ)
- `min_duration_ms`: minimum duration in ms (default: 6)
- `max_amplitude`: maximum amplitude in degrees for classification (default: 2.0°);
  set to `Inf` to detect all saccade-like events
- `group_by`: grouping column(s) for per-trial detection (default: `:trial`)
"""
function detect_microsaccades!(
    df::EyeData;
    eye::Symbol = :auto,
    lambda::Real = 6.0,
    min_duration_ms::Int = 6,
    max_amplitude::Real = 2.0,
    group_by = :trial,
)
    group_cols = _resolve_group_cols(df, group_by)

    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    n = nrow(df.df)
    in_msacc = falses(n)
    msacc_dx = fill(NaN, n)
    msacc_dy = fill(NaN, n)
    msacc_ampl = fill(NaN, n)
    msacc_pvel = fill(NaN, n)

    # Compute pixels per degree from metadata
    ppd = df.screen_res[1] / (2.0 * atand(df.screen_width_cm / 2.0, df.viewing_distance_cm))

    valid_df = filter(r -> all(s -> !ismissing(r[s]), group_cols), df.df)

    for g in groupby(valid_df, group_cols)
        idxs = parentindices(g)[1]
        gx = collect(g[!, gx_col])
        gy = collect(g[!, gy_col])
        nt = length(gx)
        nt < 5 && continue

        # ── Compute 2D velocity using central difference ──
        vx = fill(NaN, nt)
        vy = fill(NaN, nt)
        for i = 3:(nt-2)
            if !any(isnan, (gx[i-2], gx[i-1], gx[i+1], gx[i+2]))
                vx[i] = (gx[i+2] + gx[i+1] - gx[i-1] - gx[i-2]) / 6.0
                vy[i] = (gy[i+2] + gy[i+1] - gy[i-1] - gy[i-2]) / 6.0
            end
        end

        # ── Compute velocity threshold (median-based σ) ──
        n_valid = count(!isnan, vx)
        n_valid < 10 && continue
        valid_vx = filter(!isnan, vx)
        valid_vy = filter(!isnan, vy)

        σx = sqrt(max(0.0, median(valid_vx .^ 2) - median(valid_vx)^2))
        σy = sqrt(max(0.0, median(valid_vy .^ 2) - median(valid_vy)^2))
        σx = max(σx, 1e-10)
        σy = max(σy, 1e-10)

        thresh_x = lambda * σx
        thresh_y = lambda * σy

        # ── Detect and classify in a single pass ──
        _above(i) =
            !isnan(vx[i]) &&
            !isnan(vy[i]) &&
            (vx[i] / thresh_x)^2 + (vy[i] / thresh_y)^2 > 1.0

        i = 1
        while i <= nt
            if _above(i)
                # Found onset — scan to offset
                onset = i
                while i <= nt && _above(i)
                    i += 1
                end
                offset = i - 1
                dur = offset - onset + 1

                # Minimum duration check
                dur < min_duration_ms && continue

                # Amplitude check
                dx = gx[offset] - gx[onset]
                dy = gy[offset] - gy[onset]
                ampl = sqrt(dx^2 + dy^2)
                ampl / ppd > max_amplitude && continue

                # Peak velocity
                pvel = 0.0
                for k = onset:offset
                    spd = sqrt(vx[k]^2 + vy[k]^2)
                    spd > pvel && (pvel = spd)
                end

                # Mark in output arrays
                for j = idxs[onset]:idxs[offset]
                    in_msacc[j] = true
                    msacc_dx[j] = dx
                    msacc_dy[j] = dy
                    msacc_ampl[j] = ampl
                    msacc_pvel[j] = pvel
                end
            else
                i += 1
            end
        end
    end

    df.df[!, :in_msacc] = in_msacc
    df.df[!, :msacc_dx] = msacc_dx
    df.df[!, :msacc_dy] = msacc_dy
    df.df[!, :msacc_ampl] = msacc_ampl
    df.df[!, :msacc_pvel] = msacc_pvel

    return df
end
