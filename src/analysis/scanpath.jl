"""
    scanpath_similarity(df::EyeData, aois::Vector{<:AOI};
                        selection1, selection2, eye=:auto, method=:levenshtein,
                        time_window=nothing, prefix=nothing, kwargs...)
    scanpath_similarity(df::EyeData;
                        selection1, selection2, eye=:auto, method=:multimatch,
                        time_window=nothing, prefix=nothing, simplify=true,
                        amp_threshold_deg=2.0, dir_threshold_deg=45.0,
                        dur_threshold_ms=0.0)

Compare scanpaths between two selections using either AOI string-edit distance
(`method = :levenshtein`) or vector-based MultiMatch alignment (`method = :multimatch`;
Jarodzka et al., 2010; Dewhurst et al., 2012).

- For `method = :levenshtein` (requires `aois`): returns `(distance, similarity, seq1, seq2)`
  supporting arbitrary numbers of AOIs (`String` for `<= 26` AOIs, `Vector{String}` for `> 26`).
- For `method = :multimatch` (`aois` optional): aligns simplified saccade vectors via dynamic
  programming and returns `(vector, direction, length, position, duration, similarity)` with
  each dimension normalized to `[0, 1]`.
"""
function scanpath_similarity(
    df::EyeData,
    aois::Vector{<:AOI};
    selection1,
    selection2,
    eye::Symbol = :auto,
    method::Symbol = :levenshtein,
    time_window::Union{Nothing,Tuple} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
    kwargs...,
)
    method in (:levenshtein, :multimatch) ||
        error("Invalid method=:$method. Supported methods are :levenshtein and :multimatch.")
    if method == :multimatch
        return scanpath_similarity(
            df;
            selection1 = selection1,
            selection2 = selection2,
            eye = eye,
            method = :multimatch,
            time_window = time_window,
            prefix = prefix,
            kwargs...,
        )
    end
    _resolve_eye(df, eye)

    idx1 = _aoi_index_sequence(df, aois, selection1, time_window, prefix)
    idx2 = _aoi_index_sequence(df, aois, selection2, time_window, prefix)

    dist = _levenshtein(idx1, idx2)
    max_len = max(length(idx1), length(idx2))
    norm_dist = max_len > 0 ? dist / max_len : 0.0
    similarity = 1.0 - norm_dist

    seq1 = _format_aoi_sequence(idx1, aois)
    seq2 = _format_aoi_sequence(idx2, aois)

    return (
        distance = dist,
        similarity = round(similarity; digits = 4),
        seq1 = seq1,
        seq2 = seq2,
    )
end

