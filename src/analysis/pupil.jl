# ── Pupil preprocessing ────────────────────────────────────────────────────── #

"""
    interpolate_blinks!(df::EyeData; eye=:auto, margin_ms=50, method=:linear)

Replace pupil values during blinks (plus a margin before/after) with
interpolated values. Modifies the DataFrame in-place.

`margin_ms` extends the blink window on each side to handle partial blink
artifacts (eyelid droop).

# Methods
- `:linear` — straight line between pre- and post-blink anchors
- `:cubic` — cubic Hermite spline using slopes estimated from nearby samples,
  producing smoother transitions at blink boundaries

# Example
```julia
interpolate_blinks!(df)                # linear (default)
interpolate_blinks!(df; method=:cubic) # smooth cubic spline
interpolate_blinks!(df; margin_ms=100) # wider margin
```
"""
function interpolate_blinks!(
    df::EyeData;
    eye::Symbol = :auto,
    margin_ms::Int = 50,
    method::Symbol = :linear,
)

    method ∉ (:linear, :cubic) && error("Invalid method=:$method. Use :linear or :cubic.")
    !hasproperty(df.df, :in_blink) &&
        error("No :in_blink column. Ensure your DataFrame includes blink annotations.")

    eye = _resolve_eye(df, eye; cols = :pupil)
    pa_col = _eye_columns(eye).pa

    pa = collect(df.df[!, pa_col])
    n = length(pa)

    # Find blink intervals, extend by margin (converted to samples), and merge overlapping
    margin_samples = max(1, round(Int, margin_ms * df.sample_rate / 1000.0))
    intervals = _blink_intervals(df.df.in_blink, margin_samples, n)

    # Interpolate each merged interval
    for (lo, hi) in intervals
        pre_val = lo > 1 ? pa[lo-1] : NaN
        post_val = hi < n ? pa[hi+1] : NaN

        span = hi - lo + 1
        if !isnan(pre_val) && !isnan(post_val)
            if method == :cubic
                m0 = _local_slope(pa, lo - 1, -1) * span
                m1 = _local_slope(pa, hi + 1, +1) * span
                for k = lo:hi
                    t = (k - lo) / max(span - 1, 1)
                    pa[k] = _hermite(t, pre_val, post_val, m0, m1)
                end
            else  # :linear
                for k = lo:hi
                    t = (k - lo) / max(span - 1, 1)
                    pa[k] = pre_val + t * (post_val - pre_val)
                end
            end
        elseif !isnan(pre_val)
            pa[lo:hi] .= pre_val
        elseif !isnan(post_val)
            pa[lo:hi] .= post_val
        end
    end

    df.df[!, pa_col] = pa
    return df
end

# ── Helpers ────────────────────────────────────────────────────────────────── #

"""
    _blink_intervals(bm::AbstractVector{Bool}, margin::Int, n::Int)

Find contiguous runs of `true` in `bm`, extend each by `margin` samples
(clamped to `[1, n]`), and merge any overlapping intervals.
Returns a vector of `(start, end)` pairs.
"""
function _blink_intervals(bm::AbstractVector{Bool}, margin::Int, n::Int)
    intervals = Tuple{Int,Int}[]
    i = 1
    while i <= n
        if bm[i]
            # Scan to end of this blink run
            j = i
            while j <= n && bm[j]
                j += 1
            end
            lo = max(1, i - margin)
            hi = min(n, j - 1 + margin)

            # Merge with previous interval if overlapping
            if !isempty(intervals) && lo <= intervals[end][2] + 1
                intervals[end] = (intervals[end][1], hi)
            else
                push!(intervals, (lo, hi))
            end
            i = j
        else
            i += 1
        end
    end
    return intervals
end


"""Estimate local slope at `idx` using the nearest valid neighbor in direction `dir`."""
function _local_slope(pa, idx::Int, dir::Int)
    n = length(pa)
    j = idx + dir
    while 1 <= j <= n
        !isnan(pa[j]) && return (pa[j] - pa[idx]) / (j - idx)
        j += dir
    end
    return 0.0
end

"""Cubic Hermite basis: interpolate between p0 and p1 with tangents m0, m1 at t ∈ [0,1]."""
function _hermite(t::Float64, p0::Float64, p1::Float64, m0::Float64, m1::Float64)
    return (2t^3 - 3t^2 + 1) * p0 +
           (t^3 - 2t^2 + t) * m0 +
           (-2t^3 + 3t^2) * p1 +
           (t^3 - t^2) * m1
