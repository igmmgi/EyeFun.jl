function _velocity_filter_kernel!(
    gx::AbstractVector{<:AbstractFloat},
    gy::AbstractVector{<:AbstractFloat},
    vel::Vector{Float64},
    thresh::Float64,
)
    n_removed = 0
    NaNx = eltype(gx)(NaN)
    NaNy = eltype(gy)(NaN)
    @inbounds for i in eachindex(gx, gy, vel)
        v = vel[i]
        if !isnan(v) && v > thresh
            gx[i] = NaNx
            gy[i] = NaNy
            n_removed += 1
        end
    end
    return n_removed
end

"""
    velocity_filter!(df::EyeData; eye=:auto, threshold_deg_s=1000.0)

Replace gaze samples with implausibly high velocity with `NaN`.

Velocity is computed using the 5-sample central difference within each
`(participant, trial)` segment so inter-trial jumps never corrupt boundary samples.
Samples exceeding the threshold (default: 1000°/s) are set to `NaN`.

Returns the number of samples removed.
"""
function velocity_filter!(df::EyeData; eye::Symbol = :auto, threshold_deg_s::Real = 1000.0)
    eye = _resolve_eye(df, eye)
    _ensure_eye_cols!(df, eye)
    ecols = _eye_columns(eye)
    gx = _ensure_float_col!(df.df, ecols.gx)
    gy = _ensure_float_col!(df.df, ecols.gy)

    ppd = _eye_units_per_deg(df, eye)
    n = length(gx)
    vel = fill(NaN, n)
    scale = Float64(df.sample_rate) / (6.0 * Float64(ppd))
    _foreach_trial_segment(df.df) do lo, hi
        _compute_velocity_deg!(vel, gx, gy, lo, hi, scale)
    end
    return _velocity_filter_kernel!(gx, gy, vel, Float64(threshold_deg_s))
end

function _outlier_filter_kernel!(
    gx::AbstractVector{<:AbstractFloat},
    gy::AbstractVector{<:AbstractFloat},
    x_lo::Float64,
    x_hi::Float64,
    y_lo::Float64,
    y_hi::Float64,
)
    n_removed = 0
    NaNx = eltype(gx)(NaN)
    NaNy = eltype(gy)(NaN)
    @inbounds for i in eachindex(gx, gy)
        x = Float64(gx[i])
        y = Float64(gy[i])
        bad_x = !isnan(x) && (x < x_lo || x > x_hi)
        bad_y = !isnan(y) && (y < y_lo || y > y_hi)
        if bad_x || bad_y
            gx[i] = NaNx
            gy[i] = NaNy
            n_removed += 1
        end
    end
    return n_removed
end

"""
    outlier_filter!(df::EyeData; eye=:auto, bounds=nothing, margin=50)

Replace off-screen gaze samples with `NaN`.

By default uses screen resolution as bounds. Samples outside
`(-margin, width+margin, -margin, height+margin)` are removed.

Returns the number of samples removed.
"""
function outlier_filter!(
    df::EyeData;
    eye::Symbol = :auto,
    bounds::Union{Nothing,NTuple{4,Real}} = nothing,
    margin::Real = 50,
)
    eye = _resolve_eye(df, eye)
    _ensure_eye_cols!(df, eye)
    ecols = _eye_columns(eye)
    gx = _ensure_float_col!(df.df, ecols.gx)
    gy = _ensure_float_col!(df.df, ecols.gy)

    if isnothing(bounds)
        w, h = df.screen_res
        mode = _col_coord_mode(df.df, ecols.gx, df.coords)
        if mode === :deg
            ppd = pixels_per_degree(df)
            half_w = (w * 0.5) / ppd
            half_h = (h * 0.5) / ppd
            m_deg = Float64(margin) / ppd
            x_lo, x_hi = -(half_w + m_deg), (half_w + m_deg)
            y_lo, y_hi = -(half_h + m_deg), (half_h + m_deg)
        elseif mode === :center_px
            m_px = Float64(margin)
            x_lo, x_hi = -(w * 0.5 + m_px), (w * 0.5 + m_px)
            y_lo, y_hi = -(h * 0.5 + m_px), (h * 0.5 + m_px)
        else
            x_lo, x_hi = Float64(-margin), Float64(w + margin)
            y_lo, y_hi = Float64(-margin), Float64(h + margin)
        end
    else
        x_lo = Float64(bounds[1] - margin)
        x_hi = Float64(bounds[2] + margin)
        y_lo = Float64(bounds[3] - margin)
        y_hi = Float64(bounds[4] + margin)
    end

    return _outlier_filter_kernel!(gx, gy, x_lo, x_hi, y_lo, y_hi)
end

