# ── plot_scanpath ──────────────────────────────────────────────────────────── #

"""
    plot_scanpath(df::EyeData; selection=nothing, eye=:auto, screen=nothing,
                  xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                  split_by=nothing, aois=nothing)

Plot scanpath from a wide DataFrame.
"""
function plot_scanpath(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    screen = nothing,
    xlims = (0, df.screen_res[1]),
    ylims = (0, df.screen_res[2]),
    ydir::Symbol = :down,
    split_by = nothing,
    aois = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    if !isnothing(split_by)
        hasproperty(samples, split_by) || error("Column :$split_by not found for splitting.")
        groups = filter(r -> !ismissing(r[split_by]), samples)
        split_vals = sort(unique(groups[!, split_by]))
    else
        groups = samples
        split_vals = [nothing]
    end
    n_panels = length(split_vals)
    n_panels == 0 && error("No non-missing values in :$split_by for splitting.")

    title = _format_title("Scanpath", selection)

    aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
    panel_w = !isnothing(split_by) ? 400 : round(Int, 600 * aspect_ratio)
    panel_h = !isnothing(split_by) ? round(Int, panel_w / aspect_ratio) : 600
    fig_w = !isnothing(split_by) ? (panel_w * n_panels + 50) : panel_w
    fig_h = !isnothing(split_by) ? panel_h + 80 : panel_h
    fig = Figure(size = (fig_w, fig_h))

    for (idx, fval) in enumerate(split_vals)
        sub = isnothing(fval) ? groups : filter(r -> r[split_by] == fval, groups)

        ax = Axis(
            fig[1, idx];
            xlabel = "X (px)",
            ylabel = idx == 1 ? "Y (px)" : "",
            title = isnothing(fval) ? title : "$fval",
            aspect = DataAspect(),
        )
        Makie.xlims!(ax, xlims...)
        Makie.ylims!(ax, ylims...)
        ax.yreversed = (ydir == :down)

        if !isnothing(screen)
            w, h = screen
            lines!(
                ax,
                [0, w, w, 0, 0],
                [0, 0, h, h, 0];
                color = :gray70,
                linewidth = 1,
                linestyle = :dash,
            )
        end

        # Draw per-trial scanpaths with start/end markers
        has_trials = hasproperty(sub, :trial)
        trial_subset = has_trials ? filter(r -> !ismissing(r.trial), sub) : sub
        if has_trials && length(unique(skipmissing(sub.trial))) > 1
            first_trial = true
            for g in groupby(trial_subset, :trial)
                gx_t, gy_t, _ = _select_eye(g, eye)
                v = .!isnan.(gx_t) .& .!isnan.(gy_t)
                tx = Float64.(gx_t[v])
                ty = Float64.(gy_t[v])
                length(tx) == 0 && continue
                lines!(ax, tx, ty; color = :black, linewidth = 0.5)
                scatter!(
                    ax,
                    [tx[1]],
                    [ty[1]];
                    color = :green,
                    markersize = 8,
                    label = first_trial ? "Start" : nothing,
                )
                scatter!(
                    ax,
                    [tx[end]],
                    [ty[end]];
                    color = :red,
                    markersize = 8,
                    label = first_trial ? "End" : nothing,
                )
                first_trial = false
            end
            !first_trial && idx == 1 && axislegend(ax; position = :rt)
        else
            gx, gy, _ = _select_eye(sub, eye)
            valid = .!isnan.(gx) .& .!isnan.(gy)
            px = Float64.(gx[valid])
            py = Float64.(gy[valid])
            lines!(ax, px, py; color = :black, linewidth = 0.5)
            if length(px) > 0
                scatter!(
                    ax,
                    [px[1]],
                    [py[1]];
                    color = :green,
                    markersize = 10,
                    label = "Start",
                )
                scatter!(
                    ax,
                    [px[end]],
                    [py[end]];
                    color = :red,
                    markersize = 10,
                    label = "End",
                )
                idx == 1 && axislegend(ax; position = :rt)
            end
        end

        !isnothing(aois) && _draw_aois!(ax, aois)
    end

    return fig
end
