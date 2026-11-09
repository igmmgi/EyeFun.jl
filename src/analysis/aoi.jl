"""Union-split point-in-AOI test avoiding dynamic dispatch on `Vector{AOI}`."""
@inline function _in_aoi_fast(@nospecialize(aoi::AOI), x::Float64, y::Float64)::Bool
    if aoi isa RectAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa CircleAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa EllipseAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa PolygonAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa DynamicAOI{RectAOI}
        return in_aoi(aoi, x, y)
    elseif aoi isa DynamicAOI{CircleAOI}
        return in_aoi(aoi, x, y)
    elseif aoi isa DynamicAOI{EllipseAOI}
        return in_aoi(aoi, x, y)
    elseif aoi isa DynamicAOI{PolygonAOI}
        return in_aoi(aoi, x, y)
    elseif aoi isa DynamicAOI
        return in_aoi(aoi, x, y)::Bool
    else
        return in_aoi(aoi, x, y)::Bool
    end
end

@inline function _in_aoi_fast(@nospecialize(aoi::AOI), x::Float64, y::Float64, t::Float64)::Bool
    if aoi isa RectAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa CircleAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa EllipseAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa PolygonAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa DynamicAOI{RectAOI}
        return in_aoi(aoi, x, y, t)
    elseif aoi isa DynamicAOI{CircleAOI}
        return in_aoi(aoi, x, y, t)
    elseif aoi isa DynamicAOI{EllipseAOI}
        return in_aoi(aoi, x, y, t)
    elseif aoi isa DynamicAOI{PolygonAOI}
        return in_aoi(aoi, x, y, t)
    elseif aoi isa DynamicAOI
        return in_aoi(aoi, x, y, t)::Bool
    else
        return in_aoi(aoi, x, y, t)::Bool
    end
end

@inline function _in_aoi_interval_fast(
    @nospecialize(aoi::AOI),
    x::Float64,
    y::Float64,
    t0::Float64,
    t1::Float64,
)::Bool
    if aoi isa RectAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa CircleAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa EllipseAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa PolygonAOI
        return in_aoi(aoi, x, y)
    elseif aoi isa DynamicAOI{RectAOI}
        return _in_dynamic_aoi_interval(aoi, x, y, t0, t1)
    elseif aoi isa DynamicAOI{CircleAOI}
        return _in_dynamic_aoi_interval(aoi, x, y, t0, t1)
    elseif aoi isa DynamicAOI{EllipseAOI}
        return _in_dynamic_aoi_interval(aoi, x, y, t0, t1)
    elseif aoi isa DynamicAOI{PolygonAOI}
        return _in_dynamic_aoi_interval(aoi, x, y, t0, t1)
    elseif aoi isa DynamicAOI
        return _in_dynamic_aoi_interval(aoi, x, y, t0, t1)::Bool
    else
        return in_aoi(aoi, x, y, t0)::Bool
    end
end

function _extract_aoi_fix_onsets_rows!(
    fx::Vector{Float64},
    fy::Vector{Float64},
    fd::Vector{Float64},
    ft::Vector{Float64},
    in_fix::AbstractVector{Bool},
    fix_gavx::AbstractVector{<:Real},
    fix_gavy::AbstractVector{<:Real},
    fix_dur::AbstractVector{<:Real},
    t_buf::Vector{Float64},
    rows::AbstractVector{Int},
    m::Int,
    has_tw::Bool,
    t_start::Float64,
    t_end::Float64,
)
    empty!(fx)
    empty!(fy)
    empty!(fd)
    empty!(ft)
    prev = false
    @inbounds for k = 1:m
        r = rows[k]
        cur = in_fix[r]
        if cur & !prev
            x = Float64(fix_gavx[r])
            y = Float64(fix_gavy[r])
            if !isnan(x) && !isnan(y)
                onset = t_buf[k]
                dur = Float64(fix_dur[r])
                if has_tw
                    f_end = onset + dur
                    if f_end > t_start && onset < t_end
                        if onset < t_start
                            dur -= (t_start - onset)
                            onset = t_start
                        end
                        if onset + dur > t_end
                            dur -= (onset + dur - t_end)
                        end
                        if dur > 0
                            push!(fx, x)
                            push!(fy, y)
                            push!(fd, dur)
                            push!(ft, onset)
                        end
                    end
                else
                    push!(fx, x)
                    push!(fy, y)
                    push!(fd, dur)
                    push!(ft, onset)
                end
            end
        end
        prev = cur
    end
    return nothing
