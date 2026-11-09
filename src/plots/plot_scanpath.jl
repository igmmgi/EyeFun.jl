"""
    plot_scanpath(df::EyeData; selection=nothing, eye=:auto, screen=nothing,
                  xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                  split_by=nothing, aois=nothing, prefix=nothing)

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
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    groups, split_vals, n_panels = _prepare_split_panels(samples, split_by; max_panels = 4)
    title = _format_title("Scanpath", selection)

    aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
    fig =
        _create_split_figure(split_by, n_panels; panel_w = 400, aspect_ratio = aspect_ratio)

    for (idx, fval) in enumerate(split_vals)
        sub = _panel_view(groups, split_by, fval)

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

        gcols = _plot_trial_group_cols(sub)
        gd = !isempty(gcols) ? groupby(sub, gcols; skipmissing = true) : nothing
        if !isnothing(gd) && length(gd) > 1
            lx = Float64[]
            ly = Float64[]
            st_x = Float64[]
            st_y = Float64[]
            en_x = Float64[]
            en_y = Float64[]
            for g in gd
                gx_t, gy_t, _ = _select_eye(g, eye)
                tx, ty = _extract_valid_xy(gx_t, gy_t)
                isempty(tx) && continue
                if !isempty(lx)
                    push!(lx, NaN)
                    push!(ly, NaN)
                end
                append!(lx, tx)
                append!(ly, ty)
                push!(st_x, tx[1])
                push!(st_y, ty[1])
                push!(en_x, tx[end])
                push!(en_y, ty[end])
            end
            if !isempty(lx)
                lines!(ax, lx, ly; color = :black, linewidth = 0.5)
                scatter!(
                    ax,
                    st_x,
                    st_y;
                    color = :green,
                    markersize = 8,
                    label = idx == 1 ? "Start" : nothing,
                )
                scatter!(
                    ax,
                    en_x,
                    en_y;
                    color = :red,
                    markersize = 8,
                    label = idx == 1 ? "End" : nothing,
                )
                idx == 1 && axislegend(ax; position = :rt)
            end
        else
            gx, gy, _ = _select_eye(sub, eye)
            px, py = _extract_valid_xy(gx, gy)
            lines!(ax, px, py; color = :black, linewidth = 0.5)
            if !isempty(px)
                scatter!(
                    ax,
                    [px[1]],
                    [py[1]];
                    color = :green,
                    markersize = 10,
                    label = idx == 1 ? "Start" : nothing,
                )
                scatter!(
                    ax,
                    [px[end]],
                    [py[end]];
                    color = :red,
                    markersize = 10,
                    label = idx == 1 ? "End" : nothing,
                )
                idx == 1 && axislegend(ax; position = :rt)
            end
        end

        if !isnothing(prefix)
            c_infix = _prefixed_sym(prefix, :in_fix)
            c_fgx = _prefixed_sym(prefix, :fix_gavx)
            c_fgy = _prefixed_sym(prefix, :fix_gavy)
            if hasproperty(sub, c_infix) && hasproperty(sub, c_fgx) && hasproperty(sub, c_fgy)
                ux, uy = _extract_unique_fix_xy(sub, sub[!, c_infix], sub[!, c_fgx], sub[!, c_fgy])
                !isempty(ux) && scatter!(ax, ux, uy; color = (:steelblue, 0.55), markersize = 9)
            end
        end

        !isnothing(aois) && _draw_aois!(ax, aois)
    end

    return fig
end
