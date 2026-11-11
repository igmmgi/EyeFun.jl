function _count_valid_numeric(col::AbstractVector)
    c = 0
    @inbounds for i in eachindex(col)
        v = col[i]
        if !ismissing(v) && !isnan(v)
            c += 1
        end
    end
    return c
end

function _count_valid_gaze_pair(col_x::AbstractVector, col_y::AbstractVector)
    c = 0
    @inbounds for i in eachindex(col_x, col_y)
        vx = col_x[i]
        vy = col_y[i]
        if !ismissing(vx) && !ismissing(vy) && !isnan(vx) && !isnan(vy)
            c += 1
        end
    end
    return c
end

"""
    _resolve_eye(df, eye; cols=:gaze) -> Symbol

Resolve `:auto` eye selection to `:left` or `:right` (or pass through `:both`).
`cols` determines which columns to check: `:gaze` checks `gxL/gyL` and `gxR/gyR`,
`:pupil` checks `paL/paR`.
When both eyes contain valid data, `:auto` prefers the eye with more valid
samples (tie-breaking to `:left`).
"""
function _resolve_eye(dat, eye::Symbol; cols::Symbol = :gaze)

    if eye ∉ (:left, :L, :l, :right, :R, :r, :both, :B, :b, :auto)
        error("Invalid eye=:$eye. Use :left, :right, :both, :L, :R, :B, or :auto.")
    end
    if cols ∉ (:gaze, :pupil)
        error("Invalid cols=:$cols. Use :gaze or :pupil.")
    end

    df = dat isa EyeData ? dat.df : dat
    eye in (:left, :L, :l) && return :left
    eye in (:right, :R, :r) && return :right
    eye in (:both, :B, :b) && return :both

    # Select the eye with more valid samples
    if cols == :pupil
        nL = hasproperty(df, :paL) ? _count_valid_numeric(df[!, :paL]) : 0
        nR = hasproperty(df, :paR) ? _count_valid_numeric(df[!, :paR]) : 0
    else
        nL = if hasproperty(df, :gxL) && hasproperty(df, :gyL)
            _count_valid_gaze_pair(df[!, :gxL], df[!, :gyL])
        elseif hasproperty(df, :gxL)
            _count_valid_numeric(df[!, :gxL])
        else
            0
        end
        nR = if hasproperty(df, :gxR) && hasproperty(df, :gyR)
            _count_valid_gaze_pair(df[!, :gxR], df[!, :gyR])
        elseif hasproperty(df, :gxR)
            _count_valid_numeric(df[!, :gxR])
        else
            0
        end
    end

    if nL == 0 && nR == 0
        has_both = cols == :pupil ? hasproperty(df, :pa) : (hasproperty(df, :gx) && hasproperty(df, :gy))
        has_both && return :both
        return :left
    end
    return nL >= nR ? :left : :right
end

"""
    _eye_columns(eye::Symbol) -> NamedTuple{(:gx, :gy, :pa), NTuple{3, Symbol}}

Return the column names for gaze X, gaze Y, and pupil area for the given eye.
"""
_eye_columns(eye::Symbol) =
    eye == :left ? (gx = :gxL, gy = :gyL, pa = :paL) :
    eye == :right ? (gx = :gxR, gy = :gyR, pa = :paR) :
    eye == :both ? (gx = :gx, gy = :gy, pa = :pa) :
    error("Invalid resolved eye=:$eye.")

function _cyclopean_pair!(
    out::Vector{T},
    colL::AbstractVector,
    colR::AbstractVector,
) where {T<:AbstractFloat}
    NaNT = T(NaN)
    half = T(0.5)
    @inbounds for i in eachindex(out, colL, colR)
        vL = colL[i]
        vR = colR[i]
        okL = !ismissing(vL) && !isnan(vL)
        okR = !ismissing(vR) && !isnan(vR)
        if okL && okR
            out[i] = (T(vL) + T(vR)) * half
        elseif okL
            out[i] = T(vL)
        elseif okR
            out[i] = T(vR)
        else
            out[i] = NaNT
        end
    end
    return out
end

@inline _as_float_vec(v::AbstractVector{<:AbstractFloat}) = v
@inline _as_float_vec(v::AbstractVector) = Float64[ismissing(x) ? NaN : Float64(x) for x in v]

function _ensure_float_col!(df::DataFrame, col::Symbol)
    hasproperty(df, col) || return nothing
    v = df[!, col]
    eltype(v) <: AbstractFloat && return v
    cm = DataFrames.colmetadata(df, col, "eyefun_coords", nothing)
    fv = _as_float_vec(v)
    df[!, col] = fv
    !isnothing(cm) && DataFrames.colmetadata!(df, col, "eyefun_coords", cm; style = :note)
    return fv
end

@inline function _group_seam_cols(df::AbstractDataFrame)
    tr_col = hasproperty(df, :trial) ? df[!, :trial] : nothing
    pt_col = hasproperty(df, :participant) ? df[!, :participant] : nothing
    return tr_col, pt_col
end

@inline function _is_group_row_contig(
    r_prev::Int,
    r_cur::Int,
    tr_col::Union{Nothing,AbstractVector},
    pt_col::Union{Nothing,AbstractVector},
)::Bool
    r_cur == r_prev + 1 || return false
    if !isnothing(tr_col)
        tp = @inbounds tr_col[r_prev]
        tc = @inbounds tr_col[r_cur]
        (tc === tp || isequal(tc, tp)) || return false
    end
    if !isnothing(pt_col)
        pp = @inbounds pt_col[r_prev]
        pc = @inbounds pt_col[r_cur]
        (pc === pp || isequal(pc, pp)) || return false
    end
    return true
end

function _check_and_merge_eye_coords(
    d::AbstractDataFrame,
    cL::Symbol,
    cR::Symbol,
    fb::Symbol,
)::Symbol
    hasL = hasproperty(d, cL)
    hasR = hasproperty(d, cR)
    if hasL && hasR
        mL = DataFrames.colmetadata(d, cL, "eyefun_coords", fb)
        mR = DataFrames.colmetadata(d, cR, "eyefun_coords", fb)
        mL === mR || throw(
            ArgumentError(
                "Cannot average :$cL ($mL) and :$cR ($mR) with mismatched coordinate systems; convert both eyes first.",
            ),
        )
        return mL
    elseif hasL
        return DataFrames.colmetadata(d, cL, "eyefun_coords", fb)
    elseif hasR
        return DataFrames.colmetadata(d, cR, "eyefun_coords", fb)
    end
    return fb
end

