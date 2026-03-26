# ── plot_pupil ─────────────────────────────────────────────────────────────── #

"""
    plot_pupil(df::EyeData; selection=nothing, eye=:auto)

Plot pupil size over time. Shades blink periods in gray.

Uses `time_rel` for X axis if available, otherwise absolute time offset.
"""
function plot_pupil(df::EyeData; selection = nothing, eye::Symbol = :auto, facet = nothing)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    if facet !== nothing
        hasproperty(samples, facet) || error("Column :$facet not found for faceting.")
        groups = filter(r -> !ismissing(r[facet]), samples)
        facet_vals = sort(unique(groups[!, facet]))
    else
        groups = samples
        facet_vals = [nothing]
    end
    n_panels = length(facet_vals)
    n_panels == 0 && error("No non-missing values in :$facet for faceting.")

    title = _format_title("Pupil", selection)

    panel_w = facet !== nothing ? 450 : 900
    fig_w = facet !== nothing ? (panel_w * n_panels + 50) : panel_w
    fig_h = 400
    fig = Figure(size = (fig_w, fig_h))

    for (idx, fval) in enumerate(facet_vals)
        sub_facet = fval === nothing ? groups : filter(r -> r[facet] == fval, groups)

        # Use shared helpers for eye resolution
        resolved_eye = _resolve_eye(sub_facet, eye; cols = :pupil)
        pa_col = _eye_columns(resolved_eye).pa
        pa = Float64.(sub_facet[!, pa_col])

        # Time axis — only use time_rel when a selection is active
        use_rel =
            selection !== nothing &&
            hasproperty(sub_facet, :time_rel) &&
            !all(ismissing, sub_facet.time_rel)

        ax = Axis(
            fig[1, idx];
            xlabel = "Time (ms)",
            ylabel = idx == 1 ? "Pupil size" : "",
            title = fval === nothing ? title : "$fval",
        )

        global_t0 = Float64(sub_facet.time[1])
        function _get_trial_tp(sub)
            pa_sub = Float64.(sub[!, pa_col])
            if use_rel && !all(ismissing, sub.time_rel)
                t_sub = Float64[ismissing(v) ? NaN : Float64(v) for v in sub.time_rel]
            else
                t_sub = Float64.(sub.time) .- global_t0
            end
            return t_sub, pa_sub
        end

        # Draw per-trial to avoid connecting lines between trials
        has_trials = hasproperty(sub_facet, :trial)
        if has_trials && length(unique(skipmissing(sub_facet.trial))) > 1
            trial_data = filter(r -> !ismissing(r.trial), sub_facet)
            for g_df in groupby(trial_data, :trial)
                sub_t = DataFrame(g_df)
                t_sub, pa_sub = _get_trial_tp(sub_t)
                _shade_blinks!(ax, sub_t, t_sub)
                lines!(ax, t_sub, pa_sub; color = :black, linewidth = 0.5)
            end
        else
            if use_rel
                t = Float64[ismissing(v) ? NaN : Float64(v) for v in sub_facet.time_rel]
            else
                time_ms = Float64.(sub_facet.time)
                t = time_ms .- time_ms[1]
            end
            _shade_blinks!(ax, sub_facet, t)
            lines!(ax, t, pa; color = :black, linewidth = 0.5)
        end
    end

    return fig
end

"""Shade blink periods on an axis as gray vertical bands."""
function _shade_blinks!(ax, samples, t::Vector{Float64})
    !hasproperty(samples, :in_blink) && return
    bm = samples.in_blink
    i = 1
    while i <= length(bm)
        if bm[i]
            j = i
            while j <= length(bm) && bm[j]
                j += 1
            end
            Makie.vspan!(ax, [t[i]], [t[min(j, length(t))]]; color = (:gray, 0.15))
            i = j
        else
            i += 1
        end
    end
end
