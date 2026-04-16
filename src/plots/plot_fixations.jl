# ── plot_fixations ─────────────────────────────────────────────────────────── #

"""
    plot_fixations(df::EyeData; selection=nothing,
                   xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                   numbered=true, screen=nothing, split_by=nothing, aois=nothing)

Plot fixation locations as circles sized by duration, optionally numbered.

Requires a DataFrame with fixation columns (`:in_fix`, `:fix_gavx`, `:fix_gavy`, `:fix_dur`).
"""
function plot_fixations(
    df::EyeData;
    selection = nothing,
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

    groups, split_vals, n_panels = _prepare_split_panels(samples, split_by; max_panels = 4)
    title = _format_title("Fixations", selection)

    aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
    fig =
        _create_split_figure(split_by, n_panels; panel_w = 400, aspect_ratio = aspect_ratio)

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

            for i = 1:nrow(sub)
                in_fix[i] || continue
                # Detect fixation onset: first sample of a new fixation run
                i > 1 && in_fix[i-1] && continue
                fix_x, fix_y = Float64(fix_gx[i]), Float64(fix_gy[i])
                isnan(fix_x) && continue
                isnan(fix_y) && continue

                dur = Float64(fix_dur[i])
                push!(fx, fix_x)
                push!(fy, fix_y)
                push!(fdur, dur)
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