function _cyclopean_col(df::AbstractDataFrame, cL::Symbol, cR::Symbol)
    n = nrow(df)
    hasL = hasproperty(df, cL)
    hasR = hasproperty(df, cR)
    if hasL && hasR
        vL = df[!, cL]
        vR = df[!, cR]
        T = (eltype(vL) === Float32 && eltype(vR) === Float32) ? Float32 : Float64
        return _cyclopean_pair!(Vector{T}(undef, n), vL, vR)
    elseif hasL
        vL = df[!, cL]
        return eltype(vL) <: AbstractFloat ? copy(vL) : _as_float_vec(vL)
    elseif hasR
        vR = df[!, cR]
        return eltype(vR) <: AbstractFloat ? copy(vR) : _as_float_vec(vR)
    else
        return fill(NaN, n)
    end
end

"""
    average_eyes!(ed::EyeData) -> EyeData

Compute cyclopean binocular gaze (`:gx`, `:gy`) and pupil (`:pa`) columns in `ed.df`
by averaging `:gxL`/`:gxR`, `:gyL`/`:gyR`, and `:paL`/`:paR` at each sample, falling
back to the available valid eye when the other eye is `NaN` (or `NaN` when both are missing).

Return `ed`.
"""
function average_eyes!(ed::EyeData)
    d = ed.df
    fb = ed.coords
    if hasproperty(d, :gxL) || hasproperty(d, :gxR)
        mx = _check_and_merge_eye_coords(d, :gxL, :gxR, fb)
        d[!, :gx] = _cyclopean_col(d, :gxL, :gxR)
        mx !== fb && DataFrames.colmetadata!(d, :gx, "eyefun_coords", mx; style = :note)
    end
    if hasproperty(d, :gyL) || hasproperty(d, :gyR)
        my = _check_and_merge_eye_coords(d, :gyL, :gyR, fb)
        d[!, :gy] = _cyclopean_col(d, :gyL, :gyR)
        my !== fb && DataFrames.colmetadata!(d, :gy, "eyefun_coords", my; style = :note)
    end
    if hasproperty(d, :paL) || hasproperty(d, :paR)
        d[!, :pa] = _cyclopean_col(d, :paL, :paR)
    end
    return ed
end

function _ensure_eye_cols!(ed::EyeData, eye::Symbol; cols::Symbol = :gaze)
    if eye == :both
        need =
            cols == :pupil ? !hasproperty(ed.df, :pa) :
            (!hasproperty(ed.df, :gx) || !hasproperty(ed.df, :gy))
        need && average_eyes!(ed)
    end
    return nothing
end

@inline function _get_gaze_vecs(
    samples::AbstractDataFrame,
    eye::Symbol;
    fallback_coords::Symbol = :px,
)
    if eye == :both
        if hasproperty(samples, :gx) && hasproperty(samples, :gy)
            return _as_float_vec(samples[!, :gx]), _as_float_vec(samples[!, :gy])
        end
        _check_and_merge_eye_coords(samples, :gxL, :gxR, fallback_coords)
        _check_and_merge_eye_coords(samples, :gyL, :gyR, fallback_coords)
        return _cyclopean_col(samples, :gxL, :gxR), _cyclopean_col(samples, :gyL, :gyR)
    end
    ecols = _eye_columns(eye)
    return _as_float_vec(samples[!, ecols.gx]), _as_float_vec(samples[!, ecols.gy])
end

@inline function _get_pupil_vec(samples::AbstractDataFrame, eye::Symbol)
    if eye == :both
        hasproperty(samples, :pa) && return _as_float_vec(samples[!, :pa])
        return _cyclopean_col(samples, :paL, :paR)
    end
    return _as_float_vec(samples[!, _eye_columns(eye).pa])
end

function _mark_equal!(mask::BitVector, col::AbstractVector, val)
    @inbounds for i in eachindex(mask, col)
        if mask[i]
            v = col[i]
            mask[i] = !ismissing(v) && (v == val)
        end
    end
    return mask
end

function _mark_in_range!(mask::BitVector, col::AbstractVector, rng::AbstractRange)
    @inbounds for i in eachindex(mask, col)
        if mask[i]
            v = col[i]
            mask[i] = !ismissing(v) && (v in rng)
        end
    end
    return mask
end

function _mark_in_set!(mask::BitVector, col::AbstractVector, vals::AbstractVector)
    val_set = Set(vals)
    @inbounds for i in eachindex(mask, col)
        if mask[i]
            v = col[i]
            mask[i] = !ismissing(v) && (v in val_set)
        end
    end
    return mask
end

function _selection_mask(d::AbstractDataFrame, selection)
    if selection isa Int
        hasproperty(d, :trial) || error("No :trial column in data")
        mask = trues(nrow(d))
        return _mark_equal!(mask, d[!, :trial], selection)
    elseif selection isa NamedTuple
        mask = trues(nrow(d))
        for (col, val) in pairs(selection)
            hasproperty(d, col) ||
                error("Column :$col not found in data. Available: $(names(d))")
            cvec = d[!, col]
            if val isa AbstractRange
                _mark_in_range!(mask, cvec, val)
            elseif val isa AbstractVector
                _mark_in_set!(mask, cvec, val)
            else
                _mark_equal!(mask, cvec, val)
            end
        end
        return mask
    else
        error(
            "Unsupported selection type: $(typeof(selection)). Use a NamedTuple, e.g. (trial=1, stimulus=\"Face\").",
        )
    end
end

"""
Filter a DataFrame by a NamedTuple of column=value pairs.
All conditions must match (AND logic). Also supports plain `Int` for trial number.

# Examples
    _apply_selection(df, nothing)                        # no filter
    _apply_selection(df, 5)                              # trial == 5
    _apply_selection(df, (trial=1,))                     # trial == 1
    _apply_selection(df, (trial=1, stimulus="Face"))     # trial 1 AND stimulus == "Face"
    _apply_selection(df, (stimulus="Face",))             # all trials with stimulus == "Face"
"""
function _apply_selection(df::EyeData, selection)
    isnothing(selection) && return df.df
    mask = _selection_mask(df.df, selection)
    return df.df[mask, :]
end

function _apply_selection_view(df::EyeData, selection)
    isnothing(selection) && return df.df
    mask = _selection_mask(df.df, selection)
    return @view df.df[mask, :]
end

function _trial_group_cols(df::AbstractDataFrame)::Vector{Symbol}
    has_tr = hasproperty(df, :trial)
    if _has_multiple_participants(df)
        return has_tr ? Symbol[:participant, :trial] : Symbol[:participant]
    end
    has_tr || error("Grouping columns [:trial] not found in DataFrame.")
    return Symbol[:trial]
end

