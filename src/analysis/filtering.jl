"""
    velocity_filter!(df::EyeData; eye=:auto, threshold_deg_s=1000.0)

Replace gaze samples with implausibly high velocity with `NaN`.

Velocity is computed using the 5-sample central difference. Samples exceeding
the threshold (default: 1000°/s) are set to `NaN`.

Returns the number of samples removed.

# Example
```julia
n_removed = velocity_filter!(df; threshold_deg_s=800)
```
"""
function velocity_filter!(df::EyeData; eye::Symbol = :auto, threshold_deg_s::Real = 1000.0)
    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    ppd = pixels_per_degree(df)
    gx = df.df[!, gx_col]
    gy = df.df[!, gy_col]

    vel = _compute_velocity_deg(gx, gy, ppd, df.sample_rate)

    mask = .!isnan.(vel) .& (vel .> threshold_deg_s)
    gx[mask] .= NaN
    gy[mask] .= NaN

    return count(mask)
end

"""
    outlier_filter!(df::EyeData; eye=:auto,
                    bounds=nothing, margin=50)

Replace off-screen gaze samples with `NaN`.

By default uses screen resolution as bounds. Samples outside
`(-margin, width+margin, -margin, height+margin)` are removed.

Returns the number of samples removed.

# Example
```julia
n_removed = outlier_filter!(df)  # uses screen_res
n_removed = outlier_filter!(df; bounds=(0, 1280, 0, 960), margin=0)
```
"""
function outlier_filter!(
    df::EyeData;
    eye::Symbol = :auto,
    bounds::Union{Nothing,NTuple{4,Real}} = nothing,
    margin::Real = 50,
)
    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    # Default bounds from screen resolution
    if isnothing(bounds)
        w, h = df.screen_res
        x_lo, x_hi = -margin, w + margin
        y_lo, y_hi = -margin, h + margin
    else
        x_lo, x_hi, y_lo, y_hi = bounds
        x_lo -= margin
        x_hi += margin
        y_lo -= margin
        y_hi += margin
    end

    gx = df.df[!, gx_col]
    gy = df.df[!, gy_col]

    mask = .!isnan.(gx) .& ((gx .< x_lo) .| (gx .> x_hi) .| (gy .< y_lo) .| (gy .> y_hi))
    gx[mask] .= NaN
    gy[mask] .= NaN
    n_removed = count(mask)

    return n_removed
end

"""
    interpolate_gaps!(df::EyeData; eye=:auto, max_gap_ms=75)

Linearly interpolate short tracking-loss gaps (NaN runs) in gaze data.

Unlike `interpolate_blinks!` which targets blink-flagged periods, this fills
any short NaN gap in gaze coordinates regardless of cause.

Returns the number of gaps interpolated.

# Example
```julia
n_filled = interpolate_gaps!(df; max_gap_ms=100)
```
"""
function interpolate_gaps!(df::EyeData; eye::Symbol = :auto, max_gap_ms::Real = 75)
    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    max_gap_samples = round(Int, max_gap_ms * df.sample_rate / 1000.0)
    n_filled = 0

    for col in (gx_col, gy_col)
        vals = df.df[!, col]
        n = length(vals)
        i = 1
        while i <= n
            if isnan(vals[i])
                # Find gap extent
                gap_start = i
                while i <= n && isnan(vals[i])
                    i += 1
                end
                gap_end = i - 1
                gap_len = gap_end - gap_start + 1

                # Only interpolate if gap is short and bounded by valid samples
                if gap_len <= max_gap_samples && gap_start > 1 && gap_end < n
                    v_before = vals[gap_start-1]
                    v_after = vals[gap_end+1]
                    if !isnan(v_before) && !isnan(v_after)
                        for j = gap_start:gap_end
                            frac = (j - gap_start + 1) / (gap_len + 1)
                            vals[j] = v_before + frac * (v_after - v_before)
                        end
                        col == gx_col && (n_filled += 1)  # count once per gap
                    end
                end
            else
                i += 1
            end
        end
    end

    return n_filled
end