function _extract_multimatch_fixations(
    df::EyeData,
    selection,
    time_window::Union{Nothing,Tuple},
    prefix::Union{Nothing,Symbol},
)::Vector{NTuple{3,Float64}}
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && return NTuple{3,Float64}[]

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fgy = _prefixed_sym(prefix, :fix_gavy)
    c_fdur = _prefixed_sym(prefix, :fix_dur)
    (
        hasproperty(samples, c_infix) &&
        hasproperty(samples, c_fgx) &&
        hasproperty(samples, c_fgy)
    ) || error("No fixation columns ($c_fgx). Run event detection first.")

    has_tw = !isnothing(time_window)
    has_trel = has_tw ? _has_active_time_rel(samples) : false
    trel_col = has_trel ? samples[!, :time_rel] : nothing
    time_col = samples[!, :time]
    in_fix_col = samples[!, c_infix]
    fgx_col = samples[!, c_fgx]
    fgy_col = samples[!, c_fgy]
    fdur_col = hasproperty(samples, c_fdur) ? samples[!, c_fdur] : nothing
    dt_ms = df.sample_rate > 0.0 ? 1000.0 / df.sample_rate : 1.0
    has_tr = hasproperty(samples, :trial)
    tr_col = has_tr ? samples[!, :trial] : nothing

    # Convert degree coordinates to pixel equivalents so screen-diagonal normalization is consistent
    fgx_deg = _is_col_deg(samples, c_fgx, df.coords)
    fgy_deg = _is_col_deg(samples, c_fgy, df.coords)
    ppd = (fgx_deg || fgy_deg) ? pixels_per_degree(df) : 1.0

    out = NTuple{3,Float64}[]
    t_buf = Float64[]
    _foreach_trial_segment(samples) do lo, hi
        (has_tr && ismissing(tr_col[lo])) && return nothing
        has_tw && _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, lo:hi)
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(samples, lo, time_window) : (-Inf, Inf)

        r = lo
        @inbounds while r <= hi
            if in_fix_col[r]
                r_end = r + 1
                while r_end <= hi && in_fix_col[r_end]
                    r_end += 1
                end
                dur = if !isnothing(fdur_col) && Float64(fdur_col[r]) > 0.0
                    Float64(fdur_col[r])
                else
                    max(dt_ms, Float64(time_col[r_end-1]) - Float64(time_col[r]) + dt_ms)
                end
                in_win = true
                if has_tw
                    ti = t_buf[r-lo+1]
                    in_win = !isnan(ti) && (ti + dur > t_start) && (ti < t_end)
                end
                if in_win
                    fx = Float64(fgx_col[r]) * (fgx_deg ? ppd : 1.0)
                    fy = Float64(fgy_col[r]) * (fgy_deg ? ppd : 1.0)
                    if !isnan(fx) && !isnan(fy)
                        push!(out, (fx, fy, max(dur, 1.0)))
                    end
                end
                r = r_end
            else
                r += 1
            end
        end
        return nothing
    end
    return out
end

function _simplify_multimatch_fixations(
    fixs::Vector{NTuple{3,Float64}},
    amp_thresh_px::Float64,
    dir_thresh_rad::Float64,
    dur_thresh_ms::Float64,
)::Vector{NTuple{3,Float64}}
    length(fixs) <= 2 && return copy(fixs)

    # Coalesce sub-threshold saccade amplitudes
    cur = copy(fixs)
    if amp_thresh_px > 0.0
        merged = NTuple{3,Float64}[]
        i = 1
        while i <= length(cur)
            fx, fy, fd = cur[i]
            while i < length(cur) && (length(merged) + (length(cur) - i)) >= 2
                nx, ny, nd = cur[i+1]
                amp = hypot(nx - fx, ny - fy)
                dur_ok = dur_thresh_ms <= 0.0 || fd < dur_thresh_ms || nd < dur_thresh_ms
                if amp < amp_thresh_px && dur_ok
                    w = fd + nd
                    fx = (fx * fd + nx * nd) / w
                    fy = (fy * fd + ny * nd) / w
                    fd = w
                    i += 1
                else
                    break
                end
            end
            push!(merged, (fx, fy, fd))
            i += 1
        end
        cur = merged
    end

    # Coalesce nearly collinear consecutive saccades
    if dir_thresh_rad > 0.0 && length(cur) >= 3
        merged_dir = NTuple{3,Float64}[cur[1]]
        i = 2
        while i < length(cur)
            px, py, _ = merged_dir[end]
            cx, cy, cd = cur[i]
            nx, ny, _ = cur[i+1]
            v1x, v1y = cx - px, cy - py
            v2x, v2y = nx - cx, ny - cy
            n1 = hypot(v1x, v1y)
            n2 = hypot(v2x, v2y)
            dur_ok = dur_thresh_ms <= 0.0 || cd < dur_thresh_ms
            if n1 > 1e-9 && n2 > 1e-9 && dur_ok && (length(merged_dir) + (length(cur) - i)) >= 2
                cos_ang = clamp((v1x * v2x + v1y * v2y) / (n1 * n2), -1.0, 1.0)
                if acos(cos_ang) < dir_thresh_rad
                    # Absorb intermediate fixation duration into predecessor
                    mp_x, mp_y, mp_d = merged_dir[end]
                    merged_dir[end] = (mp_x, mp_y, mp_d + cd)
                    i += 1
                    continue
                end
            end
            push!(merged_dir, cur[i])
            i += 1
        end
        push!(merged_dir, cur[end])
        cur = merged_dir
    end

    return cur
