function _first_fixation_offset(
    in_fix::AbstractVector{Bool},
    fx::AbstractVector{<:Real},
    fy::AbstractVector{<:Real},
    idxs::AbstractVector{Int},
    tx::Float64,
    ty::Float64,
)
    @inbounds for k in idxs
        if in_fix[k] && !isnan(fx[k]) && !isnan(fy[k])
            return Float64(fx[k]) - tx, Float64(fy[k]) - ty, true
        end
    end
    return 0.0, 0.0, false
end

function _window_mean_offset(
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    idxs::AbstractVector{Int},
    win_samples::Int,
    tx::Float64,
    ty::Float64,
)
    win = min(win_samples, length(idxs))
    sx, sy, c = 0.0, 0.0, 0
    @inbounds for j = 1:win
        k = idxs[j]
        xv, yv = Float64(gx[k]), Float64(gy[k])
        if !isnan(xv) && !isnan(yv)
            sx += xv
            sy += yv
            c += 1
        end
    end
    c == 0 && return 0.0, 0.0
    return sx / c - tx, sy / c - ty
end

function _window_time_offset(
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    times::AbstractVector{<:Real},
    trel::Union{Nothing,AbstractVector},
    idxs::AbstractVector{Int},
    t_lo::Float64,
    t_hi::Float64,
    tx::Float64,
    ty::Float64,
)
    isempty(idxs) && return 0.0, 0.0
    t0_grp = Float64(@inbounds times[idxs[1]])
    sx, sy, c = 0.0, 0.0, 0
    @inbounds for j in eachindex(idxs)
        k = idxs[j]
        tr = if !isnothing(trel)
            tv = trel[k]
            ismissing(tv) ? NaN : Float64(tv)
        else
            Float64(times[k]) - t0_grp
        end
        if t_lo <= tr <= t_hi
            xv, yv = Float64(gx[k]), Float64(gy[k])
            if !isnan(xv) && !isnan(yv)
                sx += xv
                sy += yv
                c += 1
            end
        end
    end
    c == 0 && return 0.0, 0.0
    return sx / c - tx, sy / c - ty
end

function _subtract_offset!(
    col::AbstractVector{T},
    idxs::AbstractVector{Int},
    offset::Float64,
) where {T<:AbstractFloat}
    off = T(offset)
    @inbounds for k in idxs
        col[k] -= off
    end
    return nothing
end

