@inline function _time_bin_params(has_tw::Bool, t_start::Float64, t_end::Float64, bin_ms::Int)
    origin = (has_tw && isfinite(t_start)) ? t_start : 0.0
    span = t_end - origin
    n_exact = (has_tw && isfinite(span) && span >= bin_ms) ? round(Int, span / bin_ms) : 0
    clamp_right = n_exact >= 1 && abs(span - n_exact * bin_ms) <= 1e-9
    return origin, clamp_right, n_exact - 1
end

@inline function _time_bin_idx(
    ti::Float64,
    origin::Float64,
    bin_ms::Int,
    clamp_right::Bool,
    t_end::Float64,
    right_bin::Int,
)::Int
    (clamp_right && ti == t_end) && return right_bin
    return Int(fld(ti - origin, bin_ms))
end

function _time_bin_flat!(
    row_first_idx::Vector{Int},
    out_bin::Vector{Float64},
    out_val::Vector{Float64},
    out_n::Vector{Int},
    parent_df::DataFrame,
    grouped::GroupedDataFrame,
    vals_col::AbstractVector{<:Real},
    gx_vel::Union{Nothing,AbstractVector{<:Real}},
    gy_vel::Union{Nothing,AbstractVector{<:Real}},
    vel_scale::Float64,
    has_trel::Bool,
    trel_col,
    time_col::AbstractVector{<:Real},
    bin_ms::Int,
    time_window,
)
    n_groups = length(grouped)
    has_tw = !isnothing(time_window)
    is_vel = !isnothing(gx_vel)
    half_bin = bin_ms / 2.0

    t_buf = Float64[]
    v_buf = Float64[]
    gx_buf = Float64[]
    gy_buf = Float64[]
    sums = Float64[]
    cnts = Int[]

    @inbounds for g_idx = 1:n_groups
        rows = parentindices(grouped[g_idx])[1]
        m = length(rows)
        m == 0 && continue
        first_r = rows[1]
        _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, rows)
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(parent_df, first_r, time_window) : (0.0, 0.0)
        origin, clamp_right, right_bin = _time_bin_params(has_tw, t_start, t_end, bin_ms)

        if is_vel
            length(gx_buf) < m && resize!(gx_buf, m)
            length(gy_buf) < m && resize!(gy_buf, m)
            length(v_buf) < m && resize!(v_buf, m)
            for k = 1:m
                rk = rows[k]
                gx_buf[k] = Float64(gx_vel[rk])
                gy_buf[k] = Float64(gy_vel[rk])
                v_buf[k] = NaN
            end
            _compute_velocity_deg!(v_buf, gx_buf, gy_buf, 1, m, vel_scale)
        end

        b_min = typemax(Int)
        b_max = typemin(Int)
        n_valid = 0

        for k = 1:m
            ti = t_buf[k]
            vi = is_vel ? v_buf[k] : Float64(vals_col[rows[k]])
            (isnan(ti) || isnan(vi)) && continue
            if has_tw && (ti < t_start || ti > t_end)
                continue
            end
            b = _time_bin_idx(ti, origin, bin_ms, clamp_right, t_end, right_bin)
            b < b_min && (b_min = b)
            b > b_max && (b_max = b)
            n_valid += 1
        end
        n_valid == 0 && continue

        nbins = b_max - b_min + 1
        if length(sums) < nbins
            resize!(sums, nbins)
            resize!(cnts, nbins)
        end
        fill!(view(sums, 1:nbins), 0.0)
        fill!(view(cnts, 1:nbins), 0)

        for k = 1:m
            ti = t_buf[k]
            vi = is_vel ? v_buf[k] : Float64(vals_col[rows[k]])
            (isnan(ti) || isnan(vi)) && continue
            if has_tw && (ti < t_start || ti > t_end)
                continue
            end
            idx = _time_bin_idx(ti, origin, bin_ms, clamp_right, t_end, right_bin) - b_min + 1
            sums[idx] += vi
            cnts[idx] += 1
        end

        for b_idx = 1:nbins
            ck = cnts[b_idx]
            if ck > 0
                push!(row_first_idx, first_r)
                push!(out_bin, origin + (b_min + b_idx - 1) * bin_ms + half_bin)
                push!(out_val, sums[b_idx] / ck)
                push!(out_n, ck)
            end
        end
    end
    return nothing