end

function _aoi_sample_stats_concrete(
    aoi::A,
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    t_buf::Vector{Float64},
    rows::AbstractVector{Int},
    m::Int,
    has_tw::Bool,
    t_start::Float64,
    t_end::Float64,
) where {A<:AOI}
    dwell_samples = 0
    entries = 0
    prev_in = false
    first_sample_t = NaN

    @inbounds for k = 1:m
        ti = t_buf[k]
        if has_tw && (isnan(ti) || ti < t_start || ti > t_end)
            continue
        end
        r = rows[k]
        xi = Float64(gx[r])
        yi = Float64(gy[r])
        if isnan(xi) || isnan(yi)
            continue
        end
        if in_aoi(aoi, xi, yi, ti)
            dwell_samples += 1
            if !prev_in
                entries += 1
                prev_in = true
            end
            if isnan(first_sample_t) && !isnan(ti)
                first_sample_t = ti
            end
        else
            prev_in = false
        end
    end
    return dwell_samples, entries, first_sample_t
end

function _aoi_sample_stats_rows(
    @nospecialize(aoi::AOI),
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    t_buf::Vector{Float64},
    rows::AbstractVector{Int},
    m::Int,
    has_tw::Bool,
    t_start::Float64,
    t_end::Float64,
)
    if aoi isa RectAOI
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    elseif aoi isa CircleAOI
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    elseif aoi isa EllipseAOI
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    elseif aoi isa PolygonAOI
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    elseif aoi isa DynamicAOI{RectAOI}
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    elseif aoi isa DynamicAOI{CircleAOI}
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    elseif aoi isa DynamicAOI{EllipseAOI}
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    elseif aoi isa DynamicAOI{PolygonAOI}
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)
    else
        return _aoi_sample_stats_concrete(aoi, gx, gy, t_buf, rows, m, has_tw, t_start, t_end)::Tuple{Int,Int,Float64}
    end
end

function _aoi_metrics_flat!(
    row_first_idx::Vector{Int},
    col_aoi::Vector{String},
    col_dwell::Vector{Float64},
    col_fcount::Vector{Int},
    col_ftime::Vector{Union{Float64,Missing}},
    col_fdur::Vector{Union{Float64,Missing}},
    col_entries::Vector{Int},
    parent_df::DataFrame,
    grouped::GroupedDataFrame,
    aois::Vector{<:AOI},
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    has_trel::Bool,
    trel_col,
    time_col::AbstractVector{<:Real},
    has_fix::Bool,
    in_fix,
    fix_gavx,
    fix_gavy,
    fix_dur,
    time_window,
    inv_sr_ms::Float64,
)
    n_groups = length(grouped)
    n_aois = length(aois)
    has_tw = !isnothing(time_window)

    t_buf = Float64[]
    fx = Float64[]
    fy = Float64[]
    fd = Float64[]
    ft = Float64[]

    out_pos = 0
    @inbounds for g_idx = 1:n_groups
        rows = parentindices(grouped[g_idx])[1]
        m = length(rows)
        first_r = rows[1]
        _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, rows)
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(parent_df, first_r, time_window) : (0.0, 0.0)

        if has_fix
            _extract_aoi_fix_onsets_rows!(
                fx,
                fy,
                fd,
                ft,
                in_fix,
                fix_gavx,
                fix_gavy,
                fix_dur,
                t_buf,
                rows,
                m,
                has_tw,
                t_start,
                t_end,
            )
        end

        for idx = 1:n_aois
            aoi = aois[idx]
            dwell_samples, entries, first_sample_t = _aoi_sample_stats_rows(
                aoi,
                gx,
                gy,
                t_buf,
                rows,
                m,
                has_tw,
                t_start,
                t_end,
            )
            dwell = round(dwell_samples * inv_sr_ms; digits = 1)

            first_fix_time = NaN
            first_fix_dur = NaN
            fix_count = 0

            if has_fix
                for k in eachindex(fx)
                    if _in_aoi_interval_fast(aoi, fx[k], fy[k], ft[k], ft[k] + fd[k])
                        if fix_count == 0
                            first_fix_time = ft[k]
                            first_fix_dur = fd[k]
                        end
                        fix_count += 1
                    end
                end
            else
                first_fix_time = first_sample_t
            end

            out_pos += 1
            row_first_idx[out_pos] = first_r
            col_aoi[out_pos] = aoi.name
            col_dwell[out_pos] = dwell
            col_fcount[out_pos] = fix_count
            col_ftime[out_pos] =
                isnan(first_fix_time) ? missing : round(first_fix_time; digits = 1)
            col_fdur[out_pos] =
                isnan(first_fix_dur) ? missing : round(first_fix_dur; digits = 1)
            col_entries[out_pos] = entries
        end
    end
    return nothing