"""
    drift_correct!(df::EyeData; target=nothing, eye=:auto,
                   use_first_fixation=true, method=nothing,
                   window_ms=200, group_by=:auto, prefix=nothing)

Apply drift correction by computing the gaze offset from a known fixation
`target` at the start of each group and subtracting it from gaze, fixation,
and saccade coordinates.

# Keyword Arguments
- `target`: expected fixation position `(x, y)` (default: `nothing`, resolving to
  screen center `(screen_res[1] / 2, screen_res[2] / 2)` in pixels or `(0.0, 0.0)` in centered space)
- `use_first_fixation`: if `true` (default), uses the first fixation's center
  (requires `fix_gavx`/`fix_gavy` columns from event detection).
  If `false`, uses the mean gaze position in `window_ms`.
- `method`: optional `:first_fixation` or `:window` alias overriding `use_first_fixation`
- `window_ms`: duration of the averaging window in ms (`Real`, default `200`) or
  trial-relative `(t_start_ms, t_end_ms)` tuple
- `group_by`: grouping column(s) for per-trial correction (default: `:auto`, resolving to
  `[:participant, :trial]` for multi-participant data or `[:trial]` otherwise)
- `prefix`: optional event column prefix (e.g. `:ivt`)
"""
function drift_correct!(
    df::EyeData;
    target::Union{Nothing,Tuple{Real,Real}} = nothing,
    eye::Symbol = :auto,
    use_first_fixation::Bool = true,
    method::Union{Nothing,Symbol} = nothing,
    window_ms::Union{Real,Tuple{Real,Real}} = 200,
    group_by = :auto,
    prefix::Union{Nothing,Symbol} = nothing,
)
    use_ff = if isnothing(method)
        use_first_fixation && !(window_ms isa Tuple)
    elseif method === :first_fixation
        true
    elseif method === :window
        false
    else
        throw(ArgumentError("Invalid method=:$method. Expected :first_fixation or :window."))
    end

    d = df.df
    group_cols = _resolve_group_cols(df, group_by)
    grouped = groupby(d, group_cols; skipmissing = true)

    eye = _resolve_eye(df, eye)
    _ensure_eye_cols!(df, eye)
    ecols = _eye_columns(eye)
    gx_vec = d[!, ecols.gx]
    gy_vec = d[!, ecols.gy]
    in_cent = _is_col_centered(d, ecols.gx, df.coords)

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fgy = _prefixed_sym(prefix, :fix_gavy)
    c_ssx = _prefixed_sym(prefix, :sacc_gstx)
    c_ssy = _prefixed_sym(prefix, :sacc_gsty)
    c_sex = _prefixed_sym(prefix, :sacc_genx)
    c_sey = _prefixed_sym(prefix, :sacc_geny)

    has_fix = hasproperty(d, c_infix) && hasproperty(d, c_fgx) && hasproperty(d, c_fgy)
    in_fix_vec = has_fix ? d[!, c_infix] : nothing
    fix_x_vec = hasproperty(d, c_fgx) ? d[!, c_fgx] : nothing
    fix_y_vec = hasproperty(d, c_fgy) ? d[!, c_fgy] : nothing
    sacc_sx_vec = hasproperty(d, c_ssx) ? d[!, c_ssx] : nothing
    sacc_sy_vec = hasproperty(d, c_ssy) ? d[!, c_ssy] : nothing
    sacc_ex_vec = hasproperty(d, c_sex) ? d[!, c_sex] : nothing
    sacc_ey_vec = hasproperty(d, c_sey) ? d[!, c_sey] : nothing

    default_target = in_cent ? (0.0, 0.0) : (df.screen_res[1] / 2.0, df.screen_res[2] / 2.0)
    tx, ty = isnothing(target) ? default_target : (Float64(target[1]), Float64(target[2]))
    win_samples = window_ms isa Real ? round(Int, Float64(window_ms) / 1000.0 * df.sample_rate) : 0
    times_vec = hasproperty(d, :time) ? d[!, :time] : nothing
    trel_vec = _has_active_time_rel(d) ? d[!, :time_rel] : nothing

    for g in grouped
        idxs = parentindices(g)[1]

        offset_x, offset_y = 0.0, 0.0
        if use_ff && has_fix
            ox, oy, found =
                _first_fixation_offset(in_fix_vec, fix_x_vec, fix_y_vec, idxs, tx, ty)
            if found
                offset_x, offset_y = ox, oy
            end
        elseif window_ms isa Tuple && !isnothing(times_vec)
            offset_x, offset_y = _window_time_offset(
                gx_vec,
                gy_vec,
                times_vec,
                trel_vec,
                idxs,
                Float64(window_ms[1]),
                Float64(window_ms[2]),
                tx,
                ty,
            )
        else
            offset_x, offset_y =
                _window_mean_offset(gx_vec, gy_vec, idxs, win_samples, tx, ty)
        end

        if offset_x != 0.0 || offset_y != 0.0
            _subtract_offset!(gx_vec, idxs, offset_x)
            _subtract_offset!(gy_vec, idxs, offset_y)
            !isnothing(fix_x_vec) && _subtract_offset!(fix_x_vec, idxs, offset_x)
            !isnothing(fix_y_vec) && _subtract_offset!(fix_y_vec, idxs, offset_y)
            !isnothing(sacc_sx_vec) && _subtract_offset!(sacc_sx_vec, idxs, offset_x)
            !isnothing(sacc_sy_vec) && _subtract_offset!(sacc_sy_vec, idxs, offset_y)
            !isnothing(sacc_ex_vec) && _subtract_offset!(sacc_ex_vec, idxs, offset_x)
            !isnothing(sacc_ey_vec) && _subtract_offset!(sacc_ey_vec, idxs, offset_y)
        end
    end

    return df
end
