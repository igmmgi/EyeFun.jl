function _mark_not_nan!(valid::BitVector, col::AbstractVector{<:Real})
    @inbounds for i in eachindex(valid, col)
        if valid[i] && isnan(col[i])
            valid[i] = false
        end
    end
    return valid
end

function _slice_float64(col::AbstractVector{<:Real}, idx::Vector{Int})
    out = Vector{Float64}(undef, length(idx))
    @inbounds for i in eachindex(idx)
        out[i] = Float64(col[idx[i]])
    end
    return out
end

"""
    prepare_analysis_data(df::EyeData; selection=nothing, eye=:auto,
                          group_by=:auto, measures=[:pupil], prefix=nothing)

Reshape eye-tracking data into a one-row-per-sample long-format DataFrame.

Returns a DataFrame with columns:
- Group columns (e.g. `:trial` or `[:participant, :trial]`)
- `time`: time in ms (relative to trial start or `trial_time_zero`)
- `sample`: sample index within trial
- Requested measure columns (e.g. `:pupil`, `:gaze_x`, `:gaze_y`, `:velocity`)
- Event columns if present (`:in_fix`, `:in_sacc`, `:in_blink`)

Missing/NaN samples are excluded.
"""
function prepare_analysis_data(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :auto,
    measures::Vector{Symbol} = [:pupil],
    prefix::Union{Nothing,Symbol} = nothing,
)
    for m in measures
        m in (:pupil, :gaze_x, :gaze_y, :velocity) ||
            error("Unknown measure :$m. Use :pupil, :gaze_x, :gaze_y, or :velocity.")
    end

    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)

    only_pupil = all(==(:pupil), measures)
    eye = _resolve_eye(samples, eye; cols = only_pupil ? :pupil : :gaze)
    d = df.df
    needs_gaze = !only_pupil
    needs_pupil = :pupil in measures
    needs_gx = :gaze_x in measures
    needs_gy = :gaze_y in measures
    needs_vel = :velocity in measures

    gx_all, gy_all = needs_gaze ? _get_gaze_vecs(d, eye) : (Float64[], Float64[])
    pa_all = needs_pupil ? _get_pupil_vec(d, eye) : Float64[]
    ppd = needs_vel ? _eye_units_per_deg(df, eye) : 0.0
    vel_scale = needs_vel ? Float64(df.sample_rate) / (6.0 * ppd) : 0.0
    has_trel = _has_active_time_rel(d)
    trel_col = has_trel ? d[!, :time_rel] : nothing
    time_col = d[!, :time]

    cand_events = (
        _prefixed_sym(prefix, :in_fix),
        _prefixed_sym(prefix, :in_sacc),
        _prefixed_sym(prefix, :in_blink),
    )
    event_cols = Symbol[ec for ec in cand_events if hasproperty(samples, ec)]
    ev_src = AbstractVector[d[!, ec] for ec in event_cols]

    est = nrow(samples)
    row_src_idx = sizehint!(Int[], est)
    out_time = sizehint!(Float64[], est)
    out_sample = sizehint!(Int[], est)
    out_pa = needs_pupil ? sizehint!(Float64[], est) : Float64[]
    out_gx = needs_gx ? sizehint!(Float64[], est) : Float64[]
    out_gy = needs_gy ? sizehint!(Float64[], est) : Float64[]
    out_vel = needs_vel ? sizehint!(Float64[], est) : Float64[]

    t_buf = Float64[]
    v_buf = Float64[]
    gx_buf = Float64[]
    gy_buf = Float64[]

    @inbounds for gi = 1:length(grouped)
        rows = parentindices(grouped[gi])[1]
        m = length(rows)
        m == 0 && continue
        _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, rows)

        if needs_vel
            length(gx_buf) < m && resize!(gx_buf, m)
            length(gy_buf) < m && resize!(gy_buf, m)
            length(v_buf) < m && resize!(v_buf, m)
            for k = 1:m
                rk = rows[k]
                gx_buf[k] = Float64(gx_all[rk])
                gy_buf[k] = Float64(gy_all[rk])
                v_buf[k] = NaN
            end
            _compute_velocity_deg!(v_buf, gx_buf, gy_buf, 1, m, vel_scale)
        end

        for k = 1:m
            tk = t_buf[k]
            isnan(tk) && continue
            rk = rows[k]
            if needs_pupil && isnan(pa_all[rk])
                continue
            end
            if needs_gx && isnan(gx_all[rk])
                continue
            end
            if needs_gy && isnan(gy_all[rk])
                continue
            end
            if needs_vel && isnan(v_buf[k])
                continue
            end

            push!(row_src_idx, rk)
            push!(out_time, tk)
            push!(out_sample, k)
            needs_pupil && push!(out_pa, Float64(pa_all[rk]))
            needs_gx && push!(out_gx, Float64(gx_all[rk]))
            needs_gy && push!(out_gy, Float64(gy_all[rk]))
            needs_vel && push!(out_vel, v_buf[k])
        end
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_src_idx) for gc in group_cols
    ]
    push!(pairs_out, :time => out_time)
    push!(pairs_out, :sample => out_sample)
    for m in measures
        if m == :pupil
            push!(pairs_out, :pupil => copy(out_pa))
        elseif m == :gaze_x
            push!(pairs_out, :gaze_x => copy(out_gx))
        elseif m == :gaze_y
            push!(pairs_out, :gaze_y => copy(out_gy))
        else
            push!(pairs_out, :velocity => copy(out_vel))
        end
    end
    for (ei, ec) in enumerate(event_cols)
        push!(pairs_out, ec => _gather_group_col(ev_src[ei], row_src_idx))
    end
    return DataFrame(pairs_out; copycols = false)