"""
    _resolve_group_cols(df, group_by) -> Vector{Symbol}

Normalize `group_by` kwarg to a Vector{Symbol} and validate that all columns exist.
Accepts `:auto` (resolving to `[:participant, :trial]` when multiple participants exist
or `[:trial]` for single-participant data), `:trial`, `[:block, :trial]`, or any
`Symbol`/`Vector{Symbol}`.
"""
function _resolve_group_cols(dat, group_by)
    df = dat isa EyeData ? dat.df : dat
    group_by === :auto && return _trial_group_cols(df)
    cols = group_by isa Symbol ? Symbol[group_by] : collect(Symbol, group_by)
    issubset(cols, propertynames(df)) ||
        error("Grouping columns $cols not found in DataFrame.")
    return cols
end

"""
    _valid_groups(df_or_samples, group_by) -> (grouped, group_cols)

Resolve group columns, skip rows with missing group values, and return a
`GroupedDataFrame` along with the resolved column list.
"""
function _valid_groups(df_or_samples, group_by)
    d = df_or_samples isa EyeData ? df_or_samples.df : df_or_samples
    group_cols = _resolve_group_cols(d, group_by)
    return groupby(d, group_cols; skipmissing = true), group_cols
end

function _try_contiguous_groups_1col(col::AbstractVector)
    S = nonmissingtype(eltype(col))
    seen = Set{S}()
    ranges = UnitRange{Int}[]
    n = length(col)
    i = 1
    @inbounds while i <= n
        vi = col[i]
        if ismissing(vi)
            i += 1
            continue
        end
        key = vi::S
        key in seen && return nothing
        push!(seen, key)
        j = i + 1
        while j <= n
            vj = col[j]
            (!ismissing(vj) && isequal(vj, key)) || break
            j += 1
        end
        push!(ranges, i:(j-1))
        i = j
    end
    return ranges
end

function _try_contiguous_groups_2col(col1::AbstractVector, col2::AbstractVector)
    S1 = nonmissingtype(eltype(col1))
    S2 = nonmissingtype(eltype(col2))
    seen = Set{Tuple{S1,S2}}()
    ranges = UnitRange{Int}[]
    n = length(col1)
    i = 1
    @inbounds while i <= n
        v1 = col1[i]
        v2 = col2[i]
        if ismissing(v1) || ismissing(v2)
            i += 1
            continue
        end
        k1 = v1::S1
        k2 = v2::S2
        key = (k1, k2)
        key in seen && return nothing
        push!(seen, key)
        j = i + 1
        while j <= n
            u1 = col1[j]
            u2 = col2[j]
            (!ismissing(u1) && !ismissing(u2) && isequal(u1, k1) && isequal(u2, k2)) || break
            j += 1
        end
        push!(ranges, i:(j-1))
        i = j
    end
    return ranges
end

function _try_contiguous_groups(samples::AbstractDataFrame, group_cols::Vector{Symbol})
    samples isa DataFrame || return nothing
    if length(group_cols) == 1
        return _try_contiguous_groups_1col(samples[!, group_cols[1]])
    elseif length(group_cols) == 2
        return _try_contiguous_groups_2col(samples[!, group_cols[1]], samples[!, group_cols[2]])
    end
    return nothing
end

function _foreach_trial_segment_cols(
    f::F,
    n::Int,
    tr_col::Union{Nothing,AbstractVector},
    pt_col::Union{Nothing,AbstractVector},
) where {F}
    i = 1
    @inbounds while i <= n
        j = i + 1
        if !isnothing(tr_col) && !isnothing(pt_col)
            tr_i = tr_col[i]
            pt_i = pt_col[i]
            while j <= n && isequal(tr_col[j], tr_i) && isequal(pt_col[j], pt_i)
                j += 1
            end
        elseif !isnothing(tr_col)
            tr_i = tr_col[i]
            while j <= n && isequal(tr_col[j], tr_i)
                j += 1
            end
        else
            pt_i = pt_col[i]
            while j <= n && isequal(pt_col[j], pt_i)
                j += 1
            end
        end
        f(i, j - 1)
        i = j
    end
    return nothing
end

"""
    _foreach_trial_segment(f, df::AbstractDataFrame)

Invoke `f(lo, hi)` on the row index bounds of each contiguous `(participant, trial)`
segment in `df`.
"""
function _foreach_trial_segment(f::F, df::AbstractDataFrame) where {F}
    n = nrow(df)
    n == 0 && return nothing
    has_tr = hasproperty(df, :trial)
    has_pt = hasproperty(df, :participant)
    if !has_tr && !has_pt
        f(1, n)
        return nothing
    end
    tr_col = has_tr ? df[!, :trial] : nothing
    pt_col = has_pt ? df[!, :participant] : nothing
    return _foreach_trial_segment_cols(f, n, tr_col, pt_col)
end

"""
    counts(v::AbstractVector{Bool}) -> Int

Count the number of onset transitions (false → true) in a Bool vector.
Useful for counting discrete events in sample-level annotation columns.

# Example
```julia
counts(ed.df.in_fix)     # number of fixations
counts(ed.df.in_sacc)    # number of saccades
counts(ed.df.in_blink)   # number of blinks
```
"""
function counts(v::AbstractVector{Bool})
    c = 0
    prev = false
    @inbounds for i in eachindex(v)
        cur = v[i]
        if cur & !prev
            c += 1
        end
        prev = cur
    end
    return c
end


function _data_quality_kernel(
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    pa::AbstractVector{<:Real},
    in_fix::Union{Nothing,AbstractVector{Bool}},
    in_sacc::Union{Nothing,AbstractVector{Bool}},
    in_blink::Union{Nothing,AbstractVector{Bool}},
    rows::AbstractVector{Int},
    sr::Float64,
    inv_ppd::Float64,
)
    n = length(rows)
    valid = 0
    pa_sum = 0.0
    pa_cnt = 0
    s2s_sq_sum = 0.0
    s2s_cnt = 0
    prev_ok = false
    prev_x = 0.0
    prev_y = 0.0
    blink_n = 0
    prev_bl = false
    prev_r = -1

    @inbounds for k = 1:n
        r = rows[k]
        contig = (r == prev_r + 1)
        prev_r = r

        xi = Float64(gx[r])
        yi = Float64(gy[r])
        xy_ok = !isnan(xi) && !isnan(yi)
        if xy_ok
            valid += 1
        end
        pv = pa[r]
        if !isnan(pv)
            pa_sum += Float64(pv)
            pa_cnt += 1
        end
        if !isnothing(in_blink)
            bl = in_blink[r]
            if bl && (!prev_bl || !contig)
                blink_n += 1
            end
            prev_bl = bl
        end
        ok_prec = if xy_ok
            if !isnothing(in_fix)
                in_fix[r]
            else
                (isnothing(in_sacc) || !in_sacc[r]) &&
                (isnothing(in_blink) || !in_blink[r])
            end
        else
            false
        end
        if ok_prec
            if prev_ok && contig
                dx = xi - prev_x
                dy = yi - prev_y
                s2s_sq_sum += dx * dx + dy * dy
                s2s_cnt += 1
            end
            prev_x = xi
            prev_y = yi
            prev_ok = true
        else
            prev_ok = false
        end
    end
    loss_pct = n > 0 ? (n - valid) / n * 100.0 : 0.0
    dur_ms = n / sr * 1000.0
    blink_rate = n > 0 ? blink_n * sr / n : 0.0
    mean_pa = pa_cnt > 0 ? pa_sum / pa_cnt : NaN
    rms_deg = (s2s_cnt > 0 && inv_ppd > 0.0) ? sqrt(s2s_sq_sum / s2s_cnt) * inv_ppd : NaN

    return (;
        total_samples = n,
        valid_samples = valid,
        tracking_loss_pct = round(loss_pct; digits = 1),
        blink_count = blink_n,
        blink_rate = round(blink_rate; digits = 2),
        mean_pupil = round(mean_pa; digits = 4),
        rms_s2s_deg = round(rms_deg; digits = 4),
        duration_ms = round(Int, dur_ms),
    )
