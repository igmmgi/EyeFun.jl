function _extract_fix_plot_vecs(
    sub::AbstractDataFrame,
    in_fix::AbstractVector{Bool},
    fix_gx::AbstractVector{<:Real},
    fix_gy::AbstractVector{<:Real},
    fix_dur::AbstractVector{<:Real},
)
    fx = Float64[]
    fy = Float64[]
    fdur = Float64[]
    lx = Float64[]
    ly = Float64[]

    tr_col = hasproperty(sub, :trial) ? sub[!, :trial] : nothing
    p_col = _has_multiple_participants(sub) ? sub[!, :participant] : nothing
    times = hasproperty(sub, :time) ? sub[!, :time] : nothing

    prev = false
    need_break = false
    @inbounds for i in eachindex(in_fix)
        if _is_new_plot_trial(tr_col, p_col, times, i)
            prev = false
            !isempty(lx) && (need_break = true)
        end
        cur = in_fix[i]
        if cur & !prev
            x = Float64(fix_gx[i])
            y = Float64(fix_gy[i])
            if !isnan(x) && !isnan(y)
                if need_break
                    push!(lx, NaN)
                    push!(ly, NaN)
                    need_break = false
                end
                push!(fx, x)
                push!(fy, y)
                push!(fdur, Float64(fix_dur[i]))
                push!(lx, x)
                push!(ly, y)
            end
        end
        prev = cur
    end
    return fx, fy, fdur, lx, ly
end

"""
    plot_fixations(df::EyeData; selection=nothing,
                   xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                   numbered=true, screen=nothing, split_by=nothing, aois=nothing, prefix=nothing)

Plot fixation locations as circles sized by duration, optionally numbered.
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
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fgy = _prefixed_sym(prefix, :fix_gavy)
    c_fdur = _prefixed_sym(prefix, :fix_dur)
    hasproperty(samples, c_fgx) || error(
        "No fixation columns ($c_fgx). Run detect_events!(df) first.",
    )

    groups, split_vals, n_panels = _prepare_split_panels(samples, split_by; max_panels = 4)
    title = _format_title("Fixations", selection)

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

        fx, fy, fdur, lx, ly = if hasproperty(sub, c_fgx) && hasproperty(sub, c_infix)
            _extract_fix_plot_vecs(
                sub,
                sub[!, c_infix],
                sub[!, c_fgx],
                sub[!, c_fgy],
                sub[!, c_fdur],
            )
        else
            (Float64[], Float64[], Float64[], Float64[], Float64[])
        end

        if !isempty(fx)
            lines!(ax, lx, ly; color = (:black, 0.3), linewidth = 0.5)

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

            if numbered
                labels = String[string(k) for k = 1:length(fx)]
                text!(
                    ax,
                    fx,
                    fy;
                    text = labels,
                    align = (:center, :center),
                    fontsize = 9,
                    color = :black,
                )
            end
        end

        !isnothing(aois) && _draw_aois!(ax, aois)
    end

    return fig
end
