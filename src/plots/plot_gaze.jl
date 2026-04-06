# ── plot_gaze ──────────────────────────────────────────────────────────────── #

"""
    plot_gaze(df::EyeData; selection=nothing, eye=:auto, xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down, split_by=nothing)

Plot gaze from a wide DataFrame with eye-tracking columns.
Uses `time_rel` for the X axis if present, otherwise absolute time offset.
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
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    if !isnothing(split_by)
        hasproperty(samples, split_by) ||
            error("Column :$split_by not found for splitting.")
        groups = filter(r -> !ismissing(r[split_by]), samples)
        split_vals = sort(unique(groups[!, split_by]))
    else
        groups = samples
        split_vals = [nothing]
    end
    n_panels = length(split_vals)
    n_panels == 0 && error("No non-missing values in :$split_by for splitting.")

    title = _format_title("Gaze", selection)

    panel_w = !isnothing(split_by) ? 450 : 900
    fig_w = !isnothing(split_by) ? (panel_w * n_panels + 50) : panel_w
    fig_h = 500
    fig = Figure(size = (fig_w, fig_h))

    use_rel =
        !isnothing(selection) &&
        hasproperty(samples, :time_rel) &&
        !all(ismissing, samples.time_rel)
    has_trials = hasproperty(samples, :trial)

    for (idx, fval) in enumerate(split_vals)
        sub = isnothing(fval) ? groups : filter(r -> r[split_by] == fval, groups)
        gx, gy, _ = _select_eye(sub, eye)

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

        # Draw per-trial to avoid connecting lines between trials
        if use_rel && has_trials && length(unique(skipmissing(sub.trial))) > 1
            trial_data = filter(r -> !ismissing(r.trial), sub)
            for g in groupby(trial_data, :trial)
                sub_t = DataFrame(g)
                gx_s, gy_s, _ = _select_eye(sub_t, eye)
                t_s = Float64[ismissing(v) ? NaN : Float64(v) for v in sub_t.time_rel]
                lines!(ax1, t_s, Float64.(gx_s); color = :black, linewidth = 0.5)
                lines!(ax2, t_s, Float64.(gy_s); color = :black, linewidth = 0.5)
            end
        else
            if use_rel
                t = Float64[ismissing(v) ? NaN : Float64(v) for v in sub.time_rel]
            else
                time_ms = Float64.(sub.time)
                t = time_ms .- time_ms[1]
            end
            lines!(ax1, t, Float64.(gx); color = :black, linewidth = 0.5)
            lines!(ax2, t, Float64.(gy); color = :black, linewidth = 0.5)
        end

        linkxaxes!(ax1, ax2)
    end
    rowgap!(fig.layout, 5)

    return fig
end