function _interpolate_gaps_range!(
    gx::AbstractVector{<:AbstractFloat},
    gy::AbstractVector{<:AbstractFloat},
    lo::Int,
    hi::Int,
    max_gap_samples::Int,
)
    n_filled = 0
    Tx = eltype(gx)
    Ty = eltype(gy)
    i = lo
    @inbounds while i <= hi
        if isnan(gx[i]) || isnan(gy[i])
            gap_start = i
            while i <= hi && (isnan(gx[i]) || isnan(gy[i]))
                i += 1
            end
            gap_end = i - 1
            gap_len = gap_end - gap_start + 1

            if gap_len <= max_gap_samples && gap_start > lo && gap_end < hi
                xb, yb = Float64(gx[gap_start-1]), Float64(gy[gap_start-1])
                xa, ya = Float64(gx[gap_end+1]), Float64(gy[gap_end+1])
                if !isnan(xb) && !isnan(yb) && !isnan(xa) && !isnan(ya)
                    inv_denom = 1.0 / (gap_len + 1)
                    for j = gap_start:gap_end
                        frac = (j - gap_start + 1) * inv_denom
                        gx[j] = Tx(xb + frac * (xa - xb))
                        gy[j] = Ty(yb + frac * (ya - yb))
                    end
                    n_filled += 1
                end
            end
        else
            i += 1
        end
    end
    return n_filled
end

"""
    interpolate_gaps!(df::EyeData; eye=:auto, max_gap_ms=75)

Linearly interpolate short tracking-loss gaps (`NaN` runs in `gx` or `gy`) in gaze data
within each `(participant, trial)` segment.

Unlike `interpolate_blinks!` which targets blink-flagged periods, this fills
any short `NaN` gap in gaze coordinates regardless of cause, interpolating `gx`
and `gy` jointly so partial `NaN`s are never left behind.

Returns the number of gaps interpolated.
"""
function interpolate_gaps!(df::EyeData; eye::Symbol = :auto, max_gap_ms::Real = 75)
    eye = _resolve_eye(df, eye)
    _ensure_eye_cols!(df, eye)
    ecols = _eye_columns(eye)
    gx = _ensure_float_col!(df.df, ecols.gx)
    gy = _ensure_float_col!(df.df, ecols.gy)
    max_gap_samples = round(Int, max_gap_ms * df.sample_rate / 1000.0)
    total_filled = Ref(0)
    _foreach_trial_segment(df.df) do lo, hi
        total_filled[] += _interpolate_gaps_range!(gx, gy, lo, hi, max_gap_samples)
    end
    return total_filled[]
end

