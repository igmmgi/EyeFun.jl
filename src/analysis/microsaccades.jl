function _median_sigma!(
    work1::Vector{Float64},
    work2::Vector{Float64},
    v::Vector{Float64},
    nt::Int,
)
    cnt = 0
    @inbounds for i = 1:nt
        vi = v[i]
        if !isnan(vi)
            cnt += 1
            work1[cnt] = vi
            work2[cnt] = vi * vi
        end
    end
    cnt < 10 && return NaN, cnt
    med_v = median!(@view work1[1:cnt])
    med_v2 = median!(@view work2[1:cnt])
    return max(sqrt(max(0.0, med_v2 - med_v * med_v)), 1e-10), cnt
end

function _detect_microsaccades_trial!(
    in_msacc::BitVector,
    msacc_dx::Vector{Float64},
    msacc_dy::Vector{Float64},
    msacc_ampl::Vector{Float64},
    msacc_pvel::Vector{Float64},
    gx_all::AbstractVector{<:AbstractFloat},
    gy_all::AbstractVector{<:AbstractFloat},
    blink_mask::Union{Nothing,AbstractVector{Bool}},
    blink_pad::Int,
    idxs::AbstractVector{Int},
    vx::Vector{Float64},
    vy::Vector{Float64},
    work1::Vector{Float64},
    work2::Vector{Float64},
    lambda::Float64,
    min_dur_samples::Int,
    max_amplitude::Float64,
    ppd::Float64,
    sample_rate::Float64,
)
    nt = length(idxs)
    nt < 5 && return nothing

    if length(vx) < nt
        resize!(vx, nt)
        resize!(vy, nt)
        resize!(work1, nt)
        resize!(work2, nt)
    end

    vx[1] = vx[2] = vx[nt-1] = vx[nt] = NaN
    vy[1] = vy[2] = vy[nt-1] = vy[nt] = NaN

    inv6 = 1.0 / 6.0
    @inbounds for i = 3:(nt-2)
        k_m2 = idxs[i-2]
        k_p2 = idxs[i+2]
        if k_p2 - k_m2 != 4
            vx[i] = NaN
            vy[i] = NaN
            continue
        end
        k_m1 = idxs[i-1]
        k_0 = idxs[i]
        k_p1 = idxs[i+1]

        x_m2, x_m1, x_0, x_p1, x_p2 =
            gx_all[k_m2], gx_all[k_m1], gx_all[k_0], gx_all[k_p1], gx_all[k_p2]
        y_m2, y_m1, y_0, y_p1, y_p2 =
            gy_all[k_m2], gy_all[k_m1], gy_all[k_0], gy_all[k_p1], gy_all[k_p2]

        if !(
            isnan(x_m2) ||
            isnan(x_m1) ||
            isnan(x_0) ||
            isnan(x_p1) ||
            isnan(x_p2) ||
            isnan(y_m2) ||
            isnan(y_m1) ||
            isnan(y_0) ||
            isnan(y_p1) ||
            isnan(y_p2)
        )
            vx[i] = (Float64(x_p2) + Float64(x_p1) - Float64(x_m1) - Float64(x_m2)) * inv6
            vy[i] = (Float64(y_p2) + Float64(y_p1) - Float64(y_m1) - Float64(y_m2)) * inv6
        else
            vx[i] = NaN
            vy[i] = NaN
        end
    end

    # Mask samples bordering marked blinks so pre/post-blink eyelid droop is excluded
    if !isnothing(blink_mask) && blink_pad > 0
        @inbounds for i = 1:nt
            if blink_mask[idxs[i]]
                lo_b = max(1, i - blink_pad)
                hi_b = min(nt, i + blink_pad)
                for b = lo_b:hi_b
                    vx[b] = NaN
                    vy[b] = NaN
                end
            end
        end
    end

    σx, n_valid = _median_sigma!(work1, work2, vx, nt)
    n_valid < 10 && return nothing
    σy, _ = _median_sigma!(work1, work2, vy, nt)

    inv_tx2 = 1.0 / ((lambda * σx)^2)
    inv_ty2 = 1.0 / ((lambda * σy)^2)
    inv_ppd = 1.0 / ppd
    vel_deg_scale = sample_rate * inv_ppd

    i = 1
    @inbounds while i <= nt
        vxi, vyi = vx[i], vy[i]
        if !isnan(vxi) && !isnan(vyi) && (vxi * vxi * inv_tx2 + vyi * vyi * inv_ty2 > 1.0)
            onset = i
            i += 1
            while i <= nt
                vxj, vyj = vx[i], vy[i]
                (!isnan(vxj) && !isnan(vyj) && (vxj * vxj * inv_tx2 + vyj * vyj * inv_ty2 > 1.0)) ||
                    break
                i += 1
            end
            offset = i - 1
            dur = offset - onset + 1
            dur < min_dur_samples && continue

            x_on = Float64(gx_all[idxs[onset]])
            y_on = Float64(gy_all[idxs[onset]])
            x_off = Float64(gx_all[idxs[offset]])
            y_off = Float64(gy_all[idxs[offset]])
            (isnan(x_on) || isnan(y_on) || isnan(x_off) || isnan(y_off)) && continue

            dx = x_off - x_on
            dy = y_off - y_on
            ampl_deg = hypot(dx, dy) * inv_ppd
            ampl_deg > max_amplitude && continue

            pvel_px_sample = 0.0
            for k = onset:offset
                spd = hypot(vx[k], vy[k])
                spd > pvel_px_sample && (pvel_px_sample = spd)
            end
            pvel_deg_s = pvel_px_sample * vel_deg_scale

            for pos = onset:offset
                j = idxs[pos]
                in_msacc[j] = true
                msacc_dx[j] = dx
                msacc_dy[j] = dy
                msacc_ampl[j] = ampl_deg
                msacc_pvel[j] = pvel_deg_s
            end
        else
            i += 1
        end
    end
    return nothing
