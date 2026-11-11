# Tracker-agnostic fixation and saccade detection using I-VT (velocity threshold)
# and I-DT (dispersion threshold) algorithms.

const _LBL_NOISE = 0x00
const _LBL_FIX = 0x01
const _LBL_SACC = 0x02
const _LBL_SEP = 0x03
const _LBL_PSO = 0x04

function _compute_velocity_deg!(
    vel::Vector{Float64},
    gx::AbstractVector{<:AbstractFloat},
    gy::AbstractVector{<:AbstractFloat},
    lo::Int,
    hi::Int,
    scale::Float64,
)
    (hi - lo + 1) < 5 && return vel
    @inbounds for i = (lo+2):(hi-2)
        (
            isnan(gx[i-2]) ||
            isnan(gx[i-1]) ||
            isnan(gx[i]) ||
            isnan(gx[i+1]) ||
            isnan(gx[i+2])
        ) && continue
        (
            isnan(gy[i-2]) ||
            isnan(gy[i-1]) ||
            isnan(gy[i]) ||
            isnan(gy[i+1]) ||
            isnan(gy[i+2])
        ) && continue

        # 5-point central difference (Engbert & Kliegl, 2003)
        dx = Float64(gx[i+2]) + Float64(gx[i+1]) - Float64(gx[i-1]) - Float64(gx[i-2])
        dy = Float64(gy[i+2]) + Float64(gy[i+1]) - Float64(gy[i-1]) - Float64(gy[i-2])

        vel[i] = sqrt(dx * dx + dy * dy) * scale
    end
    return vel
end

function _compute_group_velocity_deg!(
    v_buf::Vector{Float64},
    gx_buf::Vector{Float64},
    gy_buf::Vector{Float64},
    gx_src::AbstractVector{<:Real},
    gy_src::AbstractVector{<:Real},
    rows::AbstractVector{Int},
    m::Int,
    tr_col::Union{Nothing,AbstractVector},
    pt_col::Union{Nothing,AbstractVector},
    vel_scale::Float64,
)
    length(gx_buf) < m && resize!(gx_buf, m)
    length(gy_buf) < m && resize!(gy_buf, m)
    length(v_buf) < m && resize!(v_buf, m)
    @inbounds for k = 1:m
        rk = rows[k]
        gx_buf[k] = Float64(gx_src[rk])
        gy_buf[k] = Float64(gy_src[rk])
        v_buf[k] = NaN
    end
    seg_lo = 1
    @inbounds for k = 2:m
        if !_is_group_row_contig(rows[k-1], rows[k], tr_col, pt_col)
            _compute_velocity_deg!(v_buf, gx_buf, gy_buf, seg_lo, k - 1, vel_scale)
            seg_lo = k
        end
    end
    m >= seg_lo && _compute_velocity_deg!(v_buf, gx_buf, gy_buf, seg_lo, m, vel_scale)
    return nothing
end

function _subthreshold_vel_stats(
    vel::AbstractVector{<:AbstractFloat},
    lo::Int,
    hi::Int,
    pt::Float64,
)::Tuple{Float64,Float64}
    cnt = 0
    mean_v = 0.0
    m2 = 0.0
    @inbounds for i = lo:hi
        v = Float64(vel[i])
        if !isnan(v) && v < pt
            near_nan = (i > lo && isnan(vel[i-1])) || (i < hi && isnan(vel[i+1]))
            near_nan && continue
            cnt += 1
            delta = v - mean_v
            mean_v += delta / cnt
            m2 += delta * (v - mean_v)
        end
    end
    if cnt < 10
        cnt = 0
        mean_v = 0.0
        m2 = 0.0
        @inbounds for i = lo:hi
            v = Float64(vel[i])
            if !isnan(v) && v < pt
                cnt += 1
                delta = v - mean_v
                mean_v += delta / cnt
                m2 += delta * (v - mean_v)
            end
        end
        cnt < 2 && return (5.0, 4.0)
    end
    sigma = sqrt(max(0.0, m2 / (cnt - 1)))
    return (mean_v, sigma)
end

