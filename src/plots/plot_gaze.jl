# ── plot_gaze ──────────────────────────────────────────────────────────────── #

"""
    plot_gaze(df::EyeData; selection=nothing, eye=:auto, xlims=(0,1280), ylims=(0,960), ydir=:down)

Plot gaze from a wide DataFrame with eye-tracking columns.
Uses `time_rel` for the X axis if present, otherwise absolute time offset.
"""
function plot_gaze(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    xlims = (0, 1280),
    ylims = (0, 960),
    ydir::Symbol = :down,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    gx, gy, eye_label = _select_eye(samples, eye)

    # Use time_rel if available, otherwise offset from first sample
    has_rel = hasproperty(samples, :time_rel)
    if has_rel && !all(ismissing, samples.time_rel)
        t = Float64[ismissing(v) ? NaN : Float64(v) for v in samples.time_rel]
        t_label = "Time (ms, relative)"
    else
        time_ms = Float64.(samples.time)
        t = time_ms .- time_ms[1]
        t_label = "Time (ms)"
    end

    title_sel = selection !== nothing ? " ($selection)" : ""
    title = "Gaze$title_sel ($eye_label)"

    fig = Figure(size = (900, 500))

    ax1 = Axis(fig[1, 1]; ylabel = "Gaze X (px)", title = title, xticklabelsvisible = false)
    Makie.ylims!(ax1, xlims...)
    lines!(ax1, t, Float64.(gx); color = :black, linewidth = 0.5)

    ax2 = Axis(fig[2, 1]; xlabel = t_label, ylabel = "Gaze Y (px)")
    Makie.ylims!(ax2, ylims...)
    lines!(ax2, t, Float64.(gy); color = :black, linewidth = 0.5)
    ax2.yreversed = (ydir == :down)

    linkxaxes!(ax1, ax2)
    rowgap!(fig.layout, 5)

    return fig
end