end

function _trial_col_is_monotone_blocks_single(tr::AbstractVector)::Bool
    T = nonmissingtype(eltype(tr))
    seen = Set{T}()
    n = length(tr)
    i = 1
    @inbounds while i <= n
        ti = tr[i]
        if ismissing(ti)
            i += 1
            continue
        end
        ti in seen && return false
        push!(seen, ti)
        j = i + 1
        while j <= n && isequal(tr[j], ti)
            j += 1
        end
        i = j
    end
    return true
end

function _trial_col_is_monotone_blocks(tr::AbstractVector, pt::Union{Nothing,AbstractVector})::Bool
    isnothing(pt) && return _trial_col_is_monotone_blocks_single(tr)
    TP = nonmissingtype(eltype(pt))
    TT = nonmissingtype(eltype(tr))
    seen = Set{Tuple{TP,TT}}()
    n = length(tr)
    i = 1
    @inbounds while i <= n
        ti = tr[i]
        if ismissing(ti)
            i += 1
            continue
        end
        pi = pt[i]
        if ismissing(pi)
            i += 1
            continue
        end
        key = (pi, ti)
        key in seen && return false
        push!(seen, key)
        j = i + 1
        while j <= n && isequal(tr[j], ti) && isequal(pt[j], pi)
            j += 1
        end
        i = j
    end
    return true
end

function _combine_binocular_microsaccades!(
    in_out::BitVector,
    dx_out::Vector{Float64},
    dy_out::Vector{Float64},
    ampl_out::Vector{Float64},
    pvel_out::Vector{Float64},
    in_L::BitVector,
    dx_L::Vector{Float64},
    dy_L::Vector{Float64},
    ampl_L::Vector{Float64},
    pvel_L::Vector{Float64},
    in_R::BitVector,
    dx_R::Vector{Float64},
    dy_R::Vector{Float64},
    ampl_R::Vector{Float64},
    pvel_R::Vector{Float64},
    lo::Int,
    hi::Int,
)
    # Engbert & Kliegl (2003): retain connected components of (in_L | in_R) that contain
    # at least one sample where both eyes overlap (in_L[k] && in_R[k])
    i = lo
    @inbounds while i <= hi
        if in_L[i] || in_R[i]
            j = i
            has_L = false
            has_R = false
            idx_L = 0
            idx_R = 0
            while j <= hi && (in_L[j] || in_R[j])
                if in_L[j] && !has_L
                    has_L = true
                    idx_L = j
                end
                if in_R[j] && !has_R
                    has_R = true
                    idx_R = j
                end
                j += 1
            end
            r_end = j - 1
            if has_L && has_R
                # Verify temporal overlap (at least 1 sample with both eyes active)
                overlaps = false
                for k = i:r_end
                    if in_L[k] && in_R[k]
                        overlaps = true
                        break
                    end
                end
                if overlaps
                    dx_m = 0.5 * (dx_L[idx_L] + dx_R[idx_R])
                    dy_m = 0.5 * (dy_L[idx_L] + dy_R[idx_R])
                    amp_m = 0.5 * (ampl_L[idx_L] + ampl_R[idx_R])
                    pv_m = max(pvel_L[idx_L], pvel_R[idx_R])
                    for k = i:r_end
                        in_out[k] = true
                        dx_out[k] = dx_m
                        dy_out[k] = dy_m
                        ampl_out[k] = amp_m
                        pvel_out[k] = pv_m
                    end
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
    detect_microsaccades!(df::EyeData; eye=:auto, lambda=6.0,
                           min_duration_ms=6, max_amplitude=2.0,
                           group_by=:auto, prefix=nothing,
                           blink_margin_ms=20, binocular=false)

