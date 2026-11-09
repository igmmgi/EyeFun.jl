"""Estimate local slope at `idx` using up to 5 valid samples in direction `dir` within `[seg_lo, seg_hi]`."""
function _local_slope(
    pa::AbstractVector{<:AbstractFloat},
    idx::Int,
    dir::Int,
    seg_lo::Int = 1,
    seg_hi::Int = length(pa),
)
    p0 = Float64(pa[idx])
    j_far = 0
    steps = 0
    j = idx + dir
    @inbounds while seg_lo <= j <= seg_hi && steps < 5
        if !isnan(pa[j])
            j_far = j
        end
        steps += 1
        j += dir
    end
    if j_far == 0
        # Fallback: search further within [seg_lo, seg_hi] if immediate neighbors were NaN
        j = idx + dir * 6
        @inbounds while seg_lo <= j <= seg_hi
            if !isnan(pa[j])
                j_far = j
                break
            end
            j += dir
        end
    end
    j_far == 0 && return 0.0
    return (Float64(pa[j_far]) - p0) / (j_far - idx)
end

"""Cubic Hermite basis: interpolate between p0 and p1 with tangents m0, m1 at t ∈ [0,1]."""
@inline function _hermite(t::Float64, p0::Float64, p1::Float64, m0::Float64, m1::Float64)
    t2 = t * t
    t3 = t2 * t
    return (2t3 - 3t2 + 1.0) * p0 +
           (t3 - 2t2 + t) * m0 +
           (-2t3 + 3t2) * p1 +
           (t3 - t2) * m1
end

function _blink_intervals!(
    intervals::Vector{Tuple{Int,Int}},
    bm::AbstractVector{Bool},
    margin::Int,
    seg_lo::Int,
    seg_hi::Int,
)
    empty!(intervals)
    i = seg_lo
    @inbounds while i <= seg_hi
        if bm[i]
            j = i + 1
            while j <= seg_hi && bm[j]
                j += 1
            end
            lo = max(seg_lo, i - margin)
            hi = min(seg_hi, j - 1 + margin)
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

function _interpolate_blinks_range!(
    pa::Vector{T},
    bm::AbstractVector{Bool},
    intervals::Vector{Tuple{Int,Int}},
    seg_lo::Int,
    seg_hi::Int,
    margin_samples::Int,
    is_cubic::Bool,
) where {T<:AbstractFloat}
    _blink_intervals!(intervals, bm, margin_samples, seg_lo, seg_hi)

    @inbounds for (lo, hi) in intervals
        pre_val = lo > seg_lo ? Float64(pa[lo-1]) : NaN
        post_val = hi < seg_hi ? Float64(pa[hi+1]) : NaN

        span = hi - lo + 1
        denom = Float64(span + 1)
        if !isnan(pre_val) && !isnan(post_val)
            if is_cubic
                m0 = _local_slope(pa, lo - 1, -1, seg_lo, seg_hi) * denom
                m1 = _local_slope(pa, hi + 1, +1, seg_lo, seg_hi) * denom
                for k = lo:hi
                    t = (k - lo + 1) / denom
                    pa[k] = T(_hermite(t, pre_val, post_val, m0, m1))
                end
            else
                diff = post_val - pre_val
                for k = lo:hi
                    t = (k - lo + 1) / denom
                    pa[k] = T(pre_val + t * diff)
                end
            end
        elseif !isnan(pre_val)
            pv = T(pre_val)
            for k = lo:hi
                pa[k] = pv
            end
        elseif !isnan(post_val)
            pv = T(post_val)
            for k = lo:hi
                pa[k] = pv
            end
        end
    end
    return pa
end