end

"""
    time_bin(df::EyeData; selection=nothing, bin_ms=50, measure=:pupil,
             eye=:auto, group_by=:auto, time_window=nothing)

Bin time-series data into fixed-width time bins and compute mean values per bin.

Returns a DataFrame with columns:
- Group columns (e.g. `:trial` or `[:participant, :trial]`)
- `time_bin`: bin center in ms
- `value`: mean value within the bin
- `n`: number of valid samples in the bin

# Measures
- `:pupil`: pupil size
- `:gaze_x`: horizontal gaze position
- `:gaze_y`: vertical gaze position
- `:velocity`: gaze velocity in °/s (computed via 5-point central difference)
"""
function time_bin(
    df::EyeData;
    selection = nothing,
    bin_ms::Int = 50,
    measure::Symbol = :pupil,
    eye::Symbol = :auto,
    group_by = :auto,
    time_window::Union{Nothing,Tuple} = nothing,
)
    bin_ms > 0 || error("bin_ms must be positive (got $bin_ms).")
    measure in (:pupil, :gaze_x, :gaze_y, :velocity) ||
        error("Unknown measure=:$measure. Use :pupil, :gaze_x, :gaze_y, or :velocity.")

    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye; cols = measure == :pupil ? :pupil : :gaze)
    d = df.df
    ppd = measure == :velocity ? _eye_units_per_deg(df, eye) : 0.0
    vel_scale = measure == :velocity ? Float64(df.sample_rate) / (6.0 * ppd) : 0.0
    has_trel = _has_active_time_rel(d)

    if measure == :pupil
        vals_col = _get_pupil_vec(d, eye)
        gx_vel = nothing
        gy_vel = nothing
    else
        gx_all, gy_all = _get_gaze_vecs(d, eye)
        vals_col = measure == :gaze_y ? gy_all : gx_all
        gx_vel = measure == :velocity ? gx_all : nothing
        gy_vel = measure == :velocity ? gy_all : nothing
    end

    est = max(length(grouped) * 32, 32)
    row_first_idx = sizehint!(Int[], est)
    out_bin = sizehint!(Float64[], est)
    out_val = sizehint!(Float64[], est)
    out_n = sizehint!(Int[], est)

    if length(grouped) > 0
        _time_bin_flat!(
            row_first_idx,
            out_bin,
            out_val,
            out_n,
            d,
            grouped,
            vals_col,
            gx_vel,
            gy_vel,
            vel_scale,
            has_trel,
            has_trel ? d[!, :time_rel] : nothing,
            d[!, :time],
            bin_ms,
            time_window,
        )
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :time_bin => out_bin)
    push!(pairs_out, :value => out_val)
    push!(pairs_out, :n => out_n)
    return DataFrame(pairs_out; copycols = false)
end

function _accum_aoi_bin_hits_concrete!(
    hit_counts::Vector{Int},
    any_hit_mask::Vector{UInt8},
    aoi_off::Int,
    aoi::A,
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    t_buf::Vector{Float64},
    sample_bin::Vector{Int},
    rows::AbstractVector{Int},
    m::Int,
    b_min::Int,
) where {A<:AOI}
    @inbounds for k = 1:m
        b_raw = sample_bin[k]
        b_raw == typemin(Int) && continue
        rk = rows[k]
        xi = Float64(gx[rk])
        yi = Float64(gy[rk])
        ti = t_buf[k]
        if in_aoi(aoi, xi, yi, ti)
            b_idx = b_raw - b_min + 1
            hit_counts[aoi_off+b_idx] += 1
            any_hit_mask[k] = 0x01
        end
    end
    return nothing
