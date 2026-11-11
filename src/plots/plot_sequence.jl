function _collect_event_rects!(
    rects::Vector{Rect2f},
    event_col::AbstractVector{Bool},
    t_vec::Vector{Float64},
    dt_ms::Float64,
    y_lo::Float32,
    y_h::Float32,
)
    n = length(event_col)
    i = 1
    @inbounds while i <= n
        if event_col[i]
            j = i + 1
            while j <= n && event_col[j]
                j += 1
            end
            t_start = t_vec[i]
            t_stop = j <= n ? t_vec[j] : (t_vec[n] + dt_ms)
            if !isnan(t_start) && !isnan(t_stop)
                w = max(Float32(t_stop - t_start), Float32(max(dt_ms * 0.5, 1e-3)))
                push!(rects, Rect2f(Float32(t_start), y_lo, w, y_h))
            end
            i = j
        else
            i += 1
        end
    end
    return rects
end

"""
    plot_sequence(df::EyeData; selection=nothing, group_by=:auto, max_trials=20, prefix=nothing)

Event sequence chart showing fixation, saccade, and blink periods as
horizontal color bars for each trial.

Green = fixation, blue = saccade, red = blink, gray = tracking loss.

# Example
```julia
plot_sequence(df; selection=(trial=1:10,))
plot_sequence(df; group_by=[:block, :trial], max_trials=15)
```
"""
function plot_sequence(
    df::EyeData;
    selection = nothing,
    group_by = :auto,
    max_trials::Int = 20,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)
    n_groups = min(length(grouped), max_trials)
    sr = df.sample_rate
    dt_ms = sr > 0.0 ? 1000.0 / sr : 1.0
    c_infix = _prefixed_sym(prefix, :in_fix)
    c_insacc = _prefixed_sym(prefix, :in_sacc)
    c_inblink = _prefixed_sym(prefix, :in_blink)

    labels = Vector{String}(undef, n_groups)
    for gi = 1:n_groups
        g = grouped[gi]
        vals = [first(g[!, c]) for c in group_cols]
        labels[gi] = join(["$(v)" for v in vals], "/")
    end

    fig = Figure(size = (900, max(300, n_groups * 30 + 80)))
    ax = Axis(
        fig[1, 1];
        xlabel = "Time (ms)",
        ylabel = "",
        title = _format_title("Event Sequence", selection),
        yticks = (1:n_groups, labels),
    )

    bg_rects = Rect2f[]
    fix_rects = Rect2f[]
    sacc_rects = Rect2f[]
    blink_rects = Rect2f[]
    bar_h = 0.7f0

    for gi = 1:n_groups
        g = grouped[gi]
        nsamp = nrow(g)
        nsamp == 0 && continue
        t_vec = _trial_relative_time(g; has_active_trel = false)

        t_lo = NaN
        t_hi = NaN
        @inbounds for tv in t_vec
            if !isnan(tv)
                isnan(t_lo) && (t_lo = tv)
                t_hi = tv
            end
        end
        if isnan(t_lo)
            t_lo = 0.0
            t_hi = (nsamp - 1) * dt_ms
        end

        y_lo = Float32(gi) - 0.35f0
        push!(
            bg_rects,
            Rect2f(Float32(t_lo), y_lo, max(Float32(t_hi - t_lo + dt_ms), 1.0f-3), bar_h),
        )

        hasproperty(g, c_infix) &&
            _collect_event_rects!(fix_rects, g[!, c_infix], t_vec, dt_ms, y_lo, bar_h)
        hasproperty(g, c_insacc) &&
            _collect_event_rects!(sacc_rects, g[!, c_insacc], t_vec, dt_ms, y_lo, bar_h)
        hasproperty(g, c_inblink) &&
            _collect_event_rects!(blink_rects, g[!, c_inblink], t_vec, dt_ms, y_lo, bar_h)
    end

    !isempty(bg_rects) && poly!(ax, bg_rects; color = (:gray80, 0.5))
    !isempty(fix_rects) && poly!(ax, fix_rects; color = (:green, 0.7))
    !isempty(sacc_rects) && poly!(ax, sacc_rects; color = (:dodgerblue, 0.7))
    !isempty(blink_rects) && poly!(ax, blink_rects; color = (:red, 0.6))

    elem_fix = PolyElement(color = (:green, 0.7))
    elem_sacc = PolyElement(color = (:dodgerblue, 0.7))
    elem_blink = PolyElement(color = (:red, 0.6))
    Legend(
        fig[2, 1],
        [elem_fix, elem_sacc, elem_blink],
        ["Fixation", "Saccade", "Blink"];
        orientation = :horizontal,
        tellheight = true,
        tellwidth = false,
    )

    return fig
end