"""
    interpolate_blinks!(df::EyeData; eye=:auto, margin_ms=50, method=:linear)

Replace pupil values during blinks (plus a margin before/after) with
interpolated values within each `(participant, trial)` segment. Modifies the DataFrame in-place.

`margin_ms` extends the blink window on each side to handle partial blink
artifacts (eyelid droop).

# Methods
- `:linear`: straight line between pre- and post-blink anchors
- `:cubic`: cubic Hermite spline using slopes estimated from nearby samples,
  producing smoother transitions at blink boundaries
"""
function interpolate_blinks!(
    df::EyeData;
    eye::Symbol = :auto,
    margin_ms::Int = 50,
    method::Symbol = :linear,
    prefix::Union{Nothing,Symbol} = nothing,
)
    if method ∉ (:linear, :cubic)
        error("Invalid method=:$method. Use :linear or :cubic.")
    end
    c_blink = _prefixed_sym(prefix, :in_blink)
    if !hasproperty(df.df, c_blink)
        error("No :$c_blink column. Run detect_events!(df) first or provide blink annotations.")
    end

    eye = _resolve_eye(df, eye; cols = :pupil)
    _ensure_eye_cols!(df, eye; cols = :pupil)
    pa_col = _eye_columns(eye).pa

    pa_src = _as_float_vec(df.df[!, pa_col])
    pa = copy(pa_src)
    margin_samples = max(1, round(Int, margin_ms * df.sample_rate / 1000.0))
    bm = df.df[!, c_blink]
    is_cubic = (method == :cubic)
    intervals = Tuple{Int,Int}[]
    _foreach_trial_segment(df.df) do lo, hi
        _interpolate_blinks_range!(pa, bm, intervals, lo, hi, margin_samples, is_cubic)
    end

    df.df[!, pa_col] = pa
    return df
end

function _baseline_correct_group!(
    pa_all::AbstractVector{T},
    t_buf::Vector{Float64},
    idxs::AbstractVector{Int},
    m::Int,
    w_lo::Float64,
    w_hi::Float64,
    method::Symbol,
) where {T<:AbstractFloat}
    (isnan(w_lo) || isnan(w_hi)) && return nothing
    cnt = 0
    s = 0.0
    @inbounds for j = 1:m
        tf = t_buf[j]
        pk = Float64(pa_all[idxs[j]])
        if !isnan(tf) && !isnan(pk) && w_lo <= tf <= w_hi
            s += pk
            cnt += 1
        end
    end
    cnt == 0 && return nothing
    bl_mean = s / cnt

    scale = if method == :percent
        bl_mean == 0.0 && return nothing
        100.0 / bl_mean
    elseif method == :zscore
        cnt < 2 && return nothing
        ss = 0.0
        @inbounds for j = 1:m
            tf = t_buf[j]
            pk = Float64(pa_all[idxs[j]])
            if !isnan(tf) && !isnan(pk) && w_lo <= tf <= w_hi
                d = pk - bl_mean
                ss += d * d
            end
        end
        bl_sd = sqrt(ss / (cnt - 1))
        (isnan(bl_sd) || bl_sd == 0.0) && return nothing
        1.0 / bl_sd
    else
        1.0
    end

    @inbounds for j = 1:m
        k = idxs[j]
        pa_all[k] = T((Float64(pa_all[k]) - bl_mean) * scale)
    end
    return nothing
end

"""
    baseline_correct_pupil!(df::EyeData; eye=:auto, window=(-200, 0),
                            method=:subtractive, group_by=:auto)

Baseline-correct the pupil signal for each group (e.g. each trial).

Finds all pupil samples where relative time falls within `window` (default:
`-200` ms to `0` ms; also accepts per-trial column symbol tuples such as
`(:baseline_start, :baseline_end)`) and uses them as the baseline reference.
Uses `:time_rel` when available, falling back to `time .- time[1]` within each group.

# Methods
- `:subtractive`: `corrected = raw - mean(baseline)` (arbitrary units)
- `:percent`: `corrected = (raw - mean(baseline)) / mean(baseline) × 100` (% change)
- `:zscore`: `corrected = (raw - mean(baseline)) / std(baseline)` (standard deviations)
"""
function baseline_correct_pupil!(
    df::EyeData;
    eye::Symbol = :auto,
    window::Tuple = (-200, 0),
    method::Symbol = :subtractive,
    group_by = :auto,
)
    if method ∉ (:subtractive, :percent, :zscore)
        error("Invalid method=:$method. Use :subtractive, :percent, or :zscore.")
    end

    eye = _resolve_eye(df, eye; cols = :pupil)
    _ensure_eye_cols!(df, eye; cols = :pupil)
    pa_col = _eye_columns(eye).pa
    pa_vec = df.df[!, pa_col]
    if !(eltype(pa_vec) <: AbstractFloat)
        pa_vec = Float64[ismissing(v) ? NaN : Float64(v) for v in pa_vec]
        df.df[!, pa_col] = pa_vec
    end

    d = df.df
    has_trel = _has_active_time_rel(d)
    trel_col = has_trel ? d[!, :time_rel] : nothing
    time_col = d[!, :time]

    group_cols = _resolve_group_cols(df, group_by)
    grouped = groupby(d, group_cols; skipmissing = true)

    t_buf = Float64[]
    for g in grouped
        idxs = parentindices(g)[1]
        isempty(idxs) && continue
        m = _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, idxs)
        w_lo, w_hi = _resolve_time_window_rows(d, idxs[1], window)
        _baseline_correct_group!(pa_vec, t_buf, idxs, m, w_lo, w_hi, method)
    end

    return df
