# ── plot_fixations ─────────────────────────────────────────────────────────── #

"""
    plot_fixations(df::EyeData; selection=nothing, eye=:auto,
                   xlims=(0,1280), ylims=(0,960), ydir=:down,
                   numbered=true, screen=nothing)

Plot fixation locations as circles sized by duration, optionally numbered.

Requires a DataFrame with fixation columns (`:in_fix`, `:fix_gavx`, `:fix_gavy`, `:fix_dur`).
"""
function plot_fixations(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    xlims = (0, 1280),
    ylims = (0, 960),
    ydir::Symbol = :down,
    numbered::Bool = true,
    screen = nothing,
    aois = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    hasproperty(samples, :fix_gavx) || error(
        "No fixation columns (fix_gavx). Ensure your DataFrame includes fixation annotations.",
    )

    # Extract unique fixations
    fix_rows =
        filter(r -> r.in_fix == true && !isnan(r.fix_gavx) && !isnan(r.fix_gavy), samples)
    nrow(fix_rows) == 0 && error("No fixations found in selection.")

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

    title_sel = selection !== nothing ? " ($selection)" : ""
    title = "Fixations$title_sel"

    fig = Figure(size = (800, 650))
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

    # Scanpath line connecting fixations
    lines!(ax, fx, fy; color = (:black, 0.3), linewidth = 0.5)

    # Fixation circles sized by duration
    max_dur = maximum(fdur)
    sizes = fdur ./ max_dur .* 40 .+ 5  # scale to 5–45 pts
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

    aois !== nothing && _draw_aois!(ax, aois)
    return fig
end
