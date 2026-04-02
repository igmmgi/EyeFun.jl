# ── Transition Analysis & Plotting ─────────────────────────────────────────── #


"""
    plot_transitions(df::EyeData, aois::Vector{<:AOI};
                     selection=nothing, eye=:auto, normalize=true)

Plot an AOI transition probability heatmap.

# Example
```julia
aois = [RectAOI("Face", 400, 200, 800, 600), RectAOI("Text", 0, 700, 1280, 960)]
plot_transitions(df, aois; selection=(trial=1:10,))
```
"""
function plot_transitions(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
    normalize::Bool = true,
)
    tm = transition_matrix(df, aois; selection = selection, normalize = normalize)
    mat = tm.matrix
    labels = tm.labels
    n = length(labels)

    fig = Figure(size = (500, 450))
    ax = Axis(
        fig[1, 1];
        xlabel = "To AOI",
        ylabel = "From AOI",
        title = _format_title("AOI Transitions", selection),
        xticks = (1:n, labels),
        yticks = (1:n, labels),
        xticklabelrotation = π / 4,
        yreversed = true,
    )

    hm = Makie.heatmap!(ax, 1:n, 1:n, mat; colormap = :viridis, interpolate = false)

    # Annotate cells with values
    for i = 1:n, j = 1:n
        val = mat[i, j]
        txt = normalize ? string(round(val; digits = 2)) : string(Int(val))
        text_color = val > 0.5 * maximum(mat) ? :white : :black
        Makie.text!(
            ax,
            j,
            i;
            text = txt,
            align = (:center, :center),
            fontsize = 14,
            color = text_color,
        )
    end

    label = normalize ? "Probability" : "Count"
    Colorbar(fig[1, 2], hm; label = label)

    return fig
end