end

function _smooth_pupil_range!(
    smoothed::Vector{T},
    pa::AbstractVector{T},
    lo::Int,
    hi::Int,
    half_samples::Int,
) where {T<:AbstractFloat}
    lo > hi && return smoothed

    s = 0.0
    c = 0
    init_hi = min(hi, lo + half_samples - 1)
    @inbounds for j = lo:init_hi
        pj = Float64(pa[j])
        if !isnan(pj)
            s += pj
            c += 1
        end
    end

    NaNT = T(NaN)
    @inbounds for i = lo:hi
        add = i + half_samples
        if add <= hi
            pa_add = Float64(pa[add])
            if !isnan(pa_add)
                s += pa_add
                c += 1
            end
        end
        rem = i - half_samples - 1
        if rem >= lo
            pa_rem = Float64(pa[rem])
            if !isnan(pa_rem)
                s -= pa_rem
                c -= 1
            end
        end
        if c == 0
            s = 0.0  # reset running sum across NaN intervals to avoid float drift
            smoothed[i] = NaNT
        elseif isnan(pa[i])
            smoothed[i] = NaNT
        else
            smoothed[i] = T(s / c)
        end
    end
    return smoothed
end

"""
    smooth_pupil!(df::EyeData; eye=:auto, window_ms=50,
                  method=:moving_average, poly_order=2)

Smooth the pupil signal within each `(participant, trial)` segment using either a
moving-average (`method = :moving_average`) or Savitzky-Golay polynomial filter
(`method = :savgol`). `window_ms` is the full width of the smoothing window in
milliseconds. Preserves `NaN` at uninterpolated missing/blink samples so valid
neighbors do not dilate into `NaN` gaps. Modifies in-place and returns `df`.
"""
function smooth_pupil!(
    df::EyeData;
    eye::Symbol = :auto,
    window_ms::Int = 50,
    method::Symbol = :moving_average,
    poly_order::Int = 2,
)
    window_ms > 0 || throw(ArgumentError("window_ms must be positive (got $window_ms)."))
    method in (:moving_average, :savgol) || throw(
        ArgumentError("Invalid method=:$method. Use :moving_average or :savgol."),
    )
    eye = _resolve_eye(df, eye; cols = :pupil)
    _ensure_eye_cols!(df, eye; cols = :pupil)
    pa_col = _eye_columns(eye).pa

    if method == :savgol
        poly_order >= 0 ||
            throw(ArgumentError("poly_order must be non-negative (got $poly_order)."))
        w = round(Int, window_ms * df.sample_rate / 1000.0)
        iseven(w) && (w += 1)
        min_odd = max(3, poly_order + 1 + iseven(poly_order + 1))
        w = max(w, min_odd)
        _savgol_smooth_col!(df.df, pa_col, w, poly_order)
        return df
    end

    pa = _as_float_vec(df.df[!, pa_col])
    n = length(pa)
    smoothed = Vector{eltype(pa)}(undef, n)
    half_samples = max(1, div(round(Int, window_ms * df.sample_rate / 1000.0), 2))
    _foreach_trial_segment(df.df) do lo, hi
        _smooth_pupil_range!(smoothed, pa, lo, hi, half_samples)
    end
    df.df[!, pa_col] = smoothed
    return df