end

"""
    growth_curve_data(df::DataFrame; time_col=:time_bin, degree=3)

Add orthogonal polynomial time columns to a DataFrame for growth curve analysis.

Takes output from `time_bin()` or `proportion_of_looks()` and adds columns
`ot1`, `ot2`, ..., `otN` containing orthogonal polynomial values computed
over the time column.
"""
function growth_curve_data(df::DataFrame; time_col::Symbol = :time_bin, degree::Int = 3)
    hasproperty(df, time_col) ||
        error("Column :$time_col not found. Specify time_col= or use time_bin() first.")
    nrow(df) == 0 && error("Empty DataFrame.")

    time_vals = sort(unique(df[!, time_col]))
    n_times = length(time_vals)
    degree = min(degree, n_times - 1)
    result = copy(df)
    degree < 1 && return result

    polys = _orthogonal_polynomials(time_vals, degree)
    time_to_idx = Dict(tv => i for (i, tv) in enumerate(time_vals))
    tcol = df[!, time_col]
    row_indices = Int[time_to_idx[tv] for tv in tcol]

    for d = 1:degree
        col_name = Symbol("ot$d")
        bcol = @view polys[:, d]
        result[!, col_name] = Float64[bcol[ri] for ri in row_indices]
    end

    return result
end

"""Compute orthogonal polynomials via Gram-Schmidt on [-1, 1]-scaled time points."""
function _orthogonal_polynomials(x::Vector{<:Real}, degree::Int)
    n = length(x)
    x_min, x_max = extrema(x)
    x_norm = if x_max > x_min
        inv_span = 2.0 / (x_max - x_min)
        Float64[(Float64(xi) - x_min) * inv_span - 1.0 for xi in x]
    else
        zeros(Float64, n)
    end

    ortho = zeros(Float64, n, degree + 1)
    ortho[:, 1] .= 1.0 / sqrt(Float64(n))

    for d = 1:degree
        v = x_norm .^ d
        for j = 1:d
            oj = @view ortho[:, j]
            denom = dot(oj, oj)
            if denom > 0.0
                proj = dot(v, oj) / denom
                v .-= proj .* oj
            end
        end
        norm_v = norm(v)
        if norm_v > 0.0
            ortho[:, d+1] .= v ./ norm_v
        end
    end

    return ortho[:, 2:(degree+1)]
end

