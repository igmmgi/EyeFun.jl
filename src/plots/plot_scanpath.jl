# ── plot_scanpath ──────────────────────────────────────────────────────────── #

"""
    plot_scanpath(df::EyeData; selection=nothing, eye=:auto, screen=nothing,
                  xlims=(0,1280), ylims=(0,960), ydir=:down)

Plot scanpath from a wide DataFrame.
"""
function plot_scanpath(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    screen = nothing,
    xlims = (0, 1280),
    ylims = (0, 960),
    ydir::Symbol = :down,
    aois = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    gx, gy, eye_label = _select_eye(samples, eye)

    valid = .!isnan.(gx) .& .!isnan.(gy)
    px = Float64.(gx[valid])
    py = Float64.(gy[valid])

    title_sel = selection !== nothing ? " ($selection)" : ""
    title = "Scanpath$title_sel ($eye_label)"

    fig = Figure(size = (700, 600))
    ax = Axis(
        fig[1, 1];
        xlabel = "X (px)",
        ylabel = "Y (px)",
        title = title,
        aspect = DataAspect(),
    )
    Makie.xlims!(ax, xlims...)
    Makie.ylims!(ax, ylims...)
    ax.yreversed = (ydir == :down)

    if screen !== nothing
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
    has_trials = hasproperty(samples, :trial)
    trial_subset = has_trials ? filter(r -> !ismissing(r.trial), samples) : samples
    if has_trials && length(unique(skipmissing(samples.trial))) > 1
        first_trial = true
        for g in groupby(trial_subset, :trial)
            gx_t, gy_t, _ = _select_eye(DataFrame(g), eye)
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
        axislegend(ax; position = :rt)
    else
        lines!(ax, px, py; color = :black, linewidth = 0.5)
        if length(px) > 0
            scatter!(ax, [px[1]], [py[1]]; color = :green, markersize = 10, label = "Start")
            scatter!(ax, [px[end]], [py[end]]; color = :red, markersize = 10, label = "End")
            axislegend(ax; position = :rt)
        end
    end

    aois !== nothing && _draw_aois!(ax, aois)
    return fig
end