end

function _pupil_peak_kernel(
    tr::Vector{Float64},
    pa_all::AbstractVector{<:Real},
    rows::AbstractVector{Int},
    m::Int,
    has_tw::Bool,
    tw_start::Float64,
    tw_end::Float64,
)
    t_start = has_tw ? tw_start : 0.0
    sum_val = 0.0
    cnt = 0
    min_val = Inf
    max_val = -Inf
    max_time = NaN

    @inbounds for k = 1:m
        t = tr[k]
        p = Float64(pa_all[rows[k]])
        (isnan(t) || isnan(p)) && continue
        if has_tw && (t < tw_start || t > tw_end)
            continue
        end
        sum_val += p
        cnt += 1
        p < min_val && (min_val = p)
        if p > max_val
            max_val = p
            max_time = t
        end
    end

    if cnt == 0
        return (;
            mean_pupil = NaN,
            max_pupil = NaN,
            min_pupil = NaN,
            max_pupil_time = NaN,
            time_to_peak = NaN,
        )
    end

    return (;
        mean_pupil = round(sum_val / cnt; digits = 4),
        max_pupil = round(max_val; digits = 4),
        min_pupil = round(min_val; digits = 4),
        max_pupil_time = round(max_time; digits = 1),
        time_to_peak = round(max_time - t_start; digits = 1),
    )
end

"""
    pupil_peak_metrics(df::EyeData; selection=nothing, group_by=:auto,
                       eye=:auto, time_window=nothing)

Compute pupil summary metrics (`mean_pupil`, `max_pupil`, `min_pupil`,
`max_pupil_time`, `time_to_peak`) for each group within an optional time window.
"""
function pupil_peak_metrics(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :auto,
    time_window::Union{Nothing,Tuple} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)
    eye = _resolve_eye(samples, eye; cols = :pupil)
    d = df.df
    pa_all = _get_pupil_vec(d, eye)
    has_trel = _has_active_time_rel(d)
    trel_col = has_trel ? d[!, :time_rel] : nothing
    time_col = d[!, :time]
    has_tw = !isnothing(time_window)

    ng = length(grouped)
    row_first_idx = Vector{Int}(undef, ng)
    mean_v = Vector{Float64}(undef, ng)
    max_v = Vector{Float64}(undef, ng)
    min_v = Vector{Float64}(undef, ng)
    maxt_v = Vector{Float64}(undef, ng)
    ttp_v = Vector{Float64}(undef, ng)
    t_buf = Float64[]

    @inbounds for gi = 1:ng
        rows = parentindices(grouped[gi])[1]
        row_first_idx[gi] = rows[1]
        m = _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, rows)
        tw_s, tw_e = has_tw ? _resolve_time_window_rows(d, rows[1], time_window) : (0.0, 0.0)
        pk = _pupil_peak_kernel(t_buf, pa_all, rows, m, has_tw, tw_s, tw_e)
        mean_v[gi] = pk.mean_pupil
        max_v[gi] = pk.max_pupil
        min_v[gi] = pk.min_pupil
        maxt_v[gi] = pk.max_pupil_time
        ttp_v[gi] = pk.time_to_peak
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :mean_pupil => mean_v)
    push!(pairs_out, :max_pupil => max_v)
    push!(pairs_out, :min_pupil => min_v)
    push!(pairs_out, :max_pupil_time => maxt_v)
    push!(pairs_out, :time_to_peak => ttp_v)
    return DataFrame(pairs_out; copycols = false)
end