end

"""
    aoi_metrics(df::EyeData, aois::Vector{<:AOI};
                selection=nothing, eye=:auto, group_by=:auto, time_window=nothing, prefix=nothing)

Compute standard Area of Interest metrics per group. Returns a DataFrame with:

- grouping columns (e.g. `trial`, or `participant` + `trial`)
- `aoi`: AOI name
- `dwell_time_ms`: total time spent in AOI
- `fixation_count`: number of fixations landing in AOI
- `first_fixation_time_ms`: time of first fixation/gaze entry
- `first_fixation_duration_ms`: duration of the first fixation in AOI
- `entry_count`: number of gaze entries into AOI
"""
function aoi_metrics(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :auto,
    time_window::Union{Nothing,Tuple} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found.")
    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
    d = df.df
    gx_vec, gy_vec = _get_gaze_vecs(d, eye)
    inv_sr_ms = 1000.0 / df.sample_rate

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fgy = _prefixed_sym(prefix, :fix_gavy)
    c_fdur = _prefixed_sym(prefix, :fix_dur)
    has_fix =
        hasproperty(d, c_infix) &&
        hasproperty(d, c_fgx) &&
        hasproperty(d, c_fgy) &&
        hasproperty(d, c_fdur)
    has_trel = _has_active_time_rel(d)

    n_out = length(grouped) * length(aois)
    row_first_idx = Vector{Int}(undef, n_out)
    col_aoi = Vector{String}(undef, n_out)
    col_dwell = Vector{Float64}(undef, n_out)
    col_fcount = Vector{Int}(undef, n_out)
    col_ftime = Vector{Union{Float64,Missing}}(undef, n_out)
    col_fdur = Vector{Union{Float64,Missing}}(undef, n_out)
    col_entries = Vector{Int}(undef, n_out)

    if n_out > 0
        _aoi_metrics_flat!(
            row_first_idx,
            col_aoi,
            col_dwell,
            col_fcount,
            col_ftime,
            col_fdur,
            col_entries,
            d,
            grouped,
            aois,
            gx_vec,
            gy_vec,
            has_trel,
            has_trel ? d[!, :time_rel] : nothing,
            d[!, :time],
            has_fix,
            has_fix ? d[!, c_infix] : nothing,
            has_fix ? d[!, c_fgx] : nothing,
            has_fix ? d[!, c_fgy] : nothing,
            has_fix ? d[!, c_fdur] : nothing,
            time_window,
            inv_sr_ms,
        )
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :aoi => col_aoi)
    push!(pairs_out, :dwell_time_ms => col_dwell)
    push!(pairs_out, :fixation_count => col_fcount)
    push!(pairs_out, :first_fixation_time_ms => col_ftime)
    push!(pairs_out, :first_fixation_duration_ms => col_fdur)
    push!(pairs_out, :entry_count => col_entries)
    return DataFrame(pairs_out; copycols = false)
end
