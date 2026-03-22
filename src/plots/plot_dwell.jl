# ── plot_dwell ─────────────────────────────────────────────────────────────── #

"""
    plot_dwell(df::EyeData, aois::Dict{String, Tuple};
               selection=nothing, eye=:auto)

Bar chart of dwell time (ms) per Area of Interest.

`aois` is a Dict mapping AOI names to `(x_min, y_min, x_max, y_max)` rectangles.

# Example
```julia
aois = Dict("Face" => (400, 200, 800, 600), "Object" => (100, 100, 300, 400))
plot_dwell(df, aois; selection=(trial=1,))
```
"""
function plot_dwell(
    df::EyeData,
    aois::Dict{String,<:Tuple};
    selection = nothing,
    eye::Symbol = :auto,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    gx, gy, eye_label = _select_eye(samples, eye)

    valid = .!isnan.(gx) .& .!isnan.(gy)
    px = Float64.(gx[valid])
    py = Float64.(gy[valid])

    aoi_names = sort(collect(keys(aois)))
    dwell_ms = Float64[]
    colors = Makie.wong_colors()

    for name in aoi_names
        x1, y1, x2, y2 = aois[name]
        count = sum((px .>= x1) .& (px .<= x2) .& (py .>= y1) .& (py .<= y2))
        push!(dwell_ms, Float64(count))  # at 1 kHz, count ≈ ms
    end

    title_sel = selection !== nothing ? " ($selection)" : ""

    fig = Figure(size = (500, 400))
    ax = Axis(
        fig[1, 1];
        xlabel = "AOI",
        ylabel = "Dwell time (ms)",
        title = "Dwell Time$title_sel ($eye_label)",
        xticks = (1:length(aoi_names), aoi_names),
    )

    barcolors = [colors[mod1(i, length(colors))] for i = 1:length(aoi_names)]
    barplot!(ax, 1:length(aoi_names), dwell_ms; color = barcolors)

    return fig
end
