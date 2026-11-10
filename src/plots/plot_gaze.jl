function _build_gaze_panel_traces(
    sub::AbstractDataFrame,
    gx::AbstractVector,
    gy::AbstractVector,
    use_rel::Bool,
)
    n = nrow(sub)
    times = sub[!, :time]
    trel = use_rel ? sub[!, :time_rel] : nothing
    tr_col = hasproperty(sub, :trial) ? sub[!, :trial] : nothing
    p_col = _has_multiple_participants(sub) ? sub[!, :participant] : nothing

    cap = n + 32
    tx_buf = sizehint!(Float64[], cap)
    gx_buf = sizehint!(Float64[], cap)
    gy_buf = sizehint!(Float64[], cap)

    part_t0 = Float64(times[1])
    @inbounds for i = 1:n
        if i > 1 && _is_new_plot_trial(tr_col, p_col, times, i) && !isempty(tx_buf)
            push!(tx_buf, NaN)
            push!(gx_buf, NaN)
            push!(gy_buf, NaN)
        end
        tv, part_t0 = _plot_sample_time(times, trel, p_col, i, part_t0)
        push!(tx_buf, tv)
        push!(gx_buf, ismissing(gx[i]) ? NaN : Float64(gx[i]))
        push!(gy_buf, ismissing(gy[i]) ? NaN : Float64(gy[i]))
    end
    return tx_buf, gx_buf, gy_buf
end

"""
    plot_gaze(df::EyeData; selection=nothing, eye=:auto, xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down, split_by=nothing)

Plot gaze from a wide DataFrame with eye-tracking columns.
Uses `time_rel` for the X axis if present, otherwise elapsed time offset.
"""
function plot_gaze(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    xlims = (0, df.screen_res[1]),
    ylims = (0, df.screen_res[2]),
    ydir::Symbol = :down,
    split_by = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    groups, split_vals, n_panels = _prepare_split_panels(samples, split_by; max_panels = 4)
    title = _format_title("Gaze", selection)
    fig = _create_split_figure(split_by, n_panels; panel_w = 450, fig_h = 500)

    for (idx, fval) in enumerate(split_vals)
        sub = _panel_view(groups, split_by, fval)
        gx, gy, _ = _select_eye(sub, eye)
        use_rel = _has_active_time_rel(sub)

        ax1 = Axis(
            fig[1, idx];
            ylabel = idx == 1 ? "Gaze X (px)" : "",
            title = isnothing(fval) ? title : "$fval",
            xticklabelsvisible = false,
        )
        Makie.ylims!(ax1, xlims...)

        ax2 =
            Axis(fig[2, idx]; xlabel = "Time (ms)", ylabel = idx == 1 ? "Gaze Y (px)" : "")
        Makie.ylims!(ax2, ylims...)
        ax2.yreversed = (ydir == :down)

        tx_buf, gx_buf, gy_buf = _build_gaze_panel_traces(sub, gx, gy, use_rel)
        lines!(ax1, tx_buf, gx_buf; color = :black, linewidth = 0.5)
        lines!(ax2, tx_buf, gy_buf; color = :black, linewidth = 0.5)

        linkxaxes!(ax1, ax2)
    end
    rowgap!(fig.layout, 5)

    return fig
end