end

"""
    data_quality(df::EyeData; selection=nothing, eye=:auto, group_by=:auto, prefix=nothing)

Compute per-group data quality metrics. Returns a DataFrame with columns:

- grouping columns (`trial` for single-participant data, or `participant` + `trial` when multiple participants exist)
- `total_samples`: total samples in group
- `valid_samples`: samples where both gaze X and Y are finite
- `tracking_loss_pct`: percentage of samples with missing/NaN gaze
- `blink_count`: number of blinks
- `blink_rate`: blinks per second
- `mean_pupil`: mean pupil size (excluding NaN)
- `rms_s2s_deg`: root-mean-square sample-to-sample gaze displacement in visual degrees
- `duration_ms`: duration in ms

# Example
```julia
dq = data_quality(df)
filter(r -> r.tracking_loss_pct > 50, dq)  # find bad trials

# Multi-block design
dq = data_quality(df; group_by=[:block, :trial])
```
"""
function data_quality(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :auto,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    gaze_eye = _resolve_eye(samples, eye; cols = :gaze)
    pupil_eye = eye == :auto ? _resolve_eye(samples, :auto; cols = :pupil) : gaze_eye
    d = df.df
    gx_all, gy_all = _get_gaze_vecs(d, gaze_eye)
    pa_all = _get_pupil_vec(d, pupil_eye)
    sr = df.sample_rate
    ppd = _eye_units_per_deg(df, gaze_eye)
    inv_ppd = ppd > 0.0 ? 1.0 / ppd : 0.0

    c_fix = _prefixed_sym(prefix, :in_fix)
    c_sacc = _prefixed_sym(prefix, :in_sacc)
    c_blink = _prefixed_sym(prefix, :in_blink)
    has_fix = hasproperty(d, c_fix)
    has_sacc = hasproperty(d, c_sacc)
    has_blink = hasproperty(d, c_blink)
    fix_all = has_fix ? d[!, c_fix] : nothing
    sacc_all = has_sacc ? d[!, c_sacc] : nothing
    blink_all = has_blink ? d[!, c_blink] : nothing

    group_cols = _resolve_group_cols(samples, group_by)
    contig_ranges = _try_contiguous_groups(samples, group_cols)
    grouped = isnothing(contig_ranges) ? groupby(samples, group_cols; skipmissing = true) : nothing
    ng = isnothing(contig_ranges) ? length(grouped) : length(contig_ranges)

    row_first_idx = Vector{Int}(undef, ng)
    tot_v = Vector{Int}(undef, ng)
    val_v = Vector{Int}(undef, ng)
    loss_v = Vector{Float64}(undef, ng)
    bcnt_v = Vector{Int}(undef, ng)
    brate_v = Vector{Float64}(undef, ng)
    mpup_v = Vector{Float64}(undef, ng)
    rms_v = Vector{Float64}(undef, ng)
    dur_v = Vector{Int}(undef, ng)

    if !isnothing(contig_ranges)
        @inbounds for gi = 1:ng
            rows = contig_ranges[gi]
            row_first_idx[gi] = first(rows)
            q = _data_quality_kernel(
                gx_all,
                gy_all,
                pa_all,
                fix_all,
                sacc_all,
                blink_all,
                rows,
                sr,
                inv_ppd,
            )
            tot_v[gi] = q.total_samples
            val_v[gi] = q.valid_samples
            loss_v[gi] = q.tracking_loss_pct
            bcnt_v[gi] = q.blink_count
            brate_v[gi] = q.blink_rate
            mpup_v[gi] = q.mean_pupil
            rms_v[gi] = q.rms_s2s_deg
            dur_v[gi] = q.duration_ms
        end
    else
        @inbounds for gi = 1:ng
            rows = parentindices(grouped[gi])[1]
            row_first_idx[gi] = rows[1]
            q = _data_quality_kernel(
                gx_all,
                gy_all,
                pa_all,
                fix_all,
                sacc_all,
                blink_all,
                rows,
                sr,
                inv_ppd,
            )
            tot_v[gi] = q.total_samples
            val_v[gi] = q.valid_samples
            loss_v[gi] = q.tracking_loss_pct
            bcnt_v[gi] = q.blink_count
            brate_v[gi] = q.blink_rate
            mpup_v[gi] = q.mean_pupil
            rms_v[gi] = q.rms_s2s_deg
            dur_v[gi] = q.duration_ms
        end
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :total_samples => tot_v)
    push!(pairs_out, :valid_samples => val_v)
    push!(pairs_out, :tracking_loss_pct => loss_v)
    push!(pairs_out, :blink_count => bcnt_v)
    push!(pairs_out, :blink_rate => brate_v)
    push!(pairs_out, :mean_pupil => mpup_v)
    push!(pairs_out, :rms_s2s_deg => rms_v)
    push!(pairs_out, :duration_ms => dur_v)
    return DataFrame(pairs_out; copycols = false)
end