end

function scanpath_similarity(
    df::EyeData;
    selection1,
    selection2,
    eye::Symbol = :auto,
    method::Symbol = :multimatch,
    time_window::Union{Nothing,Tuple} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
    simplify::Bool = true,
    amp_threshold_deg::Real = 2.0,
    dir_threshold_deg::Real = 45.0,
    dur_threshold_ms::Real = 0.0,
)
    method == :multimatch || error(
        "Invalid method=:$method without AOIs. Pass an AOI vector for :levenshtein or use method=:multimatch.",
    )
    _resolve_eye(df, eye)

    f1 = _extract_multimatch_fixations(df, selection1, time_window, prefix)
    f2 = _extract_multimatch_fixations(df, selection2, time_window, prefix)

    if isempty(f1) && isempty(f2)
        return (vector = 1.0, direction = 1.0, length = 1.0, position = 1.0, duration = 1.0, similarity = 1.0)
    elseif isempty(f1) || isempty(f2)
        return (vector = 0.0, direction = 0.0, length = 0.0, position = 0.0, duration = 0.0, similarity = 0.0)
    end

    ppd = pixels_per_degree(df)
    if simplify
        amp_px = Float64(amp_threshold_deg) * ppd
        dir_rad = deg2rad(Float64(dir_threshold_deg))
        dur_ms = Float64(dur_threshold_ms)
        f1 = _simplify_multimatch_fixations(f1, amp_px, dir_rad, dur_ms)
        f2 = _simplify_multimatch_fixations(f2, amp_px, dir_rad, dur_ms)
    end

    diag_px = max(hypot(Float64(df.screen_res[1]), Float64(df.screen_res[2])), 1.0)
    m = length(f1)
    n = length(f2)

    if m == 1 || n == 1
        # Single-fixation fallback: align fixation 1 against all fixations of the other path
        pos_diffs = Float64[]
        dur_diffs = Float64[]
        for a in f1, b in f2
            push!(pos_diffs, min(1.0, hypot(a[1] - b[1], a[2] - b[2]) / diag_px))
            push!(dur_diffs, abs(a[3] - b[3]) / max(a[3], b[3], 1.0))
        end
        pos_sim = clamp(1.0 - median!(pos_diffs), 0.0, 1.0)
        dur_sim = clamp(1.0 - median!(dur_diffs), 0.0, 1.0)
        vec_sim = (m == 1 && n == 1) ? pos_sim : 0.0
        dir_sim = (m == 1 && n == 1) ? 1.0 : 0.0
        len_sim = (m == 1 && n == 1) ? 1.0 : 0.0
        sim_all = (vec_sim + dir_sim + len_sim + pos_sim + dur_sim) / 5.0
        return (
            vector = round(vec_sim; digits = 4),
            direction = round(dir_sim; digits = 4),
            length = round(len_sim; digits = 4),
            position = round(pos_sim; digits = 4),
            duration = round(dur_sim; digits = 4),
            similarity = round(sim_all; digits = 4),
        )
    end

    ns1 = m - 1
    ns2 = n - 1
    u1x = Vector{Float64}(undef, ns1)
    u1y = Vector{Float64}(undef, ns1)
    @inbounds for i = 1:ns1
        u1x[i] = f1[i+1][1] - f1[i][1]
        u1y[i] = f1[i+1][2] - f1[i][2]
    end
    u2x = Vector{Float64}(undef, ns2)
    u2y = Vector{Float64}(undef, ns2)
    @inbounds for j = 1:ns2
        u2x[j] = f2[j+1][1] - f2[j][1]
        u2y[j] = f2[j+1][2] - f2[j][2]
    end

    # Dynamic programming alignment over saccade vector Euclidean difference (DTW path)
    cost = Matrix{Float64}(undef, ns1, ns2)
    dp = Matrix{Float64}(undef, ns1, ns2)
    step = Matrix{UInt8}(undef, ns1, ns2) # 1 = diag, 2 = up (i-1), 3 = left (j-1)

    @inbounds for j = 1:ns2
        ux2, uy2 = u2x[j], u2y[j]
        for i = 1:ns1
            c = hypot(u1x[i] - ux2, u1y[i] - uy2)
            cost[i, j] = c
            if i == 1 && j == 1
                dp[1, 1] = c
                step[1, 1] = 0x00
            elseif i == 1
                dp[1, j] = dp[1, j-1] + c
                step[1, j] = 0x03
            elseif j == 1
                dp[i, 1] = dp[i-1, 1] + c
                step[i, 1] = 0x02
            else
                d_diag = dp[i-1, j-1]
                d_up = dp[i-1, j]
                d_left = dp[i, j-1]
                if d_diag <= d_up && d_diag <= d_left
                    dp[i, j] = d_diag + c
                    step[i, j] = 0x01
                elseif d_up <= d_left
                    dp[i, j] = d_up + c
                    step[i, j] = 0x02
                else
                    dp[i, j] = d_left + c
                    step[i, j] = 0x03
                end
            end
        end
    end

    path_i = Int[]
    path_j = Int[]
    ci, cj = ns1, ns2
    @inbounds while true
        push!(path_i, ci)
        push!(path_j, cj)
        st = step[ci, cj]
        st == 0x00 && break
        if st == 0x01
            ci -= 1
            cj -= 1
        elseif st == 0x02
            ci -= 1
        else
            cj -= 1
        end
    end
    reverse!(path_i)
    reverse!(path_j)

    n_al = length(path_i)
    vec_diffs = Vector{Float64}(undef, n_al)
    len_diffs = Vector{Float64}(undef, n_al)
    dir_diffs = Float64[]
    sizehint!(dir_diffs, n_al)

    inv_2diag = 1.0 / (2.0 * diag_px)
    inv_diag = 1.0 / diag_px
    inv_pi = 1.0 / π

    @inbounds for k = 1:n_al
        ia = path_i[k]
        jb = path_j[k]
        ax, ay = u1x[ia], u1y[ia]
        bx, by = u2x[jb], u2y[jb]
        la = hypot(ax, ay)
        lb = hypot(bx, by)
        vec_diffs[k] = clamp(cost[ia, jb] * inv_2diag, 0.0, 1.0)
        len_diffs[k] = clamp(abs(la - lb) * inv_diag, 0.0, 1.0)
        if la > 1e-9 && lb > 1e-9
            cos_th = clamp((ax * bx + ay * by) / (la * lb), -1.0, 1.0)
            push!(dir_diffs, acos(cos_th) * inv_pi)
        elseif la <= 1e-9 && lb <= 1e-9
            push!(dir_diffs, 0.0)
        end
    end

    # Aligned fixation pairs: initial fixation (1, 1) + destination fixations (ia + 1, jb + 1)
    pos_diffs = Vector{Float64}(undef, n_al + 1)
    dur_diffs = Vector{Float64}(undef, n_al + 1)
    pos_diffs[1] = clamp(hypot(f1[1][1] - f2[1][1], f1[1][2] - f2[1][2]) * inv_diag, 0.0, 1.0)
    dur_diffs[1] = abs(f1[1][3] - f2[1][3]) / max(f1[1][3], f2[1][3], 1.0)
    @inbounds for k = 1:n_al
        fa = f1[path_i[k]+1]
        fb = f2[path_j[k]+1]
        pos_diffs[k+1] = clamp(hypot(fa[1] - fb[1], fa[2] - fb[2]) * inv_diag, 0.0, 1.0)
        dur_diffs[k+1] = abs(fa[3] - fb[3]) / max(fa[3], fb[3], 1.0)
    end

    vec_sim = clamp(1.0 - median!(vec_diffs), 0.0, 1.0)
    dir_sim = isempty(dir_diffs) ? 1.0 : clamp(1.0 - median!(dir_diffs), 0.0, 1.0)
    len_sim = clamp(1.0 - median!(len_diffs), 0.0, 1.0)
    pos_sim = clamp(1.0 - median!(pos_diffs), 0.0, 1.0)
    dur_sim = clamp(1.0 - median!(dur_diffs), 0.0, 1.0)
    sim_mean = (vec_sim + dir_sim + len_sim + pos_sim + dur_sim) / 5.0

    return (
        vector = round(vec_sim; digits = 4),
        direction = round(dir_sim; digits = 4),
        length = round(len_sim; digits = 4),
        position = round(pos_sim; digits = 4),
        duration = round(dur_sim; digits = 4),
        similarity = round(sim_mean; digits = 4),
    )