"""
Estimate an adaptive peak-velocity threshold (°/s) on `vel[lo:hi]` using the
iterative data-driven procedure of Nyström & Holmqvist (2010): starting from
`150.0` °/s, repeatedly compute `μ + 6σ` of sub-threshold velocities (excluding
samples directly bordering `NaN` blink/dropout boundaries when interior samples
exist) until convergence (`|ΔPT| < 1.0` °/s), floored at `10.0` °/s.
"""
function _adaptive_ivt_stats(
    vel::AbstractVector{<:AbstractFloat},
    lo::Int,
    hi::Int,
)::Tuple{Float64,Float64,Float64}
    lo > hi && return (30.0, 5.0, 4.0)
    pt = 150.0
    mean_v = 5.0
    sigma = 4.0
    for _ = 1:50
        cnt = 0
        mean_v = 0.0
        m2 = 0.0
        @inbounds for i = lo:hi
            v = Float64(vel[i])
            if !isnan(v) && v < pt
                # Exclude blink-edge artifact samples directly adjacent to NaN in vel
                near_nan = (i > lo && isnan(vel[i-1])) || (i < hi && isnan(vel[i+1]))
                near_nan && continue
                cnt += 1
                delta = v - mean_v
                mean_v += delta / cnt
                m2 += delta * (v - mean_v)
            end
        end
        if cnt < 10
            # Retry including boundary samples before falling back
            cnt = 0
            mean_v = 0.0
            m2 = 0.0
            @inbounds for i = lo:hi
                v = Float64(vel[i])
                if !isnan(v) && v < pt
                    cnt += 1
                    delta = v - mean_v
                    mean_v += delta / cnt
                    m2 += delta * (v - mean_v)
                end
            end
            cnt < 10 && return (30.0, 5.0, 4.0)
        end
        sigma = sqrt(max(0.0, m2 / (cnt - 1)))
        pt_new = max(10.0, mean_v + 6.0 * sigma)
        if abs(pt_new - pt) < 1.0
            return (pt_new, mean_v, sigma)
        end
        pt = pt_new
    end
    return (max(10.0, pt), mean_v, sigma)
end

function _refine_saccades_and_pso_u8!(
    labels::Vector{UInt8},
    vel::AbstractVector{<:AbstractFloat},
    lo::Int,
    hi::Int,
    onset_thresh::Float64,
    min_fix_samples::Int,
    do_refine::Bool,
    do_pso::Bool,
    max_pso_samples::Int,
)
    (lo > hi || (!do_refine && !do_pso)) && return labels

    i = lo
    @inbounds while i <= hi
        if labels[i] == _LBL_SACC
            j = i + 1
            while j <= hi && labels[j] == _LBL_SACC
                j += 1
            end
            s_lo = i
            s_hi = j - 1

            if do_refine
                # Walk backward to saccade onset (local minimum at or below μ + 3σ)
                k = s_lo - 1
                while k >= lo && labels[k] != _LBL_SACC
                    vk = Float64(vel[k])
                    (isnan(vk) || vk < onset_thresh) && break
                    v_next = Float64(vel[k+1])
                    (!isnan(v_next) && vk > v_next) && break
                    labels[k] = _LBL_SACC
                    s_lo = k
                    if k > lo
                        v_prev = Float64(vel[k-1])
                        (!isnan(v_prev) && v_prev >= vk) && break
                    end
                    k -= 1
                end

                # Walk forward to saccade offset (first local minimum or drop below μ + 3σ)
                k = s_hi + 1
                while k <= hi && labels[k] != _LBL_SACC
                    vk = Float64(vel[k])
                    (isnan(vk) || vk < onset_thresh) && break
                    v_prev = Float64(vel[k-1])
                    (!isnan(v_prev) && vk > v_prev) && break
                    labels[k] = _LBL_SACC
                    s_hi = k
                    if k < hi
                        v_next = Float64(vel[k+1])
                        (!isnan(v_next) && v_next >= vk) && break
                    end
                    k += 1
                end
            end

            next_i = s_hi + 1
            if do_pso && max_pso_samples > 0 && s_hi < hi
                p_lo = s_hi + 1
                p_hi = min(hi, s_hi + max_pso_samples)
                # Look for immediate post-saccadic velocity oscillation (glissade/PSO)
                # peaking above onset_thresh within a couple of samples after saccade offset.
                lead_lim = min(p_hi, s_hi + 3)
                has_osc = false
                pso_trigger = max(onset_thresh * 1.15, onset_thresh + 1.5)
                for k = p_lo:lead_lim
                    labels[k] == _LBL_SACC && break
                    vk = Float64(vel[k])
                    isnan(vk) && break
                    if vk >= pso_trigger
                        has_osc = true
                        break
                    end
                end
                if has_osc
                    pso_end = 0
                    peaked = false
                    for k = p_lo:p_hi
                        labels[k] == _LBL_SACC && break
                        vk = Float64(vel[k])
                        isnan(vk) && break
                        if vk >= onset_thresh
                            pso_end = k
                            vk >= pso_trigger && (peaked = true)
                        elseif peaked
                            break
                        end
                    end
                    if pso_end >= p_lo
                        for k = p_lo:pso_end
                            labels[k] = _LBL_PSO
                        end
                        next_i = pso_end + 1
                    end
                end
            end

            i = next_i
        else
            i += 1
        end
    end

    # Re-apply minimum fixation duration filter after onset/offset/PSO boundary adjustments
    i = lo
    @inbounds while i <= hi
        if labels[i] == _LBL_FIX
            j = i + 1
            while j <= hi && labels[j] == _LBL_FIX
                j += 1
            end
            if (j - i) < min_fix_samples
                for k = i:(j-1)
                    labels[k] = _LBL_NOISE
                end
            end
            i = j
        else
            i += 1
        end
    end

    return labels