"""
    empirical_logit(count::Real, total::Real; weights=false)
    empirical_logit(counts::AbstractVector{<:Real}, totals::AbstractVector{<:Real}; weights=false)
    empirical_logit(df::DataFrame, aoi_col::Symbol; n_col=:n, weights=true) -> DataFrame

Compute the Barr (2008) empirical logit transformation for Visual World Paradigm
fixation proportions:

```math
\\eta = \\log\\!\\left(\\frac{y + 0.5}{N - y + 0.5}\\right), \\qquad
w = \\frac{1}{\\frac{1}{y + 0.5} + \\frac{1}{N - y + 0.5}}
```

- On scalar or vector `(count, total)` inputs: returns `η` when `weights=false`, or a
  `NamedTuple` `(elog = η, weight = w)` when `weights=true`.
- On a `DataFrame` (e.g. from `proportion_of_looks(ed, aois; include_n=true)`): converts
  proportion column `aoi_col` (multiplying by `n_col` when values lie in `[0, 1]`) and returns
  a copy with `Symbol(aoi_col, :_elog)` (and `Symbol(aoi_col, :_weight)` when `weights=true`).
"""
function empirical_logit(count::Real, total::Real; weights::Bool = false)
    n = Float64(total)
    y = Float64(count)
    if isnan(n) || isnan(y) || n <= 0.0
        return weights ? (elog = NaN, weight = NaN) : NaN
    end
    yc = clamp(y, 0.0, n)
    a = yc + 0.5
    b = (n - yc) + 0.5
    eta = log(a / b)
    w = 1.0 / (1.0 / a + 1.0 / b)
    return weights ? (elog = eta, weight = w) : eta
end

function empirical_logit(
    counts::AbstractVector{<:Real},
    totals::AbstractVector{<:Real};
    weights::Bool = false,
)
    length(counts) == length(totals) ||
        throw(DimensionMismatch("counts and totals must have equal length."))
    m = length(counts)
    elog = Vector{Float64}(undef, m)
    wvec = weights ? Vector{Float64}(undef, m) : Float64[]
    @inbounds for i = 1:m
        n = Float64(totals[i])
        y = Float64(counts[i])
        if isnan(n) || isnan(y) || n <= 0.0
            elog[i] = NaN
            weights && (wvec[i] = NaN)
        else
            yc = clamp(y, 0.0, n)
            a = yc + 0.5
            b = (n - yc) + 0.5
            elog[i] = log(a / b)
            weights && (wvec[i] = 1.0 / (1.0 / a + 1.0 / b))
        end
    end
    return weights ? (elog = elog, weight = wvec) : elog
end

function empirical_logit(
    df::DataFrame,
    aoi_col::Symbol;
    n_col::Symbol = :n,
    weights::Bool = true,
)
    hasproperty(df, aoi_col) ||
        throw(ArgumentError("Column :$aoi_col not found in DataFrame."))
    hasproperty(df, n_col) || throw(
        ArgumentError(
            "Sample-count column :$n_col not found in DataFrame. Call proportion_of_looks(...; include_n=true) first.",
        ),
    )
    raw_col = df[!, aoi_col]
    tot_col = df[!, n_col]
    m = nrow(df)

    # Detect whether aoi_col stores proportions in [0, 1] (from proportion_of_looks) or integer counts
    is_prop = eltype(raw_col) <: Union{Missing,AbstractFloat} && all(raw_col) do v
        ismissing(v) || isnan(v) || (0.0 - 1e-9 <= Float64(v) <= 1.0 + 1e-9)
    end

    cnts = Vector{Float64}(undef, m)
    tots = Vector{Float64}(undef, m)
    @inbounds for i = 1:m
        rv = raw_col[i]
        tv = tot_col[i]
        if ismissing(rv) || ismissing(tv)
            cnts[i] = NaN
            tots[i] = NaN
        else
            nf = Float64(tv)
            vf = Float64(rv)
            tots[i] = nf
            cnts[i] = is_prop ? vf * nf : vf
        end
    end

    out = copy(df)
    if weights
        res = empirical_logit(cnts, tots; weights = true)
        out[!, Symbol(aoi_col, :_elog)] = res.elog
        out[!, Symbol(aoi_col, :_weight)] = res.weight
    else
        out[!, Symbol(aoi_col, :_elog)] = empirical_logit(cnts, tots; weights = false)
    end
    return out
end

