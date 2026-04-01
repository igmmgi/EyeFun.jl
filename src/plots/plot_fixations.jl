# ── plot_fixations ─────────────────────────────────────────────────────────── #

"""
    plot_fixations(df::EyeData; selection=nothing, eye=:auto,
                   xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                   numbered=true, screen=nothing, split_by=nothing, aois=nothing)

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
    split_by = nothing,
    aois = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    hasproperty(samples, :fix_gavx) || error(
        "No fixation columns (fix_gavx). Ensure your DataFrame includes fixation annotations.",
    )

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

    title = _format_title("Fixations", selection)

    aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
    panel_w = !isnothing(split_by) ? 400 : round(Int, 650 * aspect_ratio)
    panel_h = !isnothing(split_by) ? round(Int, panel_w / aspect_ratio) : 650
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

        # Zero-allocation pass to extract unique fixations
        fx, fy, fdur = Float64[], Float64[], Float64[]
        if hasproperty(sub, :fix_gavx)
            in_fix = sub.in_fix
            fix_gx = sub.fix_gavx
            fix_gy = sub.fix_gavy
            fix_dur = sub.fix_dur
            
            for i in 1:nrow(sub)
                in_fix[i] || continue
                gx, gy = Float64(fix_gx[i]), Float64(fix_gy[i])
                isnan(gx) && continue
                isnan(gy) && continue
                
                dur = Float64(fix_dur[i])
                if isempty(fx) || gx != fx[end] || gy != fy[end]
                    push!(fx, gx)
                    push!(fy, gy)
                    push!(fdur, dur)
                end
            end
        end
        
        if length(fx) > 0

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

        !isnothing(aois) && _draw_aois!(ax, aois)
    end

    return fig
end