function _pupil_filter_segment!(
    pa::AbstractVector{T},
    times::AbstractVector{<:Real},
    bad::BitVector,
    speed_buf::Vector{Float64},
    mad_buf::Vector{Float64},
    lo::Int,
    hi::Int,
    mad_mult::Float64,
    margin_samples::Int,
    max_interp_ms::Float64,
    min_pupil::Float64,
)::Int where {T<:AbstractFloat}
    m = hi - lo + 1
    m <= 0 && return 0
    length(bad) < m && resize!(bad, m)
    fill!(view(bad, 1:m), false)

    n_rejected = 0
    NaNT = T(NaN)

    # Reject non-positive pupil values (e.g. 0.0 during tracking loss)
    @inbounds for k = lo:hi
        pk = Float64(pa[k])
        if !isnan(pk) && pk <= min_pupil
            pa[k] = NaNT
            bad[k-lo+1] = true
            n_rejected += 1
        elseif isnan(pk)
            bad[k-lo+1] = true
        end
    end

    # Kret & Sjak-Shie (2019) normalized dilation speed d'[i]
    # d'[i] = max(|(p[i] - p[prev]) / (t[i] - t[prev])|, |(p[next] - p[i]) / (t[next] - t[i])|)
    length(speed_buf) < m && resize!(speed_buf, m)
    fill!(view(speed_buf, 1:m), NaN)

    prev_idx = 0
    @inbounds for k = lo:hi
        idx_loc = k - lo + 1
        pk = Float64(pa[k])
        isnan(pk) && continue
        if prev_idx > 0
            dt = Float64(times[k]) - Float64(times[prev_idx])
            if dt > 0.0
                spd = abs(pk - Float64(pa[prev_idx])) / dt
                s_prev = speed_buf[prev_idx-lo+1]
                speed_buf[prev_idx-lo+1] = isnan(s_prev) ? spd : max(s_prev, spd)
                speed_buf[idx_loc] = spd
            end
        end
        prev_idx = k
    end

    n_spd = 0
    length(mad_buf) < m && resize!(mad_buf, m)
    @inbounds for j = 1:m
        sv = speed_buf[j]
        if !isnan(sv)
            n_spd += 1
            mad_buf[n_spd] = sv
        end
    end

    if n_spd >= 4
        med_d = median!(@view mad_buf[1:n_spd])
        @inbounds for j = 1:n_spd
            mad_buf[j] = abs(mad_buf[j] - med_d)
        end
        mad_d = median!(@view mad_buf[1:n_spd])
        thresh = med_d + max(mad_mult * mad_d, 1e-9)

        @inbounds for j = 1:m
            sv = speed_buf[j]
            if !isnan(sv) && sv > thresh
                bad[j] = true
            end
        end
    end

    # Expand edge margin around rejected/missing intervals
    if margin_samples > 0
        j = 1
        @inbounds while j <= m
            if bad[j]
                r_end = j + 1
                while r_end <= m && bad[r_end]
                    r_end += 1
                end
                pad_lo = max(1, j - margin_samples)
                pad_hi = min(m, r_end - 1 + margin_samples)
                for p = pad_lo:pad_hi
                    if !isnan(pa[lo+p-1])
                        pa[lo+p-1] = NaNT
                        n_rejected += 1
                    end
                end
                j = r_end
            else
                j += 1
            end
        end
    else
        @inbounds for j = 1:m
            if bad[j] && !isnan(pa[lo+j-1])
                pa[lo+j-1] = NaNT
                n_rejected += 1
            end
        end
    end

    # Linear interpolation across gaps <= max_interp_ms
    if max_interp_ms > 0.0
        k = lo
        @inbounds while k <= hi
            if isnan(pa[k])
                g_end = k + 1
                while g_end <= hi && isnan(pa[g_end])
                    g_end += 1
                end
                if k > lo && g_end <= hi
                    t0 = Float64(times[k-1])
                    t1 = Float64(times[g_end])
                    gap_ms = t1 - t0
                    if gap_ms > 0.0 && gap_ms <= max_interp_ms
                        p0 = Float64(pa[k-1])
                        dp = Float64(pa[g_end]) - p0
                        inv_dt = 1.0 / gap_ms
                        for q = k:(g_end-1)
                            pa[q] = T(p0 + (Float64(times[q]) - t0) * inv_dt * dp)
                        end
                    end
                end
                k = g_end
            else
                k += 1
            end
        end
    end

    return n_rejected
end