const _LANCZOS_COEFFS = (
    0.99999999999980993,
    676.5203681218851,
    -1259.1392167224028,
    771.32342877765313,
    -176.61502916214059,
    12.507343278686905,
    -0.13857109526572012,
    9.9843695780195716e-6,
    1.5056327351493116e-7,
)

function _lgamma_pos(z::Float64)::Float64
    if z < 0.5
        return log(π / sinpi(z)) - _lgamma_pos(1.0 - z)
    end
    zm1 = z - 1.0
    x = _LANCZOS_COEFFS[1]
    @inbounds for k = 2:9
        x += _LANCZOS_COEFFS[k] / (zm1 + Float64(k - 1))
    end
    t = zm1 + 7.5
    return 0.9189385332046727 + (zm1 + 0.5) * log(t) - t + log(x)
end

function _betacf(a::Float64, b::Float64, x::Float64)::Float64
    fpmin = 1e-300
    qab = a + b
    qap = a + 1.0
    qam = a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    abs(d) < fpmin && (d = fpmin)
    d = 1.0 / d
    h = d
    for m = 1:200
        m2 = 2 * m
        mf = Float64(m)
        m2f = Float64(m2)
        aa = mf * (b - mf) * x / ((qam + m2f) * (a + m2f))
        d = 1.0 + aa * d
        abs(d) < fpmin && (d = fpmin)
        c = 1.0 + aa / c
        abs(c) < fpmin && (c = fpmin)
        d = 1.0 / d
        h *= d * c
        aa = -(a + mf) * (qab + mf) * x / ((a + m2f) * (qap + m2f))
        d = 1.0 + aa * d
        abs(d) < fpmin && (d = fpmin)
        c = 1.0 + aa / c
        abs(c) < fpmin && (c = fpmin)
        d = 1.0 / d
        del = d * c
        h *= del
        abs(del - 1.0) < 3e-14 && break
    end
    return h
end

function _incbeta(x::Float64, a::Float64, b::Float64)::Float64
    x <= 0.0 && return 0.0
    x >= 1.0 && return 1.0
    lbeta = _lgamma_pos(a) + _lgamma_pos(b) - _lgamma_pos(a + b)
    bt = exp(a * log(x) + b * log(1.0 - x) - lbeta)
    if x < (a + 1.0) / (a + b + 2.0)
        return bt * _betacf(a, b, x) / a
    else
        return 1.0 - bt * _betacf(b, a, 1.0 - x) / b
    end
end

@inline function _student_t_two_tailed_p(t_stat::Float64, df_nu::Float64)::Float64
    (!isfinite(t_stat) || df_nu <= 0.0) && return 1.0
    x = df_nu / (df_nu + t_stat * t_stat)
    return clamp(_incbeta(x, 0.5 * df_nu, 0.5), 0.0, 1.0)
end

function _student_t_crit_two_tailed(alpha::Float64, df_nu::Float64)::Float64
    lo = 0.0
    hi = 64.0
    while _student_t_two_tailed_p(hi, df_nu) > alpha && hi < 1e6
        hi *= 2.0
    end
    for _ = 1:56
        mid = 0.5 * (lo + hi)
        if _student_t_two_tailed_p(mid, df_nu) > alpha
            lo = mid
        else
            hi = mid
        end
    end
    return 0.5 * (lo + hi)
end

function _paired_t_across_bins!(
    t_out::Vector{Float64},
    diff_mat::Matrix{Float64},
    signs::Union{Nothing,Vector{Float64}},
)
    n_subj, n_bins = size(diff_mat)
    @inbounds for b = 1:n_bins
        cnt = 0
        s = 0.0
        for i = 1:n_subj
            v = diff_mat[i, b]
            isnan(v) && continue
            sv = isnothing(signs) ? v : (v * signs[i])
            s += sv
            cnt += 1
        end
        if cnt < 2
            t_out[b] = 0.0
            continue
        end
        mu = s / cnt
        ss = 0.0
        for i = 1:n_subj
            v = diff_mat[i, b]
            isnan(v) && continue
            sv = isnothing(signs) ? v : (v * signs[i])
            d = sv - mu
            ss += d * d
        end
        sd = sqrt(ss / (cnt - 1))
        t_out[b] = sd > 1e-15 ? (mu / (sd / sqrt(Float64(cnt)))) : 0.0
    end
    return t_out