function _spatial_precision_kernel(
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    in_fix::Union{Nothing,AbstractVector{Bool}},
    in_sacc::Union{Nothing,AbstractVector{Bool}},
    in_blink::Union{Nothing,AbstractVector{Bool}},
    rows::AbstractVector{Int},
    tr_col::Union{Nothing,AbstractVector},
    pt_col::Union{Nothing,AbstractVector},
    inv_ppd::Float64,
    bcea_k::Float64,
)
    n = length(rows)
    s2s_sq_sum = 0.0
    s2s_cnt = 0
    sxx = 0.0
    syy = 0.0
    sxy = 0.0
    dof = 0
    n_used = 0

    if !isnothing(in_fix)
        i = 1
        @inbounds while i <= n
            if in_fix[rows[i]]
                j = i + 1
                while j <= n &&
                          in_fix[rows[j]] &&
                          _is_group_row_contig(rows[j-1], rows[j], tr_col, pt_col)
                    j += 1
                end
                j_end = j - 1
                sum_x = 0.0
                sum_y = 0.0
                cnt = 0
                prev_ok = false
                prev_x = 0.0
                prev_y = 0.0
                for k = i:j_end
                    rk = rows[k]
                    xk = Float64(gx[rk])
                    yk = Float64(gy[rk])
                    if !isnan(xk) && !isnan(yk)
                        sum_x += xk
                        sum_y += yk
                        cnt += 1
                        if prev_ok
                            dx = xk - prev_x
                            dy = yk - prev_y
                            s2s_sq_sum += dx * dx + dy * dy
                            s2s_cnt += 1
                        end
                        prev_x = xk
                        prev_y = yk
                        prev_ok = true
                    else
                        prev_ok = false
                    end
                end
                if cnt >= 2
                    mx = sum_x / cnt
                    my = sum_y / cnt
                    for k = i:j_end
                        rk = rows[k]
                        xk = Float64(gx[rk])
                        yk = Float64(gy[rk])
                        if !isnan(xk) && !isnan(yk)
                            dx = xk - mx
                            dy = yk - my
                            sxx += dx * dx
                            syy += dy * dy
                            sxy += dx * dy
                        end
                    end
                    dof += (cnt - 1)
                    n_used += cnt
                elseif cnt == 1
                    n_used += 1
                end
                i = j
            else
                i += 1
            end
        end
    else
        i = 1
        @inbounds while i <= n
            j = i + 1
            while j <= n && _is_group_row_contig(rows[j-1], rows[j], tr_col, pt_col)
                j += 1
            end
            j_end = j - 1
            sum_x = 0.0
            sum_y = 0.0
            cnt = 0
            prev_ok = false
            prev_x = 0.0
            prev_y = 0.0
            for k = i:j_end
                rk = rows[k]
                xi = Float64(gx[rk])
                yi = Float64(gy[rk])
                ok =
                    !isnan(xi) &&
                    !isnan(yi) &&
                    (isnothing(in_sacc) || !in_sacc[rk]) &&
                    (isnothing(in_blink) || !in_blink[rk])
                if ok
                    sum_x += xi
                    sum_y += yi
                    cnt += 1
                    if prev_ok
                        dx = xi - prev_x
                        dy = yi - prev_y
                        s2s_sq_sum += dx * dx + dy * dy
                        s2s_cnt += 1
                    end
                    prev_x = xi
                    prev_y = yi
                    prev_ok = true
                else
                    prev_ok = false
                end
            end
            if cnt >= 2
                mx = sum_x / cnt
                my = sum_y / cnt
                for k = i:j_end
                    rk = rows[k]
                    xi = Float64(gx[rk])
                    yi = Float64(gy[rk])
                    ok =
                        !isnan(xi) &&
                        !isnan(yi) &&
                        (isnothing(in_sacc) || !in_sacc[rk]) &&
                        (isnothing(in_blink) || !in_blink[rk])
                    if ok
                        dx = xi - mx
                        dy = yi - my
                        sxx += dx * dx
                        syy += dy * dy
                        sxy += dx * dy
                    end
                end
                dof += (cnt - 1)
                n_used += cnt
            elseif cnt == 1
                n_used += 1
            end
            i = j
        end
    end

    rms_deg = (s2s_cnt > 0 && inv_ppd > 0.0) ? sqrt(s2s_sq_sum / s2s_cnt) * inv_ppd : NaN
    if dof > 0 && inv_ppd > 0.0
        sx_deg = sqrt(sxx / dof) * inv_ppd
        sy_deg = sqrt(syy / dof) * inv_ppd
        std_deg = hypot(sx_deg, sy_deg)
        denom = sqrt(sxx * syy)
        rho = denom > 0.0 ? clamp(sxy / denom, -1.0, 1.0) : 0.0
        bcea = 2.0 * bcea_k * π * sx_deg * sy_deg * sqrt(max(0.0, 1.0 - rho * rho))
    else
        std_deg = NaN
        bcea = NaN
    end

    return (;
        n_samples = n_used,
        rms_s2s_deg = round(rms_deg; digits = 4),
        std_deg = round(std_deg; digits = 4),
        bcea_deg2 = round(bcea; digits = 4),
    )
end

"""
    spatial_precision(df::EyeData; selection=nothing, eye=:auto,
                      group_by=:auto, bcea_prob=0.68, prefix=nothing) -> DataFrame

Compute standard spatial precision metrics per group in degrees of visual angle
(Holmqvist et al., 2012; Niehorster et al., 2020):

- `n_samples`: number of valid samples contributing to precision estimates
- `rms_s2s_deg`: root-mean-square of sample-to-sample angular displacements (°)
- `std_deg`: pooled radial standard deviation `hypot(σx, σy)` (°), demeaned per fixation when fixation columns exist
- `bcea_deg2`: Bivariate Contour Ellipse Area (deg²) enclosing probability `bcea_prob` (default `0.68`)
"""
function spatial_precision(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :auto,
    bcea_prob::Real = 0.68,
    prefix::Union{Nothing,Symbol} = nothing,
)
    prob = Float64(bcea_prob)
    (0.0 < prob < 1.0) ||
        throw(ArgumentError("bcea_prob must satisfy 0 < bcea_prob < 1 (got $bcea_prob)."))
    bcea_k = -log(1.0 - prob)

    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)
    eye = _resolve_eye(samples, eye)
    d = df.df
    gx_all, gy_all = _get_gaze_vecs(d, eye)
    ppd = _eye_units_per_deg(df, eye)
    inv_ppd = ppd > 0.0 ? 1.0 / ppd : 0.0

    c_fix = _prefixed_sym(prefix, :in_fix)
    c_sacc = _prefixed_sym(prefix, :in_sacc)
    c_blink = _prefixed_sym(prefix, :in_blink)
    has_fix = hasproperty(d, c_fix)
    has_sacc = hasproperty(d, c_sacc)
    has_blink = hasproperty(d, c_blink)
    fix_all = has_fix ? d[!, c_fix] : nothing
    sacc_all = has_sacc ? d[!, c_sacc] : nothing
    blink_all = has_blink ? d[!, c_blink] : nothing

    tr_col, pt_col = _group_seam_cols(d)
    ng = length(grouped)
    row_first_idx = Vector{Int}(undef, ng)
    nsamp_v = Vector{Int}(undef, ng)
    rms_v = Vector{Float64}(undef, ng)
    std_v = Vector{Float64}(undef, ng)
    bcea_v = Vector{Float64}(undef, ng)

    @inbounds for gi = 1:ng
        rows = parentindices(grouped[gi])[1]
        row_first_idx[gi] = rows[1]
        sp = _spatial_precision_kernel(
            gx_all,
            gy_all,
            fix_all,
            sacc_all,
            blink_all,
            rows,
            tr_col,
            pt_col,
            inv_ppd,
            bcea_k,
        )
        nsamp_v[gi] = sp.n_samples
        rms_v[gi] = sp.rms_s2s_deg
        std_v[gi] = sp.std_deg
        bcea_v[gi] = sp.bcea_deg2
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :n_samples => nsamp_v)
    push!(pairs_out, :rms_s2s_deg => rms_v)
    push!(pairs_out, :std_deg => std_v)
    push!(pairs_out, :bcea_deg2 => bcea_v)
    return DataFrame(pairs_out; copycols = false)