end

function _format_aoi_sequence(idxs::Vector{Int}, aois::Vector{<:AOI})
    if length(aois) <= 26
        chars = Vector{Char}(undef, length(idxs))
        @inbounds for i in eachindex(idxs)
            chars[i] = Char(Int('A') + idxs[i] - 1)
        end
        return String(chars)
    end
    return String[aois[i].name for i in idxs]
end

function _accumulate_transitions_range!(
    counts::Matrix{Float64},
    in_fix::AbstractVector{Bool},
    fix_gx::AbstractVector{<:Real},
    fix_gy::AbstractVector{<:Real},
    fix_dur::Union{Nothing,AbstractVector{<:Real}},
    lo::Int,
    hi::Int,
    t_buf::Vector{Float64},
    needs_t::Bool,
    has_tw::Bool,
    t_start::Float64,
    t_end::Float64,
    aois::Vector{<:AOI},
)
    n_aois = length(aois)
    prev_fix = false
    prev_aoi = 0
    has_prev = false

    @inbounds for r = lo:hi
        cur_fix = in_fix[r]
        if cur_fix & !prev_fix
            k = r - lo + 1
            ti = needs_t ? t_buf[k] : 0.0
            dur = isnothing(fix_dur) ? 0.0 : max(0.0, Float64(fix_dur[r]))
            f_end = ti + dur
            in_win = if !has_tw
                true
            elseif isnan(ti)
                false
            elseif dur > 0.0
                f_end > t_start && ti < t_end
            else
                t_start <= ti <= t_end
            end
            if in_win
                fx = Float64(fix_gx[r])
                fy = Float64(fix_gy[r])
                if !isnan(fx) && !isnan(fy)
                    t0 = has_tw ? max(ti, t_start) : ti
                    t1 = has_tw ? min(f_end, t_end) : f_end
                    aoi_idx = 0
                    for ai = 1:n_aois
                        if _in_aoi_interval_fast(aois[ai], fx, fy, t0, t1)
                            aoi_idx = ai
                            break
                        end
                    end
                    if has_prev && prev_aoi > 0 && aoi_idx > 0
                        counts[prev_aoi, aoi_idx] += 1.0
                    end
                    prev_aoi = aoi_idx
                    has_prev = true
                end
            end
        end
        prev_fix = cur_fix
    end
    return counts