end

function _unpaired_t_across_bins!(
    t_out::Vector{Float64},
    val_mat::Matrix{Float64},
    group_labels::Vector{Bool}, # true = cond1, false = cond2
)
    n_units, n_bins = size(val_mat)
    @inbounds for b = 1:n_bins
        n1 = 0
        n2 = 0
        s1 = 0.0
        s2 = 0.0
        for i = 1:n_units
            v = val_mat[i, b]
            isnan(v) && continue
            if group_labels[i]
                s1 += v
                n1 += 1
            else
                s2 += v
                n2 += 1
            end
        end
        if n1 < 2 || n2 < 2
            t_out[b] = 0.0
            continue
        end
        m1 = s1 / n1
        m2 = s2 / n2
        ss1 = 0.0
        ss2 = 0.0
        for i = 1:n_units
            v = val_mat[i, b]
            isnan(v) && continue
            if group_labels[i]
                d = v - m1
                ss1 += d * d
            else
                d = v - m2
                ss2 += d * d
            end
        end
        sp2 = (ss1 + ss2) / (n1 + n2 - 2)
        se = sqrt(sp2 * (1.0 / n1 + 1.0 / n2))
        t_out[b] = se > 1e-15 ? ((m1 - m2) / se) : 0.0
    end
    return t_out
end

function _max_abs_cluster_mass(t_vec::Vector{Float64}, t_crit::Float64)::Float64
    max_m = 0.0
    cur_pos = 0.0
    cur_neg = 0.0
    @inbounds for b in eachindex(t_vec)
        tb = t_vec[b]
        if tb > t_crit
            cur_pos += tb
            if cur_neg > max_m
                max_m = cur_neg
            end
            cur_neg = 0.0
        elseif tb < -t_crit
            cur_neg += -tb
            if cur_pos > max_m
                max_m = cur_pos
            end
            cur_pos = 0.0
        else
            cur_pos > max_m && (max_m = cur_pos)
            cur_neg > max_m && (max_m = cur_neg)
            cur_pos = 0.0
            cur_neg = 0.0
        end
    end
    cur_pos > max_m && (max_m = cur_pos)
    cur_neg > max_m && (max_m = cur_neg)
    return max_m
end