end

function _group_summary_kernel!(
    fix_durs::Vector{Float64},
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    pa::AbstractVector{<:Real},
    in_fix::Union{Nothing,AbstractVector{Bool}},
    fix_gavx::Union{Nothing,AbstractVector{<:Real}},
    fix_dur::Union{Nothing,AbstractVector{<:Real}},
    in_sacc::Union{Nothing,AbstractVector{Bool}},
    sacc_pvel::Union{Nothing,AbstractVector{<:Real}},
    sacc_ampl::Union{Nothing,AbstractVector{<:Real}},
    in_blink::Union{Nothing,AbstractVector{Bool}},
    rows::AbstractVector{Int},
    tr_col::Union{Nothing,AbstractVector} = nothing,
    pt_col::Union{Nothing,AbstractVector} = nothing,
)
    n_samples = length(rows)
    valid_n = 0
    pa_sum = 0.0
    pa_cnt = 0
    @inbounds for k = 1:n_samples
        r = rows[k]
        (!isnan(gx[r]) && !isnan(gy[r])) && (valid_n += 1)
        pv = pa[r]
        if !isnan(pv)
            pa_sum += Float64(pv)
            pa_cnt += 1
        end
    end
    loss_pct = n_samples > 0 ? round((n_samples - valid_n) / n_samples * 100.0; digits = 1) : 0.0

    empty!(fix_durs)
    fix_sum = 0.0
    if !isnothing(in_fix) && !isnothing(fix_gavx) && !isnothing(fix_dur)
        prev = false
        prev_r = -1
        @inbounds for k = 1:n_samples
            r = rows[k]
            cur = in_fix[r]
            if cur && (!prev || !_is_group_row_contig(prev_r, r, tr_col, pt_col)) && !isnan(fix_gavx[r])
                fd = Float64(fix_dur[r])
                push!(fix_durs, fd)
                fix_sum += fd
            end
            prev = cur
            prev_r = r
        end
    end
    n_fix = length(fix_durs)

    n_sacc = 0
    sacc_pvel_sum = 0.0
    sacc_ampl_sum = 0.0
    sacc_ampl_cnt = 0
    if !isnothing(in_sacc) && !isnothing(sacc_pvel)
        prev = false
        prev_r = -1
        @inbounds for k = 1:n_samples
            r = rows[k]
            cur = in_sacc[r]
            if cur && (!prev || !_is_group_row_contig(prev_r, r, tr_col, pt_col)) && !isnan(sacc_pvel[r])
                n_sacc += 1
                sacc_pvel_sum += Float64(sacc_pvel[r])
                if !isnothing(sacc_ampl) && !isnan(sacc_ampl[r])
                    sacc_ampl_sum += Float64(sacc_ampl[r])
                    sacc_ampl_cnt += 1
                end
            end
            prev = cur
            prev_r = r
        end
    end

    n_blinks = 0
    if !isnothing(in_blink)
        prev = false
        prev_r = -1
        @inbounds for k = 1:n_samples
            r = rows[k]
            cur = in_blink[r]
            if cur && (!prev || !_is_group_row_contig(prev_r, r, tr_col, pt_col))
                n_blinks += 1
            end
            prev = cur
            prev_r = r
        end
    end
    mean_pa = pa_cnt > 0 ? round(pa_sum / pa_cnt; digits = 4) : NaN

    return (;
        n_fixations = n_fix,
        mean_fix_dur = n_fix == 0 ? NaN : round(fix_sum / n_fix; digits = 1),
        median_fix_dur = n_fix == 0 ? NaN : round(median!(fix_durs); digits = 1),
        n_saccades = n_sacc,
        mean_sacc_ampl = sacc_ampl_cnt == 0 ? NaN :
                         round(sacc_ampl_sum / sacc_ampl_cnt; digits = 2),
        mean_sacc_pvel = n_sacc == 0 ? NaN : round(sacc_pvel_sum / n_sacc; digits = 1),
        n_blinks = n_blinks,
        mean_pupil = mean_pa,
        tracking_loss_pct = loss_pct,
    )
end