end

"""
    transition_matrix(df::EyeData, aois::Vector{<:AOI};
                      selection=nothing, normalize=true, time_window=nothing, prefix=nothing)

Compute an AOI-to-AOI transition matrix from fixation sequences (evaluated within
each `(participant, trial)` segment so cross-trial and cross-participant jumps are not counted).

Returns a `NamedTuple` with:
- `matrix`: `n×n` matrix of transition probabilities (or raw counts if `normalize=false`)
- `labels`: AOI name labels in row/column order
- `counts`: raw unnormalized transition counts matrix
"""
function transition_matrix(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    normalize::Bool = true,
    time_window::Union{Nothing,Tuple} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fgy = _prefixed_sym(prefix, :fix_gavy)
    c_fdur = _prefixed_sym(prefix, :fix_dur)
    (
        hasproperty(samples, c_infix) &&
        hasproperty(samples, c_fgx) &&
        hasproperty(samples, c_fgy)
    ) || error("No fixation columns ($c_fgx). Run event detection first.")

    n_aois = length(aois)
    labels = String[a.name for a in aois]
    raw_counts = zeros(Float64, n_aois, n_aois)

    has_tw = !isnothing(time_window)
    needs_t = has_tw || any(a -> a isa DynamicAOI, aois)
    has_trel = needs_t ? _has_active_time_rel(samples) : false
    trel_col = has_trel ? samples[!, :time_rel] : nothing
    time_col = samples[!, :time]
    in_fix_col = samples[!, c_infix]
    fgx_col = samples[!, c_fgx]
    fgy_col = samples[!, c_fgy]
    fdur_col = hasproperty(samples, c_fdur) ? samples[!, c_fdur] : nothing
    has_tr = hasproperty(samples, :trial)
    tr_col = has_tr ? samples[!, :trial] : nothing
    t_buf = Float64[]

    _foreach_trial_segment(samples) do lo, hi
        (has_tr && ismissing(tr_col[lo])) && return nothing
        if needs_t
            _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, lo:hi)
        end
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(samples, lo, time_window) : (-Inf, Inf)
        _accumulate_transitions_range!(
            raw_counts,
            in_fix_col,
            fgx_col,
            fgy_col,
            fdur_col,
            lo,
            hi,
            t_buf,
            needs_t,
            has_tw,
            t_start,
            t_end,
            aois,
        )
        return nothing
    end

    mat = copy(raw_counts)
    if normalize
        @inbounds for r = 1:n_aois
            row_sum = 0.0
            for c = 1:n_aois
                row_sum += mat[r, c]
            end
            if row_sum > 0.0
                inv_s = 1.0 / row_sum
                for c = 1:n_aois
                    mat[r, c] *= inv_s
                end
            end
        end
    end

    return (matrix = mat, labels = labels, counts = raw_counts)
