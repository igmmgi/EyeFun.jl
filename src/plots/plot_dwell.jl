# ── plot_dwell ─────────────────────────────────────────────────────────────── #

"""
    plot_dwell(df::EyeData, aois::Vector{<:AOI};
               selection=nothing, eye=:auto)

Bar chart of dwell time (ms) per Area of Interest.

# Example
```julia
aois = [RectAOI("Face", 600, 400, 400, 400), CircleAOI("Cross", 640, 480, 50)]
plot_dwell(df, aois; selection=(trial=1,))
```
"""
function plot_dwell(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    gx, gy, _ = _select_eye(samples, eye)

    valid = .!isnan.(gx) .& .!isnan.(gy)
    px = Float64.(gx[valid])
    py = Float64.(gy[valid])

    aoi_names = [a.name for a in aois]
    dwell_ms = Float64[]
    colors = Makie.wong_colors()

    for aoi in aois
        count = sum(in_aoi(aoi, px[i], py[i]) for i in eachindex(px))
        push!(dwell_ms, count / df.sample_rate * 1000.0)
    end

    fig = Figure(size = (500, 400))
    ax = Axis(
        fig[1, 1];
        xlabel = "AOI",
        ylabel = "Dwell time (ms)",
        title = _format_title("Dwell Time", selection),
        xticks = (1:length(aoi_names), aoi_names),
    )

    barcolors = [colors[mod1(i, length(colors))] for i = 1:length(aoi_names)]
    barplot!(ax, 1:length(aoi_names), dwell_ms; color = barcolors)

    return fig
end
