"""
    drift_correct!(df::EyeData; target=(640, 480), eye=:auto,
                    use_first_fixation=true, window_ms=200, group_by=:trial)

Apply drift correction by computing the gaze offset from a known fixation
`target` at the start of each group and subtracting it.

# Parameters
- `target`: expected fixation position `(x, y)` in pixels
- `use_first_fixation`: if `true` (default), uses the first fixation's center
  (requires `fix_gavx`/`fix_gavy` columns from event detection).
  If `false`, uses the mean gaze position in the first `window_ms`.
- `window_ms`: duration of the averaging window in milliseconds (default: 200)
- `group_by`: grouping column(s) for per-trial correction (default: `:trial`)

# Example
```julia
drift_correct!(df; target=(960, 540))                            # fixation-based
drift_correct!(df; target=(960, 540), use_first_fixation=false)  # mean-based
```
"""
function drift_correct!(
    df::EyeData;
    target::Tuple{Real,Real} = (640, 480),
    eye::Symbol = :auto,
    use_first_fixation::Bool = true,
    window_ms::Int = 200,
    group_by = :trial,
)
    group_cols = _resolve_group_cols(df, group_by)
    grouped = groupby(df.df, group_cols; skipmissing = true)

    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    tx, ty = Float64(target[1]), Float64(target[2])
    win_samples = round(Int, window_ms / 1000.0 * df.sample_rate)

    for g in grouped
        idxs = parentindices(g)[1]

        offset_x, offset_y = 0.0, 0.0

        if use_first_fixation && hasproperty(g, :fix_gavx)
            col_in_fix = g.in_fix
            col_fx = g.fix_gavx
            col_fy = g.fix_gavy
            for i in eachindex(col_fx)
                if col_in_fix[i] && !isnan(col_fx[i]) && !isnan(col_fy[i])
                    offset_x = col_fx[i] - tx
                    offset_y = col_fy[i] - ty
                    break
                end
            end
        else # Use mean of first window_ms samples 
            gx = g[!, gx_col]
            gy = g[!, gy_col]
            win = min(win_samples, nrow(g))
            sx, sy, c = 0.0, 0.0, 0
            for j = 1:win
                if !isnan(gx[j]) && !isnan(gy[j])
                    sx += gx[j]
                    sy += gy[j]
                    c += 1
                end
            end
            if c > 0
                offset_x = sx / c - tx
                offset_y = sy / c - ty
            end
        end

        df.df[idxs, gx_col] .-= offset_x
        df.df[idxs, gy_col] .-= offset_y
    end

    return df
end