end

function _ivt_classify_u8!(
    labels::Vector{UInt8},
    vel::AbstractVector{<:AbstractFloat},
    lo::Int,
    hi::Int,
    threshold::Float64,
    min_fix_samples::Int,
    min_sacc_samples::Int,
)
    lo > hi && return labels

    @inbounds for i = lo:hi
        v = vel[i]
        if isnan(v)
            labels[i] = _LBL_NOISE
        elseif v < threshold
            labels[i] = _LBL_FIX
        else
            labels[i] = _LBL_SACC
        end
    end

    # Handle short saccade bursts (< min_sacc_samples) within [lo, hi]:
    # - if sandwiched between fixations, merge into fixation
    # - otherwise, reclassify as noise so 1-sample velocity spikes near blinks are dropped
    i = lo
    @inbounds while i <= hi
        if labels[i] == _LBL_SACC
            j = i + 1
            while j <= hi && labels[j] == _LBL_SACC
                j += 1
            end
            if (j - i) < min_sacc_samples
                before_fix = i > lo && labels[i-1] == _LBL_FIX
                after_fix = j <= hi && labels[j] == _LBL_FIX
                fill_lbl = (before_fix && after_fix) ? _LBL_FIX : _LBL_NOISE
                for k = i:(j-1)
                    labels[k] = fill_lbl
                end
            end
            i = j
        else
            i += 1
        end
    end

    # Discard fixations shorter than minimum within [lo, hi]
    i = lo
    @inbounds while i <= hi
        if labels[i] == _LBL_FIX
            j = i + 1
            while j <= hi && labels[j] == _LBL_FIX
                j += 1
            end
            if (j - i) < min_fix_samples
                for k = i:(j-1)
                    labels[k] = _LBL_NOISE
                end
            end
            i = j
        else
            i += 1
        end
    end

    return labels
end