"""
    group_summary(df::EyeData; selection=nothing, group_by=:auto, by=nothing, eye=:auto, prefix=nothing)

Aggregate fixation, saccade, and pupil statistics per group, optionally
grouped by condition columns. Returns a DataFrame with summary statistics.

`group_by` defines the base grouping (default `:auto`, resolving to `:trial` or
`[:participant, :trial]`). Use `group_by=[:block, :trial]` for multi-block designs.

`by` adds extra condition columns for grouping (e.g., `:type`).

Returns a DataFrame with columns:
- `n_fixations`, `mean_fix_dur`, `median_fix_dur`
- `n_saccades`, `mean_sacc_ampl`, `mean_sacc_pvel`
- `n_blinks`, `mean_pupil`, `tracking_loss_pct`
- Plus grouping columns

# Example
```julia
group_summary(df; group_by=[:block, :trial])
group_summary(df; by=:type)
group_summary(df; group_by=[:block, :trial], by=[:participant, :type])
```
"""
function group_summary(
    df::EyeData;
    selection = nothing,
    group_by = :auto,
    by = nothing,
    eye::Symbol = :auto,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    gaze_eye = _resolve_eye(samples, eye; cols = :gaze)
    pupil_eye = eye == :auto ? _resolve_eye(samples, :auto; cols = :pupil) : gaze_eye

    by_cols = isnothing(by) ? Symbol[] : (by isa Symbol ? Symbol[by] : collect(Symbol, by))
    base_cols = _resolve_group_cols(samples, group_by)
    all_group_cols = unique!(vcat(by_cols, base_cols))

    d = df.df
    gx_all, gy_all = _get_gaze_vecs(d, gaze_eye)
    pa_all = _get_pupil_vec(d, pupil_eye)

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fdur = _prefixed_sym(prefix, :fix_dur)
    c_insacc = _prefixed_sym(prefix, :in_sacc)
    c_spvel = _prefixed_sym(prefix, :sacc_pvel)
    c_sampl = _prefixed_sym(prefix, :sacc_ampl)
    c_inblink = _prefixed_sym(prefix, :in_blink)

    has_fix = hasproperty(d, c_infix) && hasproperty(d, c_fgx) && hasproperty(d, c_fdur)
    has_sacc = hasproperty(d, c_insacc) && hasproperty(d, c_spvel)
    has_ampl = has_sacc && hasproperty(d, c_sampl)
    has_blink = hasproperty(d, c_inblink)

    in_fix_all = has_fix ? d[!, c_infix] : nothing
    fgx_all = has_fix ? d[!, c_fgx] : nothing
    fdur_all = has_fix ? d[!, c_fdur] : nothing
    in_sacc_all = has_sacc ? d[!, c_insacc] : nothing
    spvel_all = has_sacc ? d[!, c_spvel] : nothing
    sampl_all = has_ampl ? d[!, c_sampl] : nothing
    in_blink_all = has_blink ? d[!, c_inblink] : nothing

    group_cols = _resolve_group_cols(samples, all_group_cols)
    contig_ranges = _try_contiguous_groups(samples, group_cols)
    grouped = isnothing(contig_ranges) ? groupby(samples, group_cols; skipmissing = true) : nothing
    ng = isnothing(contig_ranges) ? length(grouped) : length(contig_ranges)

    row_first_idx = Vector{Int}(undef, ng)
    nfix_v = Vector{Int}(undef, ng)
    mfd_v = Vector{Float64}(undef, ng)
    mdfd_v = Vector{Float64}(undef, ng)
    nsacc_v = Vector{Int}(undef, ng)
    msa_v = Vector{Float64}(undef, ng)
    mspv_v = Vector{Float64}(undef, ng)
    nbl_v = Vector{Int}(undef, ng)
    mpup_v = Vector{Float64}(undef, ng)
    loss_v = Vector{Float64}(undef, ng)
    fix_durs = Float64[]
    sizehint!(fix_durs, 64)

    tr_col, pt_col = _group_seam_cols(d)
    if !isnothing(contig_ranges)
        @inbounds for gi = 1:ng
            rows = contig_ranges[gi]
            row_first_idx[gi] = first(rows)
            s = _group_summary_kernel!(
                fix_durs,
                gx_all,
                gy_all,
                pa_all,
                in_fix_all,
                fgx_all,
                fdur_all,
                in_sacc_all,
                spvel_all,
                sampl_all,
                in_blink_all,
                rows,
                tr_col,
                pt_col,
            )
            nfix_v[gi] = s.n_fixations
            mfd_v[gi] = s.mean_fix_dur
            mdfd_v[gi] = s.median_fix_dur
            nsacc_v[gi] = s.n_saccades
            msa_v[gi] = s.mean_sacc_ampl
            mspv_v[gi] = s.mean_sacc_pvel
            nbl_v[gi] = s.n_blinks
            mpup_v[gi] = s.mean_pupil
            loss_v[gi] = s.tracking_loss_pct
        end
    else
        @inbounds for gi = 1:ng
            rows = parentindices(grouped[gi])[1]
            row_first_idx[gi] = rows[1]
            s = _group_summary_kernel!(
                fix_durs,
                gx_all,
                gy_all,
                pa_all,
                in_fix_all,
                fgx_all,
                fdur_all,
                in_sacc_all,
                spvel_all,
                sampl_all,
                in_blink_all,
                rows,
                tr_col,
                pt_col,
            )
            nfix_v[gi] = s.n_fixations
            mfd_v[gi] = s.mean_fix_dur
            mdfd_v[gi] = s.median_fix_dur
            nsacc_v[gi] = s.n_saccades
            msa_v[gi] = s.mean_sacc_ampl
            mspv_v[gi] = s.mean_sacc_pvel
            nbl_v[gi] = s.n_blinks
            mpup_v[gi] = s.mean_pupil
            loss_v[gi] = s.tracking_loss_pct
        end
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :n_fixations => nfix_v)
    push!(pairs_out, :mean_fix_dur => mfd_v)
    push!(pairs_out, :median_fix_dur => mdfd_v)
    push!(pairs_out, :n_saccades => nsacc_v)
    push!(pairs_out, :mean_sacc_ampl => msa_v)
    push!(pairs_out, :mean_sacc_pvel => mspv_v)
    push!(pairs_out, :n_blinks => nbl_v)
    push!(pairs_out, :mean_pupil => mpup_v)
    push!(pairs_out, :tracking_loss_pct => loss_v)
    return DataFrame(pairs_out; copycols = false)
end

function _has_active_time_rel_vec(tr::AbstractVector)::Bool
    @inbounds for i in eachindex(tr)
        v = tr[i]
        if !ismissing(v) && !isnan(v)
            return true
        end
    end
    return false
end

function _has_active_time_rel(df::AbstractDataFrame)::Bool
    hasproperty(df, :time_rel) || return false
    return _has_active_time_rel_vec(df[!, :time_rel])
end

function _extract_rel_time_from_col(tr::AbstractVector)
    n = length(tr)
    out = Vector{Float64}(undef, n)
    any_valid = false
    @inbounds for i = 1:n
        v = tr[i]
        if ismissing(v)
            out[i] = NaN
        else
            fv = Float64(v)
            out[i] = fv
            !isnan(fv) && (any_valid = true)
        end
    end
    return out, any_valid
end

function _extract_rel_time_from_raw(times::AbstractVector{<:Real})
    n = length(times)
    n == 0 && return Float64[]
    t0 = Float64(times[1])
    out = Vector{Float64}(undef, n)
    @inbounds for i = 1:n
        out[i] = Float64(times[i]) - t0
    end
    return out
end

"""
    _trial_relative_time(g::AbstractDataFrame; has_active_trel=nothing) -> Vector{Float64}

Extract sample times relative to trial start or `trial_time_zero`. Uses `time_rel`
when active; if `has_active_trel === true` globally and a catch/aborted trial has
all-`missing` `time_rel`, preserves `NaN` rather than silently misaligning to `time[1]`.
"""
function _trial_relative_time(
    g::AbstractDataFrame;
    has_active_trel::Union{Nothing,Bool} = nothing,
)
    if hasproperty(g, :time_rel)
        out, any_valid = _extract_rel_time_from_col(g[!, :time_rel])
        (any_valid || has_active_trel === true) && return out
    end
    return _extract_rel_time_from_raw(g[!, :time])