end

"""
    transition_entropy(tm::NamedTuple; normalize::Bool = false) -> Float64
    transition_entropy(mat::AbstractMatrix{<:Real}; normalize::Bool = false) -> Float64

Compute the joint Shannon entropy (in bits, or normalized to `[0, 1]` when
`normalize = true`) of AOI transitions.
When passed the `NamedTuple` returned by `transition_matrix`, uses the underlying
transition counts (`tm.counts`) so rare and frequent AOIs are weighted accurately
regardless of whether `transition_matrix` was called with `normalize=true` or `normalize=false`.
"""
function transition_entropy(mat::AbstractMatrix{<:Real}; normalize::Bool = false)
    total_transitions = Float64(sum(mat))
    total_transitions <= 0.0 && return 0.0

    inv_total = 1.0 / total_transitions
    H = 0.0
    @inbounds for v in mat
        fv = Float64(v)
        if fv > 0.0
            p = fv * inv_total
            H -= p * log2(p)
        end
    end
    if normalize
        n_cells = length(mat)
        return n_cells > 1 ? H / log2(Float64(n_cells)) : 0.0
    end
    return H
end

function transition_entropy(tm::NamedTuple; normalize::Bool = false)
    return haskey(tm, :counts) ?
           transition_entropy(tm.counts; normalize = normalize) :
           transition_entropy(tm.matrix; normalize = normalize)
end

function _append_aoi_seq_range!(
    seq::Vector{Int},
    in_fix::AbstractVector{Bool},
    fix_gx::AbstractVector{<:Real},
    fix_gy::AbstractVector{<:Real},
    fix_dur::Union{Nothing,AbstractVector{<:Real}},
    lo::Int,
    hi::Int,
    t_buf::Vector{Float64},
    needs_t::Bool,
    has_tw::Bool,
    t_start::Float64,
    t_end::Float64,
    aois::Vector{<:AOI},
)
    n_aois = length(aois)
    prev_fix = false

    @inbounds for r = lo:hi
        cur_fix = in_fix[r]
        if cur_fix & !prev_fix
            k = r - lo + 1
            ti = needs_t ? t_buf[k] : 0.0
            dur = isnothing(fix_dur) ? 0.0 : max(0.0, Float64(fix_dur[r]))
            f_end = ti + dur
            in_win = if !has_tw
                true
            elseif isnan(ti)
                false
            elseif dur > 0.0
                f_end > t_start && ti < t_end
            else
                t_start <= ti <= t_end
            end
            if in_win
                fx = Float64(fix_gx[r])
                fy = Float64(fix_gy[r])
                if !isnan(fx) && !isnan(fy)
                    t0 = has_tw ? max(ti, t_start) : ti
                    t1 = has_tw ? min(f_end, t_end) : f_end
                    for ai = 1:n_aois
                        if _in_aoi_interval_fast(aois[ai], fx, fy, t0, t1)
                            push!(seq, ai)
                            break
                        end
                    end
                end
            end
        end
        prev_fix = cur_fix
    end
    return seq