"""
    pupil_filter!(df::EyeData; eye=:auto, mad_multiplier=16.0, margin_ms=50,
                  max_interp_ms=0, min_pupil=0.0) -> Int

Detect and remove pupil-size artifacts within each `(participant, trial)` segment using
the Kret & Sjak-Shie (2019) Median Absolute Deviation (MAD) dilation-speed criterion
plus edge-artifact padding around blink/dropout boundaries.

Samples with `pupil <= min_pupil` or normalized dilation speed exceeding
`median(d') + mad_multiplier * MAD(d')` are marked invalid (`NaN`), expanded by
`margin_ms` on both sides to eliminate partial-occlusion edge droop, and optionally
linearly interpolated when gap duration is `<= max_interp_ms`.

Returns the total number of previously valid pupil samples set to `NaN`.
"""
function pupil_filter!(
    df::EyeData;
    eye::Symbol = :auto,
    mad_multiplier::Real = 16.0,
    margin_ms::Real = 50,
    max_interp_ms::Real = 0,
    min_pupil::Real = 0.0,
)::Int
    mad_multiplier > 0 ||
        throw(ArgumentError("mad_multiplier must be positive (got $mad_multiplier)."))
    margin_ms >= 0 ||
        throw(ArgumentError("margin_ms must be non-negative (got $margin_ms)."))
    max_interp_ms >= 0 ||
        throw(ArgumentError("max_interp_ms must be non-negative (got $max_interp_ms)."))

    resolved = _resolve_eye(df, eye; cols = :pupil)
    _ensure_eye_cols!(df, resolved; cols = :pupil)
    pa_col = _eye_columns(resolved).pa
    d = df.df

    pa_src = _as_float_vec(d[!, pa_col])
    pa = copy(pa_src)
    times = d[!, :time]
    sr = df.sample_rate > 0.0 ? df.sample_rate : 1000.0
    margin_samples = round(Int, Float64(margin_ms) * sr / 1000.0)
    mad_mult = Float64(mad_multiplier)
    max_int_ms = Float64(max_interp_ms)
    min_p = Float64(min_pupil)

    bad = BitVector()
    speed_buf = Float64[]
    mad_buf = Float64[]
    total_rejected = 0

    _foreach_trial_segment(d) do lo, hi
        total_rejected += _pupil_filter_segment!(
            pa,
            times,
            bad,
            speed_buf,
            mad_buf,
            lo,
            hi,
            mad_mult,
            margin_samples,
            max_int_ms,
            min_p,
        )
        return nothing
    end

    d[!, pa_col] = pa
    return total_rejected
end