function _idt_classify_u8!(
    labels::Vector{UInt8},
    gx::AbstractVector{<:AbstractFloat},
    gy::AbstractVector{<:AbstractFloat},
    lo::Int,
    hi::Int,
    ppd::Float64,
    disp_threshold::Float64,
    min_fix_samples::Int,
    min_sacc_samples::Int,
)
    lo > hi && return labels
    disp_px_thresh = disp_threshold * ppd

    # Leave a 1-sample _LBL_SEP separator if the preceding segment ended in a fixation
    # so consecutive fixations across trial boundaries are never merged into one run
    # and separator samples are never misclassified as 1-sample saccades at low Hz.
    i = lo
    just_ended_fix = (lo > 1 && labels[lo-1] == _LBL_FIX)
    @inbounds while i <= hi - min_fix_samples + 1
        if isnan(gx[i]) || isnan(gy[i])
            just_ended_fix = false
            i += 1
            continue
        end

        if just_ended_fix
            labels[i] = _LBL_SEP
            just_ended_fix = false
            i += 1
            continue
        end

        # Require min_fix_samples contiguous valid (non-NaN) samples starting at i
        j = i + min_fix_samples - 1
        nan_pos = 0
        x_min, x_max = Inf, -Inf
        y_min, y_max = Inf, -Inf
        for k = i:j
            xk = Float64(gx[k])
            yk = Float64(gy[k])
            if isnan(xk) || isnan(yk)
                nan_pos = k
                break
            end
            xk < x_min && (x_min = xk)
            xk > x_max && (x_max = xk)
            yk < y_min && (y_min = yk)
            yk > y_max && (y_max = yk)
        end

        if nan_pos > 0
            i = nan_pos + 1
            continue
        end

        if (x_max - x_min) + (y_max - y_min) <= disp_px_thresh
            hit_nan = false
            while j < hi
                xn = Float64(gx[j+1])
                yn = Float64(gy[j+1])
                if isnan(xn) || isnan(yn)
                    hit_nan = true
                    break
                end
                nx_min = min(x_min, xn)
                nx_max = max(x_max, xn)
                ny_min = min(y_min, yn)
                ny_max = max(y_max, yn)
                if (nx_max - nx_min) + (ny_max - ny_min) > disp_px_thresh
                    break
                end
                x_min, x_max = nx_min, nx_max
                y_min, y_max = ny_min, ny_max
                j += 1
            end
            for k = i:j
                labels[k] = _LBL_FIX
            end
            just_ended_fix = !hit_nan
            i = j + 1
        else
            i += 1
        end
    end

    # Classify valid (non-NaN) non-fixation intervals of >= min_sacc_samples as saccades.
    # Leave 1 separator sample if the preceding segment ended in a saccade.
    if lo > 1 && labels[lo-1] == _LBL_SACC && labels[lo] == _LBL_NOISE
        labels[lo] = _LBL_SEP
    end
    i = (lo > 1 && labels[lo-1] == _LBL_SACC) ? (lo + 1) : lo
    @inbounds while i <= hi
        if labels[i] == _LBL_NOISE && !isnan(gx[i]) && !isnan(gy[i])
            j = i + 1
            while j <= hi && labels[j] == _LBL_NOISE && !isnan(gx[j]) && !isnan(gy[j])
                j += 1
            end
            if (j - i) >= min_sacc_samples
                for k = i:(j-1)
                    labels[k] = _LBL_SACC
                end
            end
            i = j
        else
            i += 1
        end
    end

    return labels
end

