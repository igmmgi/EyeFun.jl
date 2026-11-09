"""
    plot_transitions(df::EyeData, aois::Vector{<:AOI};
                     selection=nothing, eye=:auto, normalize=true)

Plot an AOI transition probability (or count) heatmap.
Rows (`From AOI`) are plotted along the Y-axis and columns (`To AOI`) along the X-axis.
"""
function plot_transitions(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
    normalize::Bool = true,
    prefix::Union{Nothing,Symbol} = nothing,
)
    _resolve_eye(df, eye)
    tm = transition_matrix(
        df,
        aois;
        selection = selection,
        normalize = normalize,
        prefix = prefix,
    )
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

    # Makie.heatmap! maps dim 1 -> X ("To AOI", j) and dim 2 -> Y ("From AOI", i),
    # whereas mat is indexed [from=i, to=j]; permute dims so colors align with labels.
    hm = Makie.heatmap!(
        ax,
        1:n,
        1:n,
        permutedims(mat);
        colormap = :viridis,
        interpolate = false,
    )

    max_val = isempty(mat) ? 0.0 : maximum(mat)
    wx = Float64[]
    wy = Float64[]
    wtxt = String[]
    bx = Float64[]
    by = Float64[]
    btxt = String[]
    for i = 1:n, j = 1:n
        val = mat[i, j]
        txt = normalize ? string(round(val; digits = 2)) : string(round(Int, val))
        if max_val > 0.0 && val > 0.5 * max_val
            push!(wx, Float64(j))
            push!(wy, Float64(i))
            push!(wtxt, txt)
        else
            push!(bx, Float64(j))
            push!(by, Float64(i))
            push!(btxt, txt)
        end
    end
    if !isempty(wx)
        Makie.text!(
            ax,
            wx,
            wy;
            text = wtxt,
            align = (:center, :center),
            fontsize = 14,
            color = :white,
        )
    end
    if !isempty(bx)
        Makie.text!(
            ax,
            bx,
            by;
            text = btxt,
            align = (:center, :center),
            fontsize = 14,
            color = :black,
        )
    end

    label = normalize ? "Probability" : "Count"
    Colorbar(fig[1, 2], hm; label = label)

    return fig
end
