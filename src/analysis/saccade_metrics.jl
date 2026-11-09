function _saccade_metrics_flat!(
    row_first_idx::Vector{Int},
    col_idx::Vector{Int},
    col_dur::Vector{Float64},
    col_sx::Vector{Float64},
    col_sy::Vector{Float64},
    col_ex::Vector{Float64},
    col_ey::Vector{Float64},
    col_ampl::Vector{Float64},
    col_pvel::Vector{Float64},
    col_curv::Vector{Float64},
    col_ratio::Vector{Float64},
    parent_df::DataFrame,
    grouped::GroupedDataFrame,
    in_sacc::AbstractVector{Bool},
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    sacc_ampl::Union{Nothing,AbstractVector{<:Real}},
    sacc_pvel::Union{Nothing,AbstractVector{<:Real}},
    has_trel::Bool,
    trel_col,
    time_col::AbstractVector{<:Real},
    time_window,
    inv_sr_ms::Float64,
    inv_ppd::Float64,
)
    n_groups = length(grouped)
    has_tw = !isnothing(time_window)
    t_buf = Float64[]

    @inbounds for g_idx = 1:n_groups
        rows = parentindices(grouped[g_idx])[1]
        m = length(rows)
        first_r = rows[1]
        _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, rows)
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(parent_df, first_r, time_window) :
            (-Inf, Inf)

        i = 1
        saccade_idx = 1
        while i <= m
            if in_sacc[rows[i]]
                j = i + 1
                while j <= m && in_sacc[rows[j]]
                    j += 1
                end
                j_end = j - 1

                sacc_t = t_buf[i]
                if t_start <= sacc_t <= t_end
                    first_k = 0
                    last_k = 0
                    valid_cnt = 0
                    for k = i:j_end
                        rk = rows[k]
                        if !isnan(gx[rk]) && !isnan(gy[rk])
                            first_k == 0 && (first_k = k)
                            last_k = k
                            valid_cnt += 1
                        end
                    end

                    if valid_cnt >= 2
                        r_first = rows[first_k]
                        r_last = rows[last_k]
                        xs, ys = Float64(gx[r_first]), Float64(gy[r_first])
                        xe, ye = Float64(gx[r_last]), Float64(gy[r_last])
                        dx = xe - xs
                        dy = ye - ys
                        amplitude_px = hypot(dx, dy)

                        max_curvature_px = 0.0
                        if amplitude_px > 1e-6
                            inv_amp = 1.0 / amplitude_px
                            for k = first_k:last_k
                                rk = rows[k]
                                xi, yi = Float64(gx[rk]), Float64(gy[rk])
                                if !isnan(xi) && !isnan(yi)
                                    dist = abs(dx * (ys - yi) - (xs - xi) * dy) * inv_amp
                                    dist > max_curvature_px && (max_curvature_px = dist)
                                end
                            end
                        end

                        curvature_ratio =
                            amplitude_px > 1e-6 ? max_curvature_px / amplitude_px : 0.0
                        ampl_deg =
                            isnothing(sacc_ampl) ? NaN : Float64(sacc_ampl[r_first])
                        if isnan(ampl_deg) && inv_ppd > 0.0
                            ampl_deg = amplitude_px * inv_ppd
                        end
                        pvel = isnothing(sacc_pvel) ? NaN : Float64(sacc_pvel[r_first])
                        dur = (j_end - i + 1) * inv_sr_ms

                        push!(row_first_idx, first_r)
                        push!(col_idx, saccade_idx)
                        push!(col_dur, round(dur; digits = 2))
                        push!(col_sx, round(xs; digits = 2))
                        push!(col_sy, round(ys; digits = 2))
                        push!(col_ex, round(xe; digits = 2))
                        push!(col_ey, round(ye; digits = 2))
                        push!(col_ampl, round(ampl_deg; digits = 4))
                        push!(col_pvel, round(pvel; digits = 4))
                        push!(col_curv, round(max_curvature_px; digits = 4))
                        push!(col_ratio, round(curvature_ratio; digits = 4))
                        saccade_idx += 1
                    end
                end
                i = j
            else
                i += 1
            end
        end
    end
    return nothing
end

"""
    saccade_metrics(df::EyeData; selection=nothing, eye=:auto, group_by=:auto,
                    time_window=nothing, prefix=nothing)

Extract individual saccadic geometric characteristics, including trajectory curvature
(maximum orthogonal deviation from a straight line).
"""
function saccade_metrics(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :auto,
    time_window::Union{Nothing,Tuple} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    c_insacc = _prefixed_sym(prefix, :in_sacc)
    c_sampl = _prefixed_sym(prefix, :sacc_ampl)
    c_spvel = _prefixed_sym(prefix, :sacc_pvel)

    hasproperty(samples, c_insacc) ||
        error("No saccade tracking columns ($c_insacc). Run event detection first.")

    grouped, group_cols = _valid_groups(samples, group_by)
    eye = _resolve_eye(samples, eye)
    d = df.df
    gx_vec, gy_vec = _get_gaze_vecs(d, eye)

    has_ampl = hasproperty(d, c_sampl)
    has_pvel = hasproperty(d, c_spvel)
    has_trel = _has_active_time_rel(d)
    inv_sr_ms = 1000.0 / df.sample_rate
    ppd = _eye_units_per_deg(df, eye)
    inv_ppd = ppd > 0.0 ? 1.0 / ppd : 0.0

    est = max(length(grouped) * 8, 16)
    row_first_idx = sizehint!(Int[], est)
    col_idx = sizehint!(Int[], est)
    col_dur = sizehint!(Float64[], est)
    col_sx = sizehint!(Float64[], est)
    col_sy = sizehint!(Float64[], est)
    col_ex = sizehint!(Float64[], est)
    col_ey = sizehint!(Float64[], est)
    col_ampl = sizehint!(Float64[], est)
    col_pvel = sizehint!(Float64[], est)
    col_curv = sizehint!(Float64[], est)
    col_ratio = sizehint!(Float64[], est)

    if length(grouped) > 0
        _saccade_metrics_flat!(
            row_first_idx,
            col_idx,
            col_dur,
            col_sx,
            col_sy,
            col_ex,
            col_ey,
            col_ampl,
            col_pvel,
            col_curv,
            col_ratio,
            d,
            grouped,
            d[!, c_insacc],
            gx_vec,
            gy_vec,
            has_ampl ? d[!, c_sampl] : nothing,
            has_pvel ? d[!, c_spvel] : nothing,
            has_trel,
            has_trel ? d[!, :time_rel] : nothing,
            d[!, :time],
            time_window,
            inv_sr_ms,
            inv_ppd,
        )
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :saccade_idx => col_idx)
    push!(pairs_out, :duration => col_dur)
    push!(pairs_out, :start_x => col_sx)
    push!(pairs_out, :start_y => col_sy)
    push!(pairs_out, :end_x => col_ex)
    push!(pairs_out, :end_y => col_ey)
    push!(pairs_out, :amplitude_deg => col_ampl)
    push!(pairs_out, :peak_velocity => col_pvel)
    push!(pairs_out, :max_curvature_px => col_curv)
    push!(pairs_out, :curvature_ratio => col_ratio)
    return DataFrame(pairs_out; copycols = false)
end