Detect microsaccades using the Engbert & Kliegl (2003) velocity-based algorithm.
When `binocular=true`, runs detection independently on the left (`gxL`, `gyL`) and
right (`gxR`, `gyR`) eyes and retains only binocular microsaccades with temporal
overlap across both eyes.

Adds columns to the DataFrame (or `[prefix]_in_msacc`, etc. when `prefix` is given):

- `in_msacc`: `Bool`, `true` during a microsaccade
- `msacc_dx`, `msacc_dy`: microsaccade displacement (`end - start`, in coordinate units)
- `msacc_ampl`: microsaccade amplitude (degrees of visual angle)
- `msacc_pvel`: microsaccade peak velocity (°/s)
"""
function detect_microsaccades!(
    df::EyeData;
    eye::Symbol = :auto,
    lambda::Real = 6.0,
    min_duration_ms::Int = 6,
    max_amplitude::Real = 2.0,
    group_by = :auto,
    prefix::Union{Nothing,Symbol} = nothing,
    blink_margin_ms::Int = 20,
    binocular::Bool = false,
)
    d = df.df
    n = nrow(d)
    sr = df.sample_rate
    min_dur_samples = max(1, round(Int, min_duration_ms * sr / 1000.0))
    blink_pad = max(0, round(Int, blink_margin_ms * sr / 1000.0))
    c_blink = _prefixed_sym(prefix, :in_blink)
    blink_mask = hasproperty(d, c_blink) ? d[!, c_blink] :
                 (hasproperty(d, :in_blink) ? d[!, :in_blink] : nothing)
    group_cols = _resolve_group_cols(df, group_by)
    lam = Float64(lambda)
    max_amp = Float64(max_amplitude)

    vx = Float64[]
    vy = Float64[]
    work1 = Float64[]
    work2 = Float64[]

    in_msacc = falses(n)
    msacc_dx = fill(NaN, n)
    msacc_dy = fill(NaN, n)
    msacc_ampl = fill(NaN, n)
    msacc_pvel = fill(NaN, n)

    if binocular
        (hasproperty(d, :gxL) && hasproperty(d, :gyL) && hasproperty(d, :gxR) && hasproperty(d, :gyR)) ||
            throw(ArgumentError("binocular=true requires both left (:gxL, :gyL) and right (:gxR, :gyR) gaze columns."))
        gxL_all = _as_float_vec(d[!, :gxL])
        gyL_all = _as_float_vec(d[!, :gyL])
        gxR_all = _as_float_vec(d[!, :gxR])
        gyR_all = _as_float_vec(d[!, :gyR])
        ppdL = _eye_units_per_deg(df, :left)
        ppdR = _eye_units_per_deg(df, :right)

        in_L = falses(n)
        dx_L = fill(NaN, n)
        dy_L = fill(NaN, n)
        ampl_L = fill(NaN, n)
        pvel_L = fill(NaN, n)

        in_R = falses(n)
        dx_R = fill(NaN, n)
        dy_R = fill(NaN, n)
        ampl_R = fill(NaN, n)
        pvel_R = fill(NaN, n)

        grouped = groupby(d, group_cols; skipmissing = true)
        for g in grouped
            idxs = parentindices(g)[1]
            isempty(idxs) && continue
            _detect_microsaccades_trial!(
                in_L, dx_L, dy_L, ampl_L, pvel_L,
                gxL_all, gyL_all, blink_mask, blink_pad, idxs,
                vx, vy, work1, work2, lam, min_dur_samples, max_amp, ppdL, sr,
            )
            _detect_microsaccades_trial!(
                in_R, dx_R, dy_R, ampl_R, pvel_R,
                gxR_all, gyR_all, blink_mask, blink_pad, idxs,
                vx, vy, work1, work2, lam, min_dur_samples, max_amp, ppdR, sr,
            )
        end
        _foreach_trial_segment(d) do lo, hi
            _combine_binocular_microsaccades!(
                in_msacc, msacc_dx, msacc_dy, msacc_ampl, msacc_pvel,
                in_L, dx_L, dy_L, ampl_L, pvel_L,
                in_R, dx_R, dy_R, ampl_R, pvel_R,
                lo, hi,
            )
            return nothing
        end

        d[!, _prefixed_sym(prefix, :in_msacc)] = in_msacc
        d[!, _prefixed_sym(prefix, :msacc_dx)] = msacc_dx
        d[!, _prefixed_sym(prefix, :msacc_dy)] = msacc_dy
        d[!, _prefixed_sym(prefix, :msacc_ampl)] = msacc_ampl
        d[!, _prefixed_sym(prefix, :msacc_pvel)] = msacc_pvel
        return df
    end

    eye = _resolve_eye(df, eye)
    _ensure_eye_cols!(df, eye)
    ecols = _eye_columns(eye)
    gx_all = _as_float_vec(d[!, ecols.gx])
    gy_all = _as_float_vec(d[!, ecols.gy])
    ppd = _eye_units_per_deg(df, eye)

    can_fast_seg =
        (group_cols == Symbol[:trial] || group_cols == Symbol[:participant, :trial]) &&
        hasproperty(d, :trial) &&
        _trial_col_is_monotone_blocks(
            d[!, :trial],
            group_cols == Symbol[:participant, :trial] ? d[!, :participant] : nothing,
        )

    if can_fast_seg
        tr_col = d[!, :trial]
        pt_col = group_cols == Symbol[:participant, :trial] ? d[!, :participant] : nothing
        _foreach_trial_segment_cols(n, tr_col, pt_col) do lo, hi
            ismissing(tr_col[lo]) && return nothing
            (!isnothing(pt_col) && ismissing(pt_col[lo])) && return nothing
            _detect_microsaccades_trial!(
                in_msacc,
                msacc_dx,
                msacc_dy,
                msacc_ampl,
                msacc_pvel,
                gx_all,
                gy_all,
                blink_mask,
                blink_pad,
                lo:hi,
                vx,
                vy,
                work1,
                work2,
                lam,
                min_dur_samples,
                max_amp,
                ppd,
                sr,
            )
            return nothing
        end
    else
        grouped = groupby(d, group_cols; skipmissing = true)
        for g in grouped
            idxs = parentindices(g)[1]
            _detect_microsaccades_trial!(
                in_msacc,
                msacc_dx,
                msacc_dy,
                msacc_ampl,
                msacc_pvel,
                gx_all,
                gy_all,
                blink_mask,
                blink_pad,
                idxs,
                vx,
                vy,
                work1,
                work2,
                lam,
                min_dur_samples,
                max_amp,
                ppd,
                sr,
            )
        end
    end

    d[!, _prefixed_sym(prefix, :in_msacc)] = in_msacc
    d[!, _prefixed_sym(prefix, :msacc_dx)] = msacc_dx
    d[!, _prefixed_sym(prefix, :msacc_dy)] = msacc_dy
    d[!, _prefixed_sym(prefix, :msacc_ampl)] = msacc_ampl
    d[!, _prefixed_sym(prefix, :msacc_pvel)] = msacc_pvel

    return df
end

function _extract_microsaccades_kernel(
    mask::AbstractVector{Bool},
    times::AbstractVector{<:Real},
    sample_period_ms::Float64,
    dx_col::Union{Nothing,AbstractVector{<:Real}},
    dy_col::Union{Nothing,AbstractVector{<:Real}},
    ampl_col::Union{Nothing,AbstractVector{<:Real}},
    pvel_col::Union{Nothing,AbstractVector{<:Real}},
    part_col::Union{Nothing,AbstractVector},
    trial_col::Union{Nothing,AbstractVector},
    include_groups::Bool,
)
    n = length(mask)
    m = _count_event_runs(mask, times, part_col, trial_col, nothing, sample_period_ms)

    sttime = Vector{Float64}(undef, m)
    entime = Vector{Float64}(undef, m)
    dur = Vector{Int32}(undef, m)
    dx = Vector{Float64}(undef, m)
    dy = Vector{Float64}(undef, m)
    ampl = Vector{Float64}(undef, m)
    pvel = Vector{Float64}(undef, m)
    angle = Vector{Float64}(undef, m)
    p_out = (include_groups && !isnothing(part_col)) ? similar(part_col, m) : nothing
    tr_out = (include_groups && !isnothing(trial_col)) ? similar(trial_col, m) : nothing

    k = 0
    i = 1
    @inbounds while i <= n
        if mask[i]
            j_raw = i + 1
            while j_raw <= n && mask[j_raw]
                j_raw += 1
            end
            while i < j_raw
                j = _next_event_run_end(
                    times,
                    part_col,
                    trial_col,
                    nothing,
                    sample_period_ms,
                    i,
                    j_raw,
                )
                k += 1
                t_s = Float64(times[i])
                t_e = Float64(times[j-1])
                sttime[k] = t_s
                entime[k] = t_e
                dur[k] = _safe_event_dur(nothing, i, t_s, t_e, sample_period_ms)
                dxi = isnothing(dx_col) ? NaN : Float64(dx_col[i])
                dyi = isnothing(dy_col) ? NaN : Float64(dy_col[i])
                dx[k] = dxi
                dy[k] = dyi
                ampl[k] = isnothing(ampl_col) ? NaN : Float64(ampl_col[i])
                pvel[k] = isnothing(pvel_col) ? NaN : Float64(pvel_col[i])
                angle[k] = (!isnan(dxi) && !isnan(dyi)) ? atan(dyi, dxi) : NaN
                !isnothing(p_out) && (p_out[k] = part_col[i])
                !isnothing(tr_out) && (tr_out[k] = trial_col[i])
                i = j
            end
        else
            i += 1
        end
    end

    result = DataFrame(
        sttime = sttime,
        entime = entime,
        duration = dur,
        dx = dx,
        dy = dy,
        ampl = ampl,
        pvel = pvel,
        angle = angle;
        copycols = false,
    )
    if include_groups
        !isnothing(tr_out) && insertcols!(result, 1, :trial => tr_out; copycols = false)
        !isnothing(p_out) && insertcols!(result, 1, :participant => p_out; copycols = false)
    end
    return result
end

"""
    microsaccades(ed::EyeData; prefix=nothing, selection=nothing, include_groups=false) -> DataFrame

