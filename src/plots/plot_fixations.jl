# ── plot_fixations ─────────────────────────────────────────────────────────── #

"""
    plot_fixations(df::EyeData; selection=nothing, eye=:auto,
                   xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                   numbered=true, screen=nothing, facet=nothing, aois=nothing)

Plot fixation locations as circles sized by duration, optionally numbered.

Requires a DataFrame with fixation columns (`:in_fix`, `:fix_gavx`, `:fix_gavy`, `:fix_dur`).
"""
function plot_fixations(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    xlims = (0, df.screen_res[1]),
    ylims = (0, df.screen_res[2]),
    ydir::Symbol = :down,
    numbered::Bool = true,
    screen = nothing,
    facet = nothing,
    aois = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    hasproperty(samples, :fix_gavx) || error(
        "No fixation columns (fix_gavx). Ensure your DataFrame includes fixation annotations.",
    )

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

    title = _format_title("Fixations", selection)

    aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
    panel_w = facet !== nothing ? 400 : round(Int, 650 * aspect_ratio)
    panel_h = facet !== nothing ? round(Int, panel_w / aspect_ratio) : 650
    fig_w = facet !== nothing ? (panel_w * n_panels + 50) : panel_w
    fig_h = facet !== nothing ? panel_h + 80 : panel_h
    fig = Figure(size = (fig_w, fig_h))

    for (idx, fval) in enumerate(facet_vals)
        sub = fval === nothing ? groups : filter(r -> r[facet] == fval, groups)

        ax = Axis(
            fig[1, idx];
            xlabel = "X (px)",
            ylabel = idx == 1 ? "Y (px)" : "",
            title = fval === nothing ? title : "$fval",
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

        fix_rows =
            filter(r -> r.in_fix == true && !isnan(r.fix_gavx) && !isnan(r.fix_gavy), sub)
        if nrow(fix_rows) > 0
            # Deduplicate consecutive identical fixation centers
            fx, fy, fdur = Float64[], Float64[], Float64[]
            for r in eachrow(fix_rows)
                gx, gy, dur = Float64(r.fix_gavx), Float64(r.fix_gavy), Float64(r.fix_dur)
                if isempty(fx) || gx != fx[end] || gy != fy[end]
                    push!(fx, gx);
                    push!(fy, gy);
                    push!(fdur, dur)
                end
            end

            # Scanpath line connecting fixations
            lines!(ax, fx, fy; color = (:black, 0.3), linewidth = 0.5)

            # Fixation circles sized by duration
            max_dur = maximum(fdur)
            sizes = max_dur > 0 ? (fdur ./ max_dur .* 40 .+ 5) : fill(10.0, length(fdur))
            scatter!(
                ax,
                fx,
                fy;
                markersize = sizes,
                color = (:steelblue, 0.5),
                strokewidth = 1,
                strokecolor = :steelblue,
            )

            # Number fixations
            if numbered
                for i in eachindex(fx)
                    Makie.text!(
                        ax,
                        fx[i],
                        fy[i];
                        text = string(i),
                        align = (:center, :center),
                        fontsize = 9,
                        color = :white,
                    )
                end
            end
        end

        aois !== nothing && _draw_aois!(ax, aois)
    end

    return fig
end