end

function _accum_aoi_bin_hits!(
    hit_counts::Vector{Int},
    any_hit_mask::Vector{UInt8},
    aoi_off::Int,
    @nospecialize(aoi::AOI),
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    t_buf::Vector{Float64},
    sample_bin::Vector{Int},
    rows::AbstractVector{Int},
    m::Int,
    b_min::Int,
)
    if aoi isa RectAOI
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    elseif aoi isa CircleAOI
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    elseif aoi isa EllipseAOI
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    elseif aoi isa PolygonAOI
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    elseif aoi isa DynamicAOI{RectAOI}
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    elseif aoi isa DynamicAOI{CircleAOI}
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    elseif aoi isa DynamicAOI{EllipseAOI}
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    elseif aoi isa DynamicAOI{PolygonAOI}
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    else
        _accum_aoi_bin_hits_concrete!(hit_counts, any_hit_mask, aoi_off, aoi, gx, gy, t_buf, sample_bin, rows, m, b_min)
    end
    return nothing
end

function _proportion_of_looks_flat!(
    row_first_idx::Vector{Int},
    out_bin::Vector{Float64},
    aoi_cols::Vector{Vector{Float64}},
    outside_col::Vector{Float64},
    out_n::Union{Nothing,Vector{Int}},
    parent_df::DataFrame,
    grouped::GroupedDataFrame,
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    aois::Vector{<:AOI},
    has_trel::Bool,
    trel_col,
    time_col::AbstractVector{<:Real},
    bin_ms::Int,
    time_window,
)
    n_groups = length(grouped)
    n_aois = length(aois)
    n_slots = n_aois + 1
    has_tw = !isnothing(time_window)
    half_bin = bin_ms / 2.0

    t_buf = Float64[]
    sample_bin = Int[]
    any_hit_mask = UInt8[]
    hit_counts = Int[]  # flattened (nbins, n_aois + 1): index = (slot - 1) * nbins + b_idx
    total_cnts = Int[]

    @inbounds for g_idx = 1:n_groups
        rows = parentindices(grouped[g_idx])[1]
        m = length(rows)
        m == 0 && continue
        first_r = rows[1]
        _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, rows)
        length(sample_bin) < m && resize!(sample_bin, m)
        length(any_hit_mask) < m && resize!(any_hit_mask, m)
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(parent_df, first_r, time_window) : (0.0, 0.0)
        origin, clamp_right, right_bin = _time_bin_params(has_tw, t_start, t_end, bin_ms)

        b_min = typemax(Int)
        b_max = typemin(Int)
        n_valid = 0

        for k = 1:m
            ti = t_buf[k]
            rk = rows[k]
            xi = Float64(gx[rk])
            yi = Float64(gy[rk])
            if isnan(ti) || isnan(xi) || isnan(yi) || (has_tw && (ti < t_start || ti > t_end))
                sample_bin[k] = typemin(Int)
                continue
            end
            b = _time_bin_idx(ti, origin, bin_ms, clamp_right, t_end, right_bin)
            sample_bin[k] = b
            any_hit_mask[k] = 0x00
            b < b_min && (b_min = b)
            b > b_max && (b_max = b)
            n_valid += 1
        end
        n_valid == 0 && continue

        nbins = b_max - b_min + 1
        req_hits = nbins * n_slots
        length(hit_counts) < req_hits && resize!(hit_counts, req_hits)
        length(total_cnts) < nbins && resize!(total_cnts, nbins)
        fill!(view(hit_counts, 1:req_hits), 0)
        fill!(view(total_cnts, 1:nbins), 0)

        for ai = 1:n_aois
            _accum_aoi_bin_hits!(
                hit_counts,
                any_hit_mask,
                (ai - 1) * nbins,
                aois[ai],
                gx,
                gy,
                t_buf,
                sample_bin,
                rows,
                m,
                b_min,
            )
        end

        outside_off = n_aois * nbins
        for k = 1:m
            b_raw = sample_bin[k]
            b_raw == typemin(Int) && continue
            b_idx = b_raw - b_min + 1
            total_cnts[b_idx] += 1
            if any_hit_mask[k] == 0x00
                hit_counts[outside_off+b_idx] += 1
            end
        end

        for b_idx = 1:nbins
            tot = total_cnts[b_idx]
            if tot > 0
                inv_tot = 1.0 / tot
                push!(row_first_idx, first_r)
                push!(out_bin, origin + (b_min + b_idx - 1) * bin_ms + half_bin)
                for ai = 1:n_aois
                    push!(aoi_cols[ai], hit_counts[(ai-1)*nbins+b_idx] * inv_tot)
                end
                push!(outside_col, hit_counts[outside_off+b_idx] * inv_tot)
                !isnothing(out_n) && push!(out_n, tot)
            end
        end
    end
    return nothing
