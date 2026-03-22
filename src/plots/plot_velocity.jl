# ── plot_velocity ──────────────────────────────────────────────────────────── #

"""
    plot_velocity(df::EyeData; selection=nothing)

Plot saccade peak velocity over time as stem markers.
"""
function plot_velocity(df::EyeData; selection = nothing)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    hasproperty(samples, :sacc_pvel) || error(
        "No saccade columns (sacc_pvel). Ensure your DataFrame includes saccade annotations.",
    )

    # Extract unique saccades
    sacc_rows = filter(r -> r.in_sacc == true && !isnan(r.sacc_pvel), samples)
    nrow(sacc_rows) == 0 && error("No saccades found in selection.")

    # Deduplicate
    t_mid, pvel = Float64[], Float64[]
    has_rel = hasproperty(sacc_rows, :time_rel)

    prev_stx = NaN
    for r in eachrow(sacc_rows)
        stx = Float64(r.sacc_gstx)
        if stx != prev_stx
            if has_rel && !ismissing(r.time_rel)
                push!(t_mid, Float64(r.time_rel))
            else
                push!(t_mid, Float64(r.time))
            end
            push!(pvel, Float64(r.sacc_pvel))
            prev_stx = stx
        end
    end

    title_sel = selection !== nothing ? " ($selection)" : ""
    t_label =
        has_rel && !all(ismissing, sacc_rows.time_rel) ? "Time (ms, relative)" : "Time (ms)"

    fig = Figure(size = (900, 400))
    ax = Axis(
        fig[1, 1];
        xlabel = t_label,
        ylabel = "Peak velocity (°/s)",
        title = "Saccade velocity$title_sel",
    )

    # Stem markers: vertical lines from 0 to velocity
    for i in eachindex(t_mid)
        lines!(
            ax,
            [t_mid[i], t_mid[i]],
            [0.0, pvel[i]];
            color = :steelblue,
            linewidth = 1.5,
        )
    end
    scatter!(
        ax,
        t_mid,
        pvel;
        color = :steelblue,
        markersize = 10,
        strokewidth = 1,
        strokecolor = :black,
    )

    return fig
end