Extract a one-row-per-microsaccade `DataFrame` (`sttime`, `entime`, `duration`, `dx`, `dy`,
`ampl`, `pvel`, `angle`) from `in_msacc` (or `[prefix]_in_msacc`) after calling
[`detect_microsaccades!`](@ref). Set `include_groups=true` to prepend `:participant` and `:trial`.
"""
function microsaccades(
    ed::EyeData;
    prefix::Union{Nothing,Symbol} = nothing,
    selection = nothing,
    include_groups::Bool = false,
)
    c_in = _prefixed_sym(prefix, :in_msacc)
    df = isnothing(selection) ? ed.df : _apply_selection_view(ed, selection)
    !hasproperty(df, c_in) && return DataFrame()

    c_dx = _prefixed_sym(prefix, :msacc_dx)
    c_dy = _prefixed_sym(prefix, :msacc_dy)
    c_amp = _prefixed_sym(prefix, :msacc_ampl)
    c_pv = _prefixed_sym(prefix, :msacc_pvel)
    sample_period_ms = ed.sample_rate > 0 ? 1000.0 / ed.sample_rate : 1.0

    return _extract_microsaccades_kernel(
        df[!, c_in],
        df[!, :time],
        sample_period_ms,
        hasproperty(df, c_dx) ? df[!, c_dx] : nothing,
        hasproperty(df, c_dy) ? df[!, c_dy] : nothing,
        hasproperty(df, c_amp) ? df[!, c_amp] : nothing,
        hasproperty(df, c_pv) ? df[!, c_pv] : nothing,
        hasproperty(df, :participant) ? df[!, :participant] : nothing,
        hasproperty(df, :trial) ? df[!, :trial] : nothing,
        include_groups,
    )
end