"""
    cluster_permutation_test(df::DataFrame; value_col=:value, time_col=:time_bin,
                             condition_col=:condition, subject_col=:participant,
                             n_permutations=1000, threshold_p=0.05,
                             threshold_t=nothing, paired=true, rng=nothing) -> DataFrame

Run a Maris & Oostenveld (2007) cluster-based permutation test across time bins to control
the family-wise error rate (FWER) when comparing two conditions on pupil or Visual World
time-course data (e.g. from [`time_bin`](@ref), [`proportion_of_looks`](@ref), or
[`empirical_logit`](@ref)).

Aggregates observations within `(subject_col, condition_col, time_col)` cells first, computes
pointwise `t`-statistics (`level1 - level2`), groups contiguous supra-threshold time bins into
clusters, and evaluates exact Monte Carlo cluster-mass `p`-values across `n_permutations`
sign-flips (`paired=true`) or label shuffles (`paired=false`).

Returns a `DataFrame` with columns:
`cluster_id`, `t_start`, `t_end`, `n_bins`, `direction`, `cluster_mass`, `peak_t`, `p_value`.
"""
function cluster_permutation_test(
    df::DataFrame;
    value_col::Symbol = :value,
    time_col::Symbol = :time_bin,
    condition_col::Symbol = :condition,
    subject_col::Symbol = :participant,
    n_permutations::Int = 1000,
    threshold_p::Real = 0.05,
    threshold_t::Union{Nothing,Real} = nothing,
    paired::Bool = true,
    rng = nothing,
)
    vcol = (value_col === :value && !hasproperty(df, :value) && hasproperty(df, :mean)) ? :mean : value_col
    hasproperty(df, vcol) || throw(ArgumentError("Value column :$vcol not found in DataFrame."))
    hasproperty(df, time_col) || throw(ArgumentError("Time column :$time_col not found in DataFrame."))
    hasproperty(df, condition_col) || throw(ArgumentError("Condition column :$condition_col not found in DataFrame."))
    hasproperty(df, subject_col) || throw(ArgumentError("Subject column :$subject_col not found in DataFrame."))
    n_permutations >= 1 || throw(ArgumentError("n_permutations must be >= 1 (got $n_permutations)."))
    (0.0 < threshold_p < 1.0) || throw(ArgumentError("threshold_p must lie in (0, 1) (got $threshold_p)."))

    cond_levels = sort(collect(Set(skipmissing(df[!, condition_col]))))
    length(cond_levels) == 2 || throw(
        ArgumentError(
            "cluster_permutation_test requires exactly 2 non-missing levels in :$condition_col (got $(length(cond_levels)): $cond_levels).",
        ),
    )
    c1, c2 = cond_levels[1], cond_levels[2]

    time_bins = sort(Float64[Float64(t) for t in unique(skipmissing(df[!, time_col])) if !isnan(Float64(t))])
    n_bins = length(time_bins)
    n_bins > 0 || throw(ArgumentError("No valid time bins found in :$time_col."))
    time_idx = Dict{Float64,Int}(time_bins[b] => b for b = 1:n_bins)

    subjects = sort(collect(Set(skipmissing(df[!, subject_col]))))
    n_subj = length(subjects)
    subj_idx = Dict{Any,Int}(subjects[i] => i for i = 1:n_subj)

    rng_local = isnothing(rng) ? Random.default_rng() : rng
    t_obs = Vector{Float64}(undef, n_bins)
    t_perm = Vector{Float64}(undef, n_bins)
    null_max = Vector{Float64}(undef, n_permutations)

    if paired
        n_subj >= 2 || throw(ArgumentError("Paired cluster_permutation_test requires at least 2 subjects (got $n_subj)."))
        sum1 = zeros(Float64, n_subj, n_bins)
        cnt1 = zeros(Int, n_subj, n_bins)
        sum2 = zeros(Float64, n_subj, n_bins)
        cnt2 = zeros(Int, n_subj, n_bins)

        s_col = df[!, subject_col]
        c_col = df[!, condition_col]
        t_col = df[!, time_col]
        v_vec = df[!, vcol]
        @inbounds for r = 1:nrow(df)
            sv = s_col[r]
            cv = c_col[r]
            tv = t_col[r]
            vv = v_vec[r]
            (ismissing(sv) || ismissing(cv) || ismissing(tv) || ismissing(vv)) && continue
            vf = Float64(vv)
            tf = Float64(tv)
            (isnan(vf) || isnan(tf)) && continue
            si = get(subj_idx, sv, 0)
            bi = get(time_idx, tf, 0)
            (si == 0 || bi == 0) && continue
            if isequal(cv, c1)
                sum1[si, bi] += vf
                cnt1[si, bi] += 1
            elseif isequal(cv, c2)
                sum2[si, bi] += vf
                cnt2[si, bi] += 1
            end
        end

        diff_mat = fill(NaN, n_subj, n_bins)
        @inbounds for b = 1:n_bins, i = 1:n_subj
            if cnt1[i, b] > 0 && cnt2[i, b] > 0
                diff_mat[i, b] = (sum1[i, b] / cnt1[i, b]) - (sum2[i, b] / cnt2[i, b])
            end
        end

        t_crit = isnothing(threshold_t) ?
            _student_t_crit_two_tailed(Float64(threshold_p), Float64(n_subj - 1)) :
            Float64(threshold_t)

        _paired_t_across_bins!(t_obs, diff_mat, nothing)

        signs = Vector{Float64}(undef, n_subj)
        @inbounds for p = 1:n_permutations
            for i = 1:n_subj
                signs[i] = rand(rng_local, Bool) ? 1.0 : -1.0
            end
            _paired_t_across_bins!(t_perm, diff_mat, signs)
            null_max[p] = _max_abs_cluster_mass(t_perm, t_crit)
        end
    else
        # Unpaired: each (subject, condition) pair is an independent unit
        unit_keys = Tuple{Any,Bool}[]
        unit_map = Dict{Tuple{Any,Bool},Int}()
        s_col = df[!, subject_col]
        c_col = df[!, condition_col]
        t_col = df[!, time_col]
        v_vec = df[!, vcol]

        for r = 1:nrow(df)
            sv = s_col[r]
            cv = c_col[r]
            (ismissing(sv) || ismissing(cv)) && continue
            is_c1 = isequal(cv, c1)
            (is_c1 || isequal(cv, c2)) || continue
            uk = (sv, is_c1)
            if !haskey(unit_map, uk)
                push!(unit_keys, uk)
                unit_map[uk] = length(unit_keys)
            end
        end

        n_units = length(unit_keys)
        labels_orig = Bool[uk[2] for uk in unit_keys]
        n1_tot = count(labels_orig)
        n2_tot = n_units - n1_tot
        (n1_tot >= 2 && n2_tot >= 2) || throw(
            ArgumentError("Unpaired cluster_permutation_test requires >= 2 subjects per condition."),
        )

        usum = zeros(Float64, n_units, n_bins)
        ucnt = zeros(Int, n_units, n_bins)
        @inbounds for r = 1:nrow(df)
            sv = s_col[r]
            cv = c_col[r]
            tv = t_col[r]
            vv = v_vec[r]
            (ismissing(sv) || ismissing(cv) || ismissing(tv) || ismissing(vv)) && continue
            vf = Float64(vv)
            tf = Float64(tv)
            (isnan(vf) || isnan(tf)) && continue
            is_c1 = isequal(cv, c1)
            (is_c1 || isequal(cv, c2)) || continue
            ui = unit_map[(sv, is_c1)]
            bi = get(time_idx, tf, 0)
            bi == 0 && continue
            usum[ui, bi] += vf
            ucnt[ui, bi] += 1
        end

        val_mat = fill(NaN, n_units, n_bins)
        @inbounds for b = 1:n_bins, u = 1:n_units
            ucnt[u, b] > 0 && (val_mat[u, b] = usum[u, b] / ucnt[u, b])
        end

        t_crit = isnothing(threshold_t) ?
            _student_t_crit_two_tailed(Float64(threshold_p), Float64(n_units - 2)) :
            Float64(threshold_t)

        _unpaired_t_across_bins!(t_obs, val_mat, labels_orig)

        labels_perm = copy(labels_orig)
        @inbounds for p = 1:n_permutations
            Random.shuffle!(rng_local, labels_perm)
            _unpaired_t_across_bins!(t_perm, val_mat, labels_perm)
            null_max[p] = _max_abs_cluster_mass(t_perm, t_crit)
        end
    end

    cid_out = Int[]
    ts_out = Float64[]
    te_out = Float64[]
    nb_out = Int[]
    dir_out = Symbol[]
    mass_out = Float64[]
    pk_out = Float64[]
    pval_out = Float64[]

    b = 1
    cid = 0
    @inbounds while b <= n_bins
        tb = t_obs[b]
        if abs(tb) > t_crit
            is_pos = tb > 0.0
            b_end = b + 1
            mass = tb
            peak_t = tb
            while b_end <= n_bins && (is_pos ? (t_obs[b_end] > t_crit) : (t_obs[b_end] < -t_crit))
                tv_cur = t_obs[b_end]
                mass += tv_cur
                if abs(tv_cur) > abs(peak_t)
                    peak_t = tv_cur
                end
                b_end += 1
            end
            cid += 1
            abs_m = abs(mass)
            n_ge = 0
            for p = 1:n_permutations
                null_max[p] >= abs_m - 1e-12 && (n_ge += 1)
            end
            pval = (n_ge + 1.0) / (n_permutations + 1.0)

            push!(cid_out, cid)
            push!(ts_out, time_bins[b])
            push!(te_out, time_bins[b_end-1])
            push!(nb_out, b_end - b)
            push!(dir_out, is_pos ? :positive : :negative)
            push!(mass_out, round(mass; digits = 4))
            push!(pk_out, round(peak_t; digits = 4))
            push!(pval_out, round(pval; digits = 6))
            b = b_end
        else
            b += 1
        end
    end

    return DataFrame(
        cluster_id = cid_out,
        t_start = ts_out,
        t_end = te_out,
        n_bins = nb_out,
        direction = dir_out,
        cluster_mass = mass_out,
        peak_t = pk_out,
        p_value = pval_out;
        copycols = false,
    )
end
