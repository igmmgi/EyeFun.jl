# ── plot_velocity ──────────────────────────────────────────────────────────── #

"""
    plot_velocity(df::EyeData; selection=nothing)

Plot saccade peak velocity over time as stem markers.
"""
function plot_velocity(df::EyeData; selection = nothing, facet = nothing)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    hasproperty(samples, :sacc_pvel) || error(
        "No saccade columns (sacc_pvel). Ensure your DataFrame includes saccade annotations.",
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

    title = _format_title("Saccade Velocity", selection)

    panel_w = facet !== nothing ? 450 : 900
    fig_w = facet !== nothing ? (panel_w * n_panels + 50) : panel_w
    fig_h = 400
    fig = Figure(size = (fig_w, fig_h))

    for (idx, fval) in enumerate(facet_vals)
        sub_facet = fval === nothing ? groups : filter(r -> r[facet] == fval, groups)

        # Extract unique saccades
        sacc_rows = filter(r -> r.in_sacc == true && !isnan(r.sacc_pvel), sub_facet)

        t_mid, pvel = Float64[], Float64[]
        use_rel = selection !== nothing &&
                  hasproperty(sacc_rows, :time_rel) &&
                  !all(ismissing, sacc_rows.time_rel)

        prev_stx = NaN
        for r in eachrow(sacc_rows)
            stx = Float64(r.sacc_gstx)
            if stx != prev_stx
                if use_rel && !ismissing(r.time_rel)
                    push!(t_mid, Float64(r.time_rel))
                else
                    push!(t_mid, Float64(r.time))
                end
                push!(pvel, Float64(r.sacc_pvel))
                prev_stx = stx
            end
        end

        ax = Axis(
            fig[1, idx];
            xlabel = "Time (ms)",
            ylabel = idx == 1 ? "Peak velocity (°/s)" : "",
            title = fval === nothing ? title : "$fval",
        )

        # Stem markers: vectorized vertical lines from 0 to velocity
        if !isempty(t_mid)
            slx = Float64[]
            sly = Float64[]
            for i in eachindex(t_mid)
                push!(slx, t_mid[i], t_mid[i], NaN)
                push!(sly, 0.0, pvel[i], NaN)
            end
            lines!(ax, slx, sly; color = :black, linewidth = 1.5)
            scatter!(
                ax,
                t_mid,
                pvel;
                color = :black,
                markersize = 10,
                strokewidth = 1,
                strokecolor = :black,
            )
        end
    end

    return fig
end