end

"""
    proportion_of_looks(df::EyeData, aois::Vector{<:AOI};
                        selection=nothing, bin_ms=50, eye=:auto,
                        group_by=:auto, time_window=nothing, include_n=false)

Compute the proportion of gaze samples falling in each AOI per time bin.

Returns a DataFrame with columns:
- Group columns (e.g. `:trial` or `[:participant, :trial]`)
- `time_bin`: bin center in ms
- One column per AOI name: proportion of looks (0.0–1.0)
- `outside`: proportion of looks outside all AOIs
- `n` (when `include_n=true`): valid gaze sample count in the bin
"""
function proportion_of_looks(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    bin_ms::Int = 50,
    eye::Symbol = :auto,
    group_by = :auto,
    time_window::Union{Nothing,Tuple} = nothing,
    include_n::Bool = false,
)
    bin_ms > 0 || error("bin_ms must be positive (got $bin_ms).")
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
    d = df.df
    gx_vec, gy_vec = _get_gaze_vecs(d, eye)
    has_trel = _has_active_time_rel(d)

    aoi_syms = Symbol[Symbol(a.name) for a in aois]
    length(unique(aoi_syms)) == length(aoi_syms) ||
        error("Duplicate AOI names in proportion_of_looks; each AOI must have a unique name.")
    reserved_cols = include_n ? vcat(group_cols, [:time_bin, :outside, :n]) :
                    vcat(group_cols, [:time_bin, :outside])
    reserved = Set(reserved_cols)
    for sym in aoi_syms
        sym in reserved &&
            error("AOI name \"$sym\" collides with output column :$sym in proportion_of_looks.")
    end

    n_aois = length(aois)
    est = max(length(grouped) * 32, 32)
    row_first_idx = sizehint!(Int[], est)
    out_bin = sizehint!(Float64[], est)
    aoi_cols = Vector{Float64}[sizehint!(Float64[], est) for _ = 1:n_aois]
    outside_col = sizehint!(Float64[], est)
    out_n = include_n ? sizehint!(Int[], est) : nothing

    if length(grouped) > 0
        _proportion_of_looks_flat!(
            row_first_idx,
            out_bin,
            aoi_cols,
            outside_col,
            out_n,
            d,
            grouped,
            gx_vec,
            gy_vec,
            aois,
            has_trel,
            has_trel ? d[!, :time_rel] : nothing,
            d[!, :time],
            bin_ms,
            time_window,
        )
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :time_bin => out_bin)
    for ai = 1:n_aois
        push!(pairs_out, aoi_syms[ai] => aoi_cols[ai])
    end
    push!(pairs_out, :outside => outside_col)
    !isnothing(out_n) && push!(pairs_out, :n => out_n)
    return DataFrame(pairs_out; copycols = false)
end
