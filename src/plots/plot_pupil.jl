"""
    plot_pupil(df::EyeData; selection=nothing, eye=:auto, split_by=nothing, prefix=nothing)

Plot pupil size over time. Shades blink periods in gray.
Uses `time_rel` for X axis if available, otherwise elapsed time offset.
"""
function plot_pupil(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    split_by = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    groups, split_vals, n_panels = _prepare_split_panels(samples, split_by; max_panels = 4)
    title = _format_title("Pupil", selection)
    fig = _create_split_figure(split_by, n_panels; panel_w = 450, fig_h = 400)
    c_blink = _prefixed_sym(prefix, :in_blink)
    dt_ms = df.sample_rate > 0.0 ? 1000.0 / df.sample_rate : 1.0

    for (idx, fval) in enumerate(split_vals)
        sub_split = _panel_view(groups, split_by, fval)
        resolved_eye = _resolve_eye(sub_split, eye; cols = :pupil)
        pa_raw = _get_pupil_vec(sub_split, resolved_eye)
        use_rel = _has_active_time_rel(sub_split)

        ax = Axis(
            fig[1, idx];
            xlabel = "Time (ms)",
            ylabel = idx == 1 ? "Pupil size" : "",
            title = isnothing(fval) ? title : "$fval",
        )

        n = nrow(sub_split)
        times = sub_split[!, :time]
        trel = use_rel ? sub_split[!, :time_rel] : nothing
        tr_col = hasproperty(sub_split, :trial) ? sub_split[!, :trial] : nothing
        p_col = _has_multiple_participants(sub_split) ? sub_split[!, :participant] : nothing
        bm = hasproperty(sub_split, c_blink) ? sub_split[!, c_blink] : nothing

        tx_buf = sizehint!(Float64[], n + 32)
        pa_buf = sizehint!(Float64[], n + 32)
        xlo = Float64[]
        xhi = Float64[]

        part_t0 = Float64(times[1])
        in_blk_run = false
        blk_t0 = 0.0
        prev_tv = 0.0

        @inbounds for i = 1:n
            new_seg = false
            if i > 1
                new_part = !isnothing(p_col) && !isequal(p_col[i], p_col[i-1])
                new_seg =
                    new_part ||
                    (!isnothing(tr_col) && !isequal(tr_col[i], tr_col[i-1])) ||
                    (Float64(times[i]) < Float64(times[i-1]))
                if new_part || Float64(times[i]) < Float64(times[i-1])
                    part_t0 = Float64(times[i])
                end
            end

            if new_seg
                if in_blk_run
                    !isnan(blk_t0) && !isnan(prev_tv) && begin
                        push!(xlo, blk_t0)
                        push!(xhi, max(blk_t0 + dt_ms, prev_tv))
                    end
                    in_blk_run = false
                end
                if !isempty(tx_buf)
                    push!(tx_buf, NaN)
                    push!(pa_buf, NaN)
                end
            end

            tv = if !isnothing(trel)
                rv = trel[i]
                ismissing(rv) ? NaN : Float64(rv)
            else
                Float64(times[i]) - part_t0
            end

            if !isnothing(bm)
                cur_b = bm[i] === true
                if cur_b && !in_blk_run
                    in_blk_run = true
                    blk_t0 = tv
                elseif !cur_b && in_blk_run
                    if !isnan(blk_t0)
                        hi_v = isnan(tv) ? prev_tv : tv
                        if !isnan(hi_v)
                            push!(xlo, blk_t0)
                            push!(xhi, max(blk_t0 + dt_ms, hi_v))
                        end
                    end
                    in_blk_run = false
                end
            end

            push!(tx_buf, tv)
            push!(pa_buf, ismissing(pa_raw[i]) ? NaN : Float64(pa_raw[i]))
            prev_tv = tv
        end

        if in_blk_run && !isnan(blk_t0) && !isnan(prev_tv)
            push!(xlo, blk_t0)
            push!(xhi, max(blk_t0 + dt_ms, prev_tv))
        end

        !isempty(xlo) && Makie.vspan!(ax, xlo, xhi; color = (:gray, 0.15))
        lines!(ax, tx_buf, pa_buf; color = :black, linewidth = 0.5)
    end

    return fig
end

"""Shade blink periods on an axis as gray vertical bands."""
function _shade_blinks!(ax, samples, t::Vector{Float64}, c_blink::Symbol = :in_blink)
    !hasproperty(samples, c_blink) && return
    bm = samples[!, c_blink]
    dt_ms = length(t) > 1 ? max(1e-3, (t[end] - t[1]) / max(1, length(t) - 1)) : 1.0
    xlo = Float64[]
    xhi = Float64[]
    n = length(bm)
    i = 1
    @inbounds while i <= n
        if bm[i]
            j = i + 1
            while j <= n && bm[j]
                j += 1
            end
            lo = t[i]
            hi = j <= length(t) ? t[j] : t[end]
            push!(xlo, lo)
            push!(xhi, max(lo + dt_ms, hi))
            i = j
        else
            i += 1
        end
    end
    !isempty(xlo) && Makie.vspan!(ax, xlo, xhi; color = (:gray, 0.15))
end