"""Write detected events into DataFrame columns using the standard schema."""
function _write_event_columns_u8!(
    df::EyeData,
    labels::Vector{UInt8},
    gx::AbstractVector{<:AbstractFloat},
    gy::AbstractVector{<:AbstractFloat},
    pa::Union{Nothing,AbstractVector{<:AbstractFloat}},
    vel::AbstractVector{<:AbstractFloat},
    ppd::Float64,
    sample_rate::Float64,
    prefix::Union{Nothing,Symbol},
    write_pso::Bool = false,
)
    n = length(labels)
    col(name) = isnothing(prefix) ? name : Symbol(prefix, :_, name)

    in_fix = Vector{Bool}(undef, n)
    fill!(in_fix, false)
    fix_gavx = fill(NaN, n)
    fix_gavy = fill(NaN, n)
    fix_ava = fill(NaN, n)
    fix_dur = fill(Int32(0), n)

    in_sacc = Vector{Bool}(undef, n)
    fill!(in_sacc, false)
    sacc_gstx = fill(NaN, n)
    sacc_gsty = fill(NaN, n)
    sacc_genx = fill(NaN, n)
    sacc_geny = fill(NaN, n)
    sacc_dur = fill(Int32(0), n)
    sacc_ampl = fill(NaN, n)
    sacc_pvel = fill(NaN, n)

    in_pso = write_pso ? fill(false, n) : Bool[]
    pso_dur = write_pso ? fill(Int32(0), n) : Int32[]

    inv_sr_ms = 1000.0 / sample_rate
    inv_ppd = 1.0 / ppd

    i = 1
    @inbounds while i <= n
        lbl = labels[i]
        if lbl == _LBL_FIX
            j = i + 1
            while j <= n && labels[j] == _LBL_FIX
                j += 1
            end
            j_end = j - 1
            sum_x, sum_y, sum_pa = 0.0, 0.0, 0.0
            cnt, cnt_pa = 0, 0
            for k = i:j_end
                in_fix[k] = true
                xk = Float64(gx[k])
                yk = Float64(gy[k])
                if !isnan(xk) && !isnan(yk)
                    sum_x += xk
                    sum_y += yk
                    cnt += 1
                    if !isnothing(pa)
                        pk = Float64(pa[k])
                        if !isnan(pk)
                            sum_pa += pk
                            cnt_pa += 1
                        end
                    end
                end
            end
            if cnt > 0
                cx = sum_x / cnt
                cy = sum_y / cnt
                ca = cnt_pa > 0 ? sum_pa / cnt_pa : NaN
                dur_ms = round(Int32, (j_end - i + 1) * inv_sr_ms)
                for k = i:j_end
                    fix_gavx[k] = cx
                    fix_gavy[k] = cy
                    fix_ava[k] = ca
                    fix_dur[k] = dur_ms
                end
            end
            i = j
        elseif lbl == _LBL_SACC
            j = i + 1
            while j <= n && labels[j] == _LBL_SACC
                j += 1
            end
            j_end = j - 1
            dur_ms = round(Int32, (j_end - i + 1) * inv_sr_ms)
            first_valid = 0
            last_valid = 0
            peak_v = NaN
            for k = i:j_end
                in_sacc[k] = true
                sacc_dur[k] = dur_ms
                if !isnan(gx[k]) && !isnan(gy[k])
                    first_valid == 0 && (first_valid = k)
                    last_valid = k
                end
                vk = Float64(vel[k])
                if !isnan(vk) && (isnan(peak_v) || vk > peak_v)
                    peak_v = vk
                end
            end
            if first_valid > 0 && last_valid > 0
                stx = Float64(gx[first_valid])
                sty = Float64(gy[first_valid])
                enx = Float64(gx[last_valid])
                eny = Float64(gy[last_valid])
                amp = hypot(enx - stx, eny - sty) * inv_ppd
                if isnan(peak_v) && last_valid > first_valid
                    max_step_v = NaN
                    prev_k = first_valid
                    for k = (first_valid+1):last_valid
                        if !isnan(gx[k]) && !isnan(gy[k])
                            step_deg =
                                hypot(
                                    Float64(gx[k]) - Float64(gx[prev_k]),
                                    Float64(gy[k]) - Float64(gy[prev_k]),
                                ) * inv_ppd
                            step_v = step_deg * sample_rate / (k - prev_k)
                            if isnan(max_step_v) || step_v > max_step_v
                                max_step_v = step_v
                            end
                            prev_k = k
                        end
                    end
                    peak_v = max_step_v
                end
                for k = i:j_end
                    sacc_gstx[k] = stx
                    sacc_gsty[k] = sty
                    sacc_genx[k] = enx
                    sacc_geny[k] = eny
                    sacc_ampl[k] = amp
                    sacc_pvel[k] = peak_v
                end
            end
            i = j
        elseif write_pso && lbl == _LBL_PSO
            j = i + 1
            while j <= n && labels[j] == _LBL_PSO
                j += 1
            end
            j_end = j - 1
            dur_ms = round(Int32, (j_end - i + 1) * inv_sr_ms)
            for k = i:j_end
                in_pso[k] = true
                pso_dur[k] = dur_ms
            end
            i = j
        else
            i += 1
        end
    end

    df.df[!, col(:in_fix)] = in_fix
    df.df[!, col(:fix_gavx)] = fix_gavx
    df.df[!, col(:fix_gavy)] = fix_gavy
    df.df[!, col(:fix_ava)] = fix_ava
    df.df[!, col(:fix_dur)] = fix_dur
    df.df[!, col(:in_sacc)] = in_sacc
    df.df[!, col(:sacc_gstx)] = sacc_gstx
    df.df[!, col(:sacc_gsty)] = sacc_gsty
    df.df[!, col(:sacc_genx)] = sacc_genx
    df.df[!, col(:sacc_geny)] = sacc_geny
    df.df[!, col(:sacc_dur)] = sacc_dur
    df.df[!, col(:sacc_ampl)] = sacc_ampl
    df.df[!, col(:sacc_pvel)] = sacc_pvel
    if write_pso
        df.df[!, col(:in_pso)] = in_pso
        df.df[!, col(:pso_dur)] = pso_dur
    end
    return nothing
end