end

"""Extract AOI fixation sequence as integer AOI indices `1..length(aois)`."""
function _aoi_index_sequence(
    df::EyeData,
    aois::Vector{<:AOI},
    selection,
    time_window,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && return Int[]

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fgy = _prefixed_sym(prefix, :fix_gavy)
    c_fdur = _prefixed_sym(prefix, :fix_dur)
    (
        hasproperty(samples, c_infix) &&
        hasproperty(samples, c_fgx) &&
        hasproperty(samples, c_fgy)
    ) || error("No fixation columns ($c_fgx). Run event detection first.")

    has_tw = !isnothing(time_window)
    needs_t = has_tw || any(a -> a isa DynamicAOI, aois)
    has_trel = needs_t ? _has_active_time_rel(samples) : false
    trel_col = has_trel ? samples[!, :time_rel] : nothing
    time_col = samples[!, :time]
    in_fix_col = samples[!, c_infix]
    fgx_col = samples[!, c_fgx]
    fgy_col = samples[!, c_fgy]
    fdur_col = hasproperty(samples, c_fdur) ? samples[!, c_fdur] : nothing
    has_tr = hasproperty(samples, :trial)
    tr_col = has_tr ? samples[!, :trial] : nothing

    seq = Int[]
    t_buf = Float64[]
    _foreach_trial_segment(samples) do lo, hi
        (has_tr && ismissing(tr_col[lo])) && return nothing
        if needs_t
            _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, lo:hi)
        end
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(samples, lo, time_window) : (-Inf, Inf)
        _append_aoi_seq_range!(
            seq,
            in_fix_col,
            fgx_col,
            fgy_col,
            fdur_col,
            lo,
            hi,
            t_buf,
            needs_t,
            has_tw,
            t_start,
            t_end,
            aois,
        )
        return nothing
    end

    return seq
end

"""Levenshtein edit distance between two integer or string sequences."""
function _levenshtein(s::AbstractVector{Int}, t::AbstractVector{Int})
    m, n = length(s), length(t)
    m == 0 && return n
    n == 0 && return m

    prev = collect(0:n)
    curr = similar(prev)

    @inbounds for i = 1:m
        curr[1] = i
        si = s[i]
        for j = 1:n
            cost = si == t[j] ? 0 : 1
            curr[j+1] = min(
                prev[j+1] + 1,      # deletion
                curr[j] + 1,        # insertion
                prev[j] + cost,     # substitution
            )
        end
        prev, curr = curr, prev
    end
    return prev[n+1]
end

function _levenshtein(s::AbstractString, t::AbstractString)
    s_bytes = codeunits(s)
    t_bytes = codeunits(t)
    m, n = length(s_bytes), length(t_bytes)
    m == 0 && return n
    n == 0 && return m

    prev = collect(0:n)
    curr = similar(prev)

    @inbounds for i = 1:m
        curr[1] = i
        si = s_bytes[i]
        for j = 1:n
            cost = si == t_bytes[j] ? 0 : 1
            curr[j+1] = min(
                prev[j+1] + 1,      # deletion
                curr[j] + 1,        # insertion
                prev[j] + cost,     # substitution
            )
        end
        prev, curr = curr, prev
    end

    return prev[n+1]
end