end

function _fill_rel_time_from_trel!(
    t_buf::Vector{Float64},
    trel_col::AbstractVector,
    rows::AbstractVector{Int},
    m::Int,
)::Bool
    any_valid = false
    @inbounds for k = 1:m
        v = trel_col[rows[k]]
        if ismissing(v)
            t_buf[k] = NaN
        else
            fv = Float64(v)
            t_buf[k] = fv
            !isnan(fv) && (any_valid = true)
        end
    end
    return any_valid
end

function _fill_rel_time_from_raw!(
    t_buf::Vector{Float64},
    time_col::AbstractVector{<:Real},
    rows::AbstractVector{Int},
    m::Int,
    tr_col::Union{Nothing,AbstractVector} = nothing,
    pt_col::Union{Nothing,AbstractVector} = nothing,
)
    m == 0 && return nothing
    r1 = @inbounds rows[1]
    t0 = Float64(@inbounds time_col[r1])
    @inbounds t_buf[1] = 0.0
    r_prev = r1
    @inbounds for k = 2:m
        rk = rows[k]
        tk = Float64(time_col[rk])
        if !_is_group_row_contig(r_prev, rk, tr_col, pt_col) || tk < Float64(time_col[r_prev])
            t0 = tk
        end
        t_buf[k] = tk - t0
        r_prev = rk
    end
    return nothing
end

function _fill_group_rel_time!(
    t_buf::Vector{Float64},
    has_trel::Bool,
    trel_col,
    time_col::AbstractVector{<:Real},
    rows::AbstractVector{Int},
    tr_col::Union{Nothing,AbstractVector} = nothing,
    pt_col::Union{Nothing,AbstractVector} = nothing,
)::Int
    m = length(rows)
    length(t_buf) < m && resize!(t_buf, m)
    if has_trel
        _fill_rel_time_from_trel!(t_buf, trel_col, rows, m)
        return m
    end
    _fill_rel_time_from_raw!(t_buf, time_col, rows, m, tr_col, pt_col)
    return m
end

function _resolve_time_window_rows(
    parent_df::AbstractDataFrame,
    first_row::Int,
    time_window,
)::Tuple{Float64,Float64}
    if time_window isa Tuple && length(time_window) == 2
        t_start, t_end = time_window
        start_val = if t_start isa Symbol
            hasproperty(parent_df, t_start) ||
                error("time_window column :$t_start not found in DataFrame.")
            v = parent_df[first_row, t_start]
            ismissing(v) ? NaN : Float64(v)
        else
            Float64(t_start)
        end
        end_val = if t_end isa Symbol
            hasproperty(parent_df, t_end) ||
                error("time_window column :$t_end not found in DataFrame.")
            v = parent_df[first_row, t_end]
            ismissing(v) ? NaN : Float64(v)
        else
            Float64(t_end)
        end
        return (start_val, end_val)
    end
    error("time_window must be nothing, or a tuple of two numbers or column symbols.")
end

@inline function _msg_matches_anchor(
    msg::AbstractString,
    anchor::AbstractString,
    allow_substring::Bool,
)::Bool
    isempty(msg) && return false
    if allow_substring
        return occursin(anchor, msg)
    end
    s = strip(msg)
    s == anchor && return true
    la = ncodeunits(anchor)
    ns = ncodeunits(s)
    if ns > la && startswith(s, anchor)
        nxt = codeunit(s, la + 1)
        return nxt == UInt8(' ') || nxt == UInt8('\t') || nxt == UInt8(';') || nxt == UInt8(':')
    end
    # Also check semicolon-joined burst messages ("MSG1; SYNCTIME")
    if occursin(';', s)
        for part in eachsplit(s, ';')
            ps = strip(part)
            (ps == anchor || (ncodeunits(ps) > la && startswith(ps, anchor) && codeunit(ps, la + 1) in (UInt8(' '), UInt8('\t'), UInt8(':')))) &&
                return true
        end
    end
    return false
end

@inline _msg_matches_anchor(msg::AbstractString, anchor::Regex, ::Bool)::Bool =
    !isempty(msg) && occursin(anchor, msg)

"""
    set_time_zero!(ed::EyeData, anchor; group_by=:auto, allow_substring=false) -> EyeData

Compute or re-anchor `ed.df.time_rel` in-place relative to a per-trial event marker
(`anchor::AbstractString` or `anchor::Regex` matched against `:message`) or a per-trial
timestamp column (`anchor::Symbol`, e.g. `:target_onset`).

Groups where the anchor message is absent (or the anchor column is `missing`/`NaN`) receive
`NaN` in `:time_rel` so downstream windowed analyses exclude unanchored catch trials.
Return `ed`.
"""
function set_time_zero!(
    ed::EyeData,
    anchor::Union{AbstractString,Regex,Symbol};
    group_by = :auto,
    allow_substring::Bool = false,
)
    d = ed.df
    n = nrow(d)
    hasproperty(d, :time) || error("DataFrame must contain a :time column.")
    times = d[!, :time]
    t_rel = fill(NaN, n)
    group_cols = _resolve_group_cols(ed, group_by)
    grouped = groupby(d, group_cols; skipmissing = true)

    if anchor isa Symbol
        hasproperty(d, anchor) ||
            throw(ArgumentError("Anchor column :$anchor not found in DataFrame."))
        acol = d[!, anchor]
        @inbounds for g in grouped
            rows = parentindices(g)[1]
            isempty(rows) && continue
            v0 = acol[rows[1]]
            (ismissing(v0) || !(v0 isa Real) || isnan(v0)) && continue
            t0 = Float64(v0)
            for r in rows
                t_rel[r] = Float64(times[r]) - t0
            end
        end
    else
        hasproperty(d, :message) ||
            throw(ArgumentError("DataFrame has no :message column to search for anchor $(repr(anchor))."))
        msgs = d[!, :message]
        @inbounds for g in grouped
            rows = parentindices(g)[1]
            isempty(rows) && continue
            t0 = NaN
            for r in rows
                mr = msgs[r]
                (!ismissing(mr) && _msg_matches_anchor(mr, anchor, allow_substring)) || continue
                t0 = Float64(times[r])
                break
            end
            isnan(t0) && continue
            for r in rows
                t_rel[r] = Float64(times[r]) - t0
            end
        end
    end

    d[!, :time_rel] = t_rel
    return ed
end