"""
    detect_events!(df::EyeData; method=:ivt, eye=:auto, ...)

Detect fixations and saccades using velocity-based (I-VT) or dispersion-based
(I-DT) algorithms. Writes event columns directly into the DataFrame using the
standard EyeFun column schema (`in_fix`, `fix_gavx`, `in_sacc`, `sacc_gstx`, etc.).

By default, **overwrites** existing event columns. Use `prefix=:ivt` to write
to prefixed columns instead (e.g. `ivt_in_fix`), preserving originals for comparison.
Detection is isolated within contiguous `(participant, trial)` segments so
events never bleed across trial or participant boundaries.

# Keyword Arguments
- `method=:ivt`: Detection algorithm (`:ivt` for velocity threshold or `:idt` for dispersion threshold)
- `eye=:auto`: Eye to analyze (`:auto`, `:left`, `:right`, or `:both`)
- `velocity_threshold=30.0`: Velocity threshold in °/s, or `:adaptive` for iterative Nyström & Holmqvist (2010) data-driven threshold estimation (I-VT only)
- `dispersion_threshold=1.0`: Spatial dispersion threshold in ° (I-DT only)
- `min_fixation_ms=60`: Minimum fixation duration in ms
- `min_saccade_ms=10`: Minimum saccade duration in ms
- `min_blink_ms=80`: Minimum NaN-run duration to classify as a blink
- `detect_blinks=nothing`: When `true`, detect blinks from `NaN` runs; when `nothing` (default), enabled automatically for `:smi`/`:tobii` data and `:generic` data lacking a blink column
- `refine_saccades=(velocity_threshold === :adaptive)`: Expand suprathreshold saccade peaks backward/forward to Nyström & Holmqvist (2010) `μ + 3σ` local velocity minima (I-VT only)
- `detect_pso=false`: Detect post-saccadic oscillations / glissades immediately following saccade offset and populate `in_pso` and `pso_dur` columns so PSO wobble is excluded from fixation centroids (I-VT only)
- `max_pso_ms=40`: Maximum post-saccadic oscillation window in ms when `detect_pso=true`
- `pixels_per_degree=nothing`: Override automatic ppd calculation
- `prefix=nothing`: `nothing` overwrites base columns; `:ivt`/`:idt` writes prefixed columns
"""
function detect_events!(
    df::EyeData;
    eye::Symbol = :auto,
    method::Symbol = :ivt,
    velocity_threshold::Union{Real,Symbol} = 30.0,
    dispersion_threshold::Real = 1.0,
    min_fixation_ms::Int = 60,
    min_saccade_ms::Int = 10,
    min_blink_ms::Int = 80,
    detect_blinks::Union{Nothing,Bool} = nothing,
    refine_saccades::Bool = (velocity_threshold === :adaptive),
    detect_pso::Bool = false,
    max_pso_ms::Int = 40,
    pixels_per_degree::Union{Nothing,Real} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)

    method ∈ (:ivt, :idt) || error("Invalid method=:$method. Use :ivt or :idt.")
    is_adaptive = if velocity_threshold isa Symbol
        velocity_threshold == :adaptive || throw(
            ArgumentError(
                "Invalid velocity_threshold=:$velocity_threshold. Use a positive number or :adaptive.",
            ),
        )
        true
    else
        Float64(velocity_threshold) > 0.0 || throw(
            ArgumentError("velocity_threshold must be positive (got $velocity_threshold)."),
        )
        false
    end

    eye = _resolve_eye(df, eye)
    _ensure_eye_cols!(df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col, pa_col = ecols.gx, ecols.gy, ecols.pa

    # Coordinate units per degree (1.0 when already converted to visual degrees)
    ppd = Float64(something(pixels_per_degree, _eye_units_per_deg(df, eye)))
    sample_rate = df.sample_rate

    samples_per_ms = sample_rate / 1000.0
    min_fix_samples = max(1, round(Int, min_fixation_ms * samples_per_ms))
    min_sacc_samples = max(1, round(Int, min_saccade_ms * samples_per_ms))
    max_pso_samples = max(0, round(Int, max_pso_ms * samples_per_ms))

    gx = _as_float_vec(df.df[!, gx_col])
    gy = _as_float_vec(df.df[!, gy_col])
    pa = hasproperty(df.df, pa_col) ? _as_float_vec(df.df[!, pa_col]) : nothing

    n = length(gx)
    all_vel = fill(NaN, n)
    all_labels = fill(_LBL_NOISE, n)
    vel_scale = Float64(sample_rate) / (6.0 * ppd)
    v_thresh = is_adaptive ? 30.0 : Float64(velocity_threshold)
    d_thresh = Float64(dispersion_threshold)
    is_ivt = (method == :ivt)
    do_refine = is_ivt && refine_saccades
    do_pso = is_ivt && detect_pso

    _foreach_trial_segment(df.df) do lo, hi
        _compute_velocity_deg!(all_vel, gx, gy, lo, hi, vel_scale)
        if is_ivt
            if is_adaptive
                seg_v_thresh, mu_v, sigma_v = _adaptive_ivt_stats(all_vel, lo, hi)
            elseif do_refine || do_pso
                seg_v_thresh = v_thresh
                mu_v, sigma_v = _subthreshold_vel_stats(all_vel, lo, hi, seg_v_thresh)
            else
                seg_v_thresh, mu_v, sigma_v = v_thresh, 0.0, 0.0
            end
            _ivt_classify_u8!(all_labels, all_vel, lo, hi, seg_v_thresh, min_fix_samples, min_sacc_samples)
            if do_refine || do_pso
                onset_thresh = min(seg_v_thresh, max(2.0, mu_v + 3.0 * sigma_v))
                _refine_saccades_and_pso_u8!(
                    all_labels,
                    all_vel,
                    lo,
                    hi,
                    onset_thresh,
                    min_fix_samples,
                    do_refine,
                    do_pso,
                    max_pso_samples,
                )
            end
        else
            _idt_classify_u8!(
                all_labels,
                gx,
                gy,
                lo,
                hi,
                ppd,
                d_thresh,
                min_fix_samples,
                min_sacc_samples,
            )
        end
    end

    _write_event_columns_u8!(df, all_labels, gx, gy, pa, all_vel, ppd, sample_rate, prefix, do_pso)

    blink_col = isnothing(prefix) ? :in_blink : Symbol(prefix, :_in_blink)
    do_blinks = something(
        detect_blinks,
        df.source in (:smi, :tobii) ||
        (df.source == :generic && !hasproperty(df.df, blink_col)),
    )
    if do_blinks
        _detect_nan_blinks!(df, min_blink_ms, eye, prefix)
    end

    return df
end

function _mark_nan_blink_runs_range!(
    in_blink::BitVector,
    blink_dur::Vector{Int32},
    track::AbstractVector,
    lo::Int,
    hi::Int,
    min_blink_samples::Int,
    inv_sr_ms::Float64,
)
    # Leave a 1-sample separator if the preceding segment ended in a blink
    i = (lo > 1 && in_blink[lo-1]) ? (lo + 1) : lo
    @inbounds while i <= hi
        v = track[i]
        if ismissing(v) || isnan(v)
            j = i + 1
            while j <= hi
                vj = track[j]
                (ismissing(vj) || isnan(vj)) || break
                j += 1
            end
            run_len = j - i
            if run_len >= min_blink_samples
                dur_ms = round(Int32, run_len * inv_sr_ms)
                for k = i:(j-1)
                    in_blink[k] = true
                    blink_dur[k] = dur_ms
                end
            end
            i = j
        else
            i += 1
        end
    end
    return nothing
end

function _mark_nan_blink_runs_pair_range!(
    in_blink::BitVector,
    blink_dur::Vector{Int32},
    gx::AbstractVector,
    gy::AbstractVector,
    lo::Int,
    hi::Int,
    min_blink_samples::Int,
    inv_sr_ms::Float64,
)
    i = (lo > 1 && in_blink[lo-1]) ? (lo + 1) : lo
    @inbounds while i <= hi
        vx = gx[i]
        vy = gy[i]
        if ismissing(vx) || isnan(vx) || ismissing(vy) || isnan(vy)
            j = i + 1
            while j <= hi
                vjx = gx[j]
                vjy = gy[j]
                (ismissing(vjx) || isnan(vjx) || ismissing(vjy) || isnan(vjy)) || break
                j += 1
            end
            run_len = j - i
            if run_len >= min_blink_samples
                dur_ms = round(Int32, run_len * inv_sr_ms)
                for k = i:(j-1)
                    in_blink[k] = true
                    blink_dur[k] = dur_ms
                end
            end
            i = j
        else
            i += 1
        end
    end
    return nothing
end

"""
    _detect_nan_blinks!(ed::EyeData, min_blink_ms::Int, eye::Symbol, prefix=nothing)

Detect blinks as contiguous NaN runs in the gaze signal for the selected `eye`
within each `(participant, trial)` segment. Populates `in_blink` and `blink_dur`
(or `[prefix]_in_blink` / `[prefix]_blink_dur`) columns in `ed.df`.
"""
function _detect_nan_blinks!(
    ed::EyeData,
    min_blink_ms::Int,
    eye::Symbol,
    prefix::Union{Nothing,Symbol} = nothing,
)
    df = ed.df
    n = nrow(df)
    ecols = _eye_columns(eye)

    has_gx = hasproperty(df, ecols.gx)
    has_gy = hasproperty(df, ecols.gy)

    sr = ed.sample_rate
    min_blink_samples = max(1, round(Int, min_blink_ms * sr / 1000.0))

    in_blink = falses(n)
    blink_dur = fill(Int32(0), n)
    inv_sr_ms = 1000.0 / sr

    if has_gx && has_gy
        gx = df[!, ecols.gx]
        gy = df[!, ecols.gy]
        _foreach_trial_segment(df) do lo, hi
            _mark_nan_blink_runs_pair_range!(
                in_blink,
                blink_dur,
                gx,
                gy,
                lo,
                hi,
                min_blink_samples,
                inv_sr_ms,
            )
        end
    elseif has_gx || hasproperty(df, ecols.pa)
        track = df[!, has_gx ? ecols.gx : ecols.pa]
        _foreach_trial_segment(df) do lo, hi
            _mark_nan_blink_runs_range!(in_blink, blink_dur, track, lo, hi, min_blink_samples, inv_sr_ms)
        end
    end

    c_blink = isnothing(prefix) ? :in_blink : Symbol(prefix, :_in_blink)
    c_dur = isnothing(prefix) ? :blink_dur : Symbol(prefix, :_blink_dur)
    df[!, c_blink] = in_blink
    df[!, c_dur] = blink_dur
    return
end

function _extract_fixations_info_kernel(
    in_fix::AbstractVector{Bool},
    gavx::AbstractVector{<:Real},
    gavy::AbstractVector{<:Real},
    dur::AbstractVector{<:Real},
)
    fixs = FixationInfo[]
    n = length(in_fix)
    i = 1
    @inbounds while i <= n
        if in_fix[i]
            j = i + 1
            while j <= n && in_fix[j]
                j += 1
            end
            fx, fy = Float64(gavx[i]), Float64(gavy[i])
            if !isnan(fx) && !isnan(fy)
                push!(
                    fixs,
                    (x = fx, y = fy, dur = Float64(dur[i]), time_start = i, time_end = j - 1),
                )
            end
            i = j
        else
            i += 1
        end
    end
    return fixs
end

"""Extract unique fixations from a DataFrame using contiguous run encoding."""
function _extract_fixations(
    g::AbstractDataFrame;
    prefix::Union{Nothing,Symbol} = nothing,
)
    c_in = _prefixed_sym(prefix, :in_fix)
    c_x = _prefixed_sym(prefix, :fix_gavx)
    c_y = _prefixed_sym(prefix, :fix_gavy)
    c_dur = _prefixed_sym(prefix, :fix_dur)
    (!hasproperty(g, c_x) || !hasproperty(g, c_in)) && return FixationInfo[]
    return _extract_fixations_info_kernel(g[!, c_in], g[!, c_x], g[!, c_y], g[!, c_dur])
end

function _extract_saccades_info_kernel(
    in_sacc::AbstractVector{Bool},
    gstx::AbstractVector{<:Real},
    gsty::AbstractVector{<:Real},
    genx::AbstractVector{<:Real},
    geny::AbstractVector{<:Real},
)
    saccs = SaccadeInfo[]
    n = length(in_sacc)
    i = 1
    @inbounds while i <= n
        if in_sacc[i]
            j = i + 1
            while j <= n && in_sacc[j]
                j += 1
            end
            x1, y1 = Float64(gstx[i]), Float64(gsty[i])
            x2, y2 = Float64(genx[i]), Float64(geny[i])
            if !isnan(x1) && !isnan(y1) && !isnan(x2) && !isnan(y2)
                dx, dy = x2 - x1, -(y2 - y1)  # flip Y for screen coords
                push!(
                    saccs,
                    (
                        x1 = x1,
                        y1 = y1,
                        x2 = x2,
                        y2 = y2,
                        time_idx = i,
                        angle = atan(dx, dy),
                        amplitude = hypot(dx, dy),
                    ),
                )
            end
            i = j
        else
            i += 1
        end
    end
    return saccs
end

"""Extract unique saccades from a DataFrame using contiguous run encoding."""
function _extract_saccades(
    g::AbstractDataFrame;
    prefix::Union{Nothing,Symbol} = nothing,
)
    c_in = _prefixed_sym(prefix, :in_sacc)
    c_stx = _prefixed_sym(prefix, :sacc_gstx)
    c_sty = _prefixed_sym(prefix, :sacc_gsty)
    c_enx = _prefixed_sym(prefix, :sacc_genx)
    c_eny = _prefixed_sym(prefix, :sacc_geny)
    (!hasproperty(g, c_stx) || !hasproperty(g, c_in)) && return SaccadeInfo[]
    return _extract_saccades_info_kernel(g[!, c_in], g[!, c_stx], g[!, c_sty], g[!, c_enx], g[!, c_eny])
end