function _savgol_weights(half::Int, poly_order::Int)::Vector{Float64}
    wlen = 2 * half + 1
    d = poly_order + 1
    V = Matrix{Float64}(undef, wlen, d)
    @inbounds for r = 1:wlen
        x = Float64(r - half - 1)
        xp = 1.0
        for c = 1:d
            V[r, c] = xp
            xp *= x
        end
    end
    e1 = zeros(Float64, d)
    e1[1] = 1.0
    q = (V' * V) \ e1
    return V * q
end

function _savgol_local_eval(
    x::AbstractVector{<:AbstractFloat},
    i::Int,
    j_lo::Int,
    j_hi::Int,
    poly_order::Int,
    G::Matrix{Float64},
    rhs::Vector{Float64},
)::Float64
    n_valid = 0
    @inbounds for j = j_lo:j_hi
        !isnan(x[j]) && (n_valid += 1)
    end
    n_valid <= 1 && return Float64(x[i])

    eff_p = n_valid > poly_order + 1 ? poly_order : max(0, n_valid - 2)
    if eff_p == 0
        s = 0.0
        @inbounds for j = j_lo:j_hi
            xj = Float64(x[j])
            !isnan(xj) && (s += xj)
        end
        return s / n_valid
    end

    d = eff_p + 1
    @inbounds begin
        for c = 1:d, r = 1:d
            G[r, c] = 0.0
        end
        for r = 1:d
            rhs[r] = 0.0
        end
        for j = j_lo:j_hi
            yj = Float64(x[j])
            isnan(yj) && continue
            dx = Float64(j - i)
            # Accumulate powers dx^(r + c - 2) and yj * dx^(r - 1)
            p_r = 1.0
            for r = 1:d
                rhs[r] += yj * p_r
                p_rc = p_r
                for c = 1:d
                    G[r, c] += p_rc
                    p_rc *= dx
                end
                r < d && (p_r *= dx)
            end
        end
        # Tiny ridge on diagonal for numerical safety on ill-conditioned gaps
        for r = 1:d
            G[r, r] += 1e-12
        end
    end
    sol = view(G, 1:d, 1:d) \ view(rhs, 1:d)
    return sol[1]
end

function _savgol_smooth_range!(
    out::Vector{T},
    x::AbstractVector{T},
    lo::Int,
    hi::Int,
    half::Int,
    poly_order::Int,
    weights::Vector{Float64},
    G::Matrix{Float64},
    rhs::Vector{Float64},
) where {T<:AbstractFloat}
    lo > hi && return out
    wlen = 2 * half + 1
    seg_len = hi - lo + 1
    NaNT = T(NaN)

    @inbounds for i = lo:hi
        if isnan(x[i])
            out[i] = NaNT
            continue
        end
        if i - half >= lo && i + half <= hi
            s = 0.0
            all_ok = true
            base = i - half - 1
            for k = 1:wlen
                xj = Float64(x[base+k])
                if isnan(xj)
                    all_ok = false
                    break
                end
                s += weights[k] * xj
            end
            if all_ok
                out[i] = T(s)
                continue
            end
        end

        j_lo = seg_len >= wlen ? clamp(i - half, lo, hi - wlen + 1) : lo
        j_hi = seg_len >= wlen ? (j_lo + wlen - 1) : hi
        out[i] = T(_savgol_local_eval(x, i, j_lo, j_hi, poly_order, G, rhs))
    end
    return out
end

function _savgol_smooth_col!(
    df::DataFrame,
    col::Symbol,
    window_samples::Int,
    poly_order::Int,
)
    cm = DataFrames.colmetadata(df, col, "eyefun_coords", nothing)
    x = _as_float_vec(df[!, col])
    n = length(x)
    out = Vector{eltype(x)}(undef, n)
    half = div(window_samples, 2)
    weights = _savgol_weights(half, poly_order)
    d = poly_order + 1
    G = Matrix{Float64}(undef, d, d)
    rhs = Vector{Float64}(undef, d)
    _foreach_trial_segment(df) do lo, hi
        _savgol_smooth_range!(out, x, lo, hi, half, poly_order, weights, G, rhs)
    end
    df[!, col] = out
    !isnothing(cm) && DataFrames.colmetadata!(df, col, "eyefun_coords", cm; style = :note)
    return nothing
end

"""
    savitzky_golay_filter!(df::EyeData; window_samples=11, poly_order=2,
                           eye=:auto, cols=:gaze) -> EyeData

Smooth gaze and/or pupil time series in-place using a Savitzky-Golay polynomial
FIR filter (Nyström & Holmqvist, 2010) within each `(participant, trial)` segment.

Preserves `NaN` at missing/blink samples without dilating valid values into gaps,
and fits local least-squares polynomials near segment boundaries and `NaN` edges.

# Keyword Arguments
- `window_samples=11`: Odd window width in samples (`>= 3`)
- `poly_order=2`: Polynomial degree (`0 <= poly_order < window_samples`)
- `eye=:auto`: `:auto`, `:left`, `:right`, or `:both`
- `cols=:gaze`: `:gaze` (`gx`, `gy`), `:pupil` (`pa`), or `:both` (`gx`, `gy`, `pa`)
"""
function savitzky_golay_filter!(
    df::EyeData;
    window_samples::Int = 11,
    poly_order::Int = 2,
    eye::Symbol = :auto,
    cols::Symbol = :gaze,
)
    (window_samples >= 3 && isodd(window_samples)) || throw(
        ArgumentError("window_samples must be an odd integer >= 3 (got $window_samples)."),
    )
    (0 <= poly_order < window_samples) || throw(
        ArgumentError(
            "poly_order must satisfy 0 <= poly_order < window_samples (got poly_order=$poly_order, window_samples=$window_samples).",
        ),
    )
    cols in (:gaze, :pupil, :both) ||
        throw(ArgumentError("Invalid cols=:$cols. Use :gaze, :pupil, or :both."))

    if cols in (:gaze, :both)
        g_eye = _resolve_eye(df, eye; cols = :gaze)
        _ensure_eye_cols!(df, g_eye; cols = :gaze)
        ge = _eye_columns(g_eye)
        hasproperty(df.df, ge.gx) &&
            _savgol_smooth_col!(df.df, ge.gx, window_samples, poly_order)
        hasproperty(df.df, ge.gy) &&
            _savgol_smooth_col!(df.df, ge.gy, window_samples, poly_order)
    end
    if cols in (:pupil, :both)
        p_eye = _resolve_eye(df, eye; cols = :pupil)
        _ensure_eye_cols!(df, p_eye; cols = :pupil)
        pe = _eye_columns(p_eye)
        hasproperty(df.df, pe.pa) &&
            _savgol_smooth_col!(df.df, pe.pa, window_samples, poly_order)
    end
    return df
end