end

"""
    baseline_correct_pupil!(df::EyeData; eye=:auto, window=(-200, 0),
                            method=:subtractive, group_by=:trial)

Baseline-correct the pupil signal for each group (e.g. each trial).

Finds all pupil samples where `time_rel` falls within `window` (default:
-200 ms to 0 ms) and uses them as the baseline reference. After correction,
values represent change from baseline rather than absolute pupil size.

# Methods
- `:subtractive` — `corrected = raw - mean(baseline)` (arbitrary units)
- `:percent` — `corrected = (raw - mean(baseline)) / mean(baseline) × 100` (% change)
- `:zscore` — `corrected = (raw - mean(baseline)) / std(baseline)` (standard deviations)

`:percent` is recommended for group comparisons because it normalises for
individual differences in absolute pupil size.

Requires a `time_rel` column (set via `trial_time_zero` in `create_eyelink_edf_dataframe`).

# Example
```julia
baseline_correct_pupil!(df)                              # subtractive (default)
baseline_correct_pupil!(df; method=:percent)             # % change from baseline
baseline_correct_pupil!(df; method=:zscore)              # z-scored
baseline_correct_pupil!(df; group_by=[:block, :trial])   # multi-block design
```
"""
function baseline_correct_pupil!(
    df::EyeData;
    eye::Symbol = :auto,
    window::Tuple{Real,Real} = (-200, 0),
    method::Symbol = :subtractive,
    group_by = :trial,
)


    method ∉ (:subtractive, :percent, :zscore) &&
        error("Invalid method=:$method. Use :subtractive, :percent, or :zscore.")
    !hasproperty(df.df, :time_rel) && error(
        "No :time_rel column. Ensure your DataFrame includes relative time (e.g. using trial_time_zero).",
    )

    eye = _resolve_eye(df, eye; cols = :pupil)
    pa_col = _eye_columns(eye).pa

    grouped, group_cols = _valid_groups(df, group_by)

    for g in grouped
        idxs = parentindices(g)[1]
        tr = g.time_rel
        pa = g[!, pa_col]

        # Collect baseline pupil values within the time window
        bl = [
            pa[i] for i in eachindex(tr) if
            !ismissing(tr[i]) && !isnan(pa[i]) && window[1] <= tr[i] <= window[2]
        ]
        isempty(bl) && continue

        bl_mean = mean(bl)

        # Compute scale factor for the correction method
        if method == :percent
            bl_mean == 0.0 && continue
            scale = 100.0 / bl_mean
        elseif method == :zscore
            bl_sd = std(bl)
            bl_sd == 0.0 && continue
            scale = 1.0 / bl_sd
        else  # :subtractive
            scale = 1.0
        end

        df.df[idxs, pa_col] .= @. (pa - bl_mean) * scale
    end

    return df
end

"""
    smooth_pupil!(df::EyeData; eye=:auto, window_ms=50)

Apply a moving-average smoothing to the pupil signal. `window_ms` is the
full width of the smoothing window in milliseconds. Modifies in-place.
"""
function smooth_pupil!(df::EyeData; eye::Symbol = :auto, window_ms::Int = 50)
    eye = _resolve_eye(df, eye; cols = :pupil)
    pa_col = _eye_columns(eye).pa

    pa = collect(df.df[!, pa_col])
    n = length(pa)
    half_samples = max(1, div(round(Int, window_ms * df.sample_rate / 1000.0), 2))
    smoothed = similar(pa)

    # Initialize running sum for first window
    s, c = 0.0, 0
    for j = 1:min(n, half_samples)
        if !isnan(pa[j])
            s += pa[j];
            c += 1
        end
    end

    for i = 1:n
        # Add sample entering the window (right edge)
        add = i + half_samples
        if add <= n && !isnan(pa[add])
            s += pa[add];
            c += 1
        end
        # Remove sample leaving the window (left edge)
        rem = i - half_samples - 1
        if rem >= 1 && !isnan(pa[rem])
            s -= pa[rem];
            c -= 1
        end
        smoothed[i] = c > 0 ? s / c : NaN
    end

    df.df[!, pa_col] = smoothed
    return df
end