"""
    correct_pupil_foreshortening!(df::EyeData; eye=:auto, camera_pos=nothing,
                                  measure=:auto) -> EyeData

Apply geometric pupil foreshortening error (PFE) correction (Brisson et al., 2013;
Hayes & Petrov, 2016) based on the 3D angle `α` between the eye-to-gaze vector and
the eye-to-camera axis.

When the eye rotates off-axis by angle `α`, the circular pupil projects as an ellipse
whose apparent area scales by `cos(α)`. Depending on `measure`:
- `:area`: multiplies pupil values by `1 / cos(α)` (default for EyeLink/SMI area data)
- `:diameter`: multiplies pupil values by `1 / sqrt(cos(α))` (default when `df.source == :tobii`)
- `:auto`: selects `:diameter` for `:tobii` and `:area` otherwise

`camera_pos` specifies the camera position `(cam_x_cm, cam_y_cm)` (or 3D
`(cam_x_cm, cam_y_cm, cam_z_cm)`) in physical centimeters relative to screen center;
defaults to `(0.0, 0.0, df.viewing_distance_cm)` (optical axis aligned with screen center).
Modifies `df` in-place and returns `df`.
"""
function correct_pupil_foreshortening!(
    df::EyeData;
    eye::Symbol = :auto,
    camera_pos::Union{Nothing,Tuple{Real,Real},Tuple{Real,Real,Real}} = nothing,
    measure::Symbol = :auto,
)
    measure in (:auto, :area, :diameter) ||
        throw(ArgumentError("Invalid measure=:$measure. Expected :auto, :area, or :diameter."))

    resolved = _resolve_eye(df, eye; cols = :pupil)
    _ensure_eye_cols!(df, resolved; cols = :pupil)
    _ensure_eye_cols!(df, resolved; cols = :gaze)
    ecols = _eye_columns(resolved)
    d = df.df

    (hasproperty(d, ecols.gx) && hasproperty(d, ecols.gy)) ||
        error("Gaze columns ($(ecols.gx), $(ecols.gy)) required for foreshortening correction.")

    w_px, h_px = df.screen_res
    w_cm = df.screen_width_cm
    dist_cm = df.viewing_distance_cm
    (w_px > 0 && h_px > 0 && w_cm > 0.0 && dist_cm > 0.0) ||
        throw(ArgumentError("Valid positive screen_res, screen_width_cm, and viewing_distance_cm are required."))

    cm_per_px = w_cm / Float64(w_px)
    ppd = pixels_per_degree(df)
    cx_px = Float64(w_px) * 0.5
    cy_px = Float64(h_px) * 0.5

    gx_deg = _is_col_deg(d, ecols.gx, df.coords)
    gy_deg = _is_col_deg(d, ecols.gy, df.coords)
    gx_cent = _is_col_centered(d, ecols.gx, df.coords)
    gy_cent = _is_col_centered(d, ecols.gy, df.coords)

    cam_x, cam_y, cam_z = if isnothing(camera_pos)
        (0.0, 0.0, dist_cm)
    elseif length(camera_pos) == 2
        (Float64(camera_pos[1]), Float64(camera_pos[2]), dist_cm)
    else
        (Float64(camera_pos[1]), Float64(camera_pos[2]), Float64(camera_pos[3]))
    end
    cam_norm = sqrt(cam_x * cam_x + cam_y * cam_y + cam_z * cam_z)
    cam_norm > 0.0 || throw(ArgumentError("camera_pos vector norm must be positive."))

    use_diam = measure === :diameter || (measure === :auto && df.source === :tobii)

    gx_vec = d[!, ecols.gx]
    gy_vec = d[!, ecols.gy]
    pa_src = _as_float_vec(d[!, ecols.pa])
    pa_out = _correct_pfe_kernel(
        pa_src,
        gx_vec,
        gy_vec,
        gx_deg,
        gy_deg,
        gx_cent,
        gy_cent,
        ppd,
        cx_px,
        cy_px,
        cm_per_px,
        dist_cm,
        cam_x,
        cam_y,
        cam_z,
        cam_norm,
        use_diam,
    )

    d[!, ecols.pa] = pa_out
    return df
end

function _correct_pfe_kernel(
    pa_src::Vector{T},
    gx_vec::AbstractVector,
    gy_vec::AbstractVector,
    gx_deg::Bool,
    gy_deg::Bool,
    gx_cent::Bool,
    gy_cent::Bool,
    ppd::Float64,
    cx_px::Float64,
    cy_px::Float64,
    cm_per_px::Float64,
    dist_cm::Float64,
    cam_x::Float64,
    cam_y::Float64,
    cam_z::Float64,
    cam_norm::Float64,
    use_diam::Bool,
) where {T<:AbstractFloat}
    pa_out = copy(pa_src)
    @inbounds for i in eachindex(pa_out, gx_vec, gy_vec)
        pi = Float64(pa_out[i])
        isnan(pi) && continue
        xi_raw = gx_vec[i]
        yi_raw = gy_vec[i]
        (ismissing(xi_raw) || ismissing(yi_raw)) && continue
        xi = Float64(xi_raw)
        yi = Float64(yi_raw)
        (isnan(xi) || isnan(yi)) && continue

        dx_px = gx_deg ? (gx_cent ? xi * ppd : (xi * ppd - cx_px)) : (gx_cent ? xi : (xi - cx_px))
        dy_px = gy_deg ? (gy_cent ? yi * ppd : (yi * ppd - cy_px)) : (gy_cent ? yi : (yi - cy_px))
        x_cm = dx_px * cm_per_px
        y_cm = dy_px * cm_per_px

        g_norm = sqrt(x_cm * x_cm + y_cm * y_cm + dist_cm * dist_cm)
        cos_a = clamp((x_cm * cam_x + y_cm * cam_y + dist_cm * cam_z) / (g_norm * cam_norm), 0.25, 1.0)
        factor = use_diam ? (1.0 / sqrt(cos_a)) : (1.0 / cos_a)
        pa_out[i] = T(pi * factor)
    end
    return pa_out
end
