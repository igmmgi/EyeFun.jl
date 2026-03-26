# ── Transition Analysis & Plotting ─────────────────────────────────────────── #

"""
    transition_matrix(df::EyeData, aois::Vector{<:AOI};
                      selection=nothing, eye=:auto, normalize=true)

Compute an AOI-to-AOI transition matrix from fixation sequences.

Returns a `NamedTuple` with:
- `matrix` — `n×n` matrix of transition counts (or probabilities if `normalize=true`)
- `labels` — AOI name labels in row/column order

# Example
```julia
aois = [RectAOI("Face", 400, 200, 800, 600), RectAOI("Text", 0, 700, 1280, 960)]
tm = transition_matrix(df, aois; selection=(trial=1:10,))
tm.matrix   # 2×2 transition probability matrix
tm.labels   # ["Face", "Text"]
```
"""
function transition_matrix(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
    normalize::Bool = true,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    n_aois = length(aois)
    labels = [a.name for a in aois]
    mat = zeros(Float64, n_aois, n_aois)

    # Build fixation sequence with AOI labels
    hasproperty(samples, :fix_gavx) ||
        error("No fixation columns. Run event detection first.")

    eye = _resolve_eye(samples, eye)
    ecols = _eye_columns(eye)

    # Extract unique fixations
    fix_sequence = Int[]  # AOI index for each fixation (0 = outside all AOIs)
    prev_fx = NaN
    for i = 1:nrow(samples)
        samples.in_fix[i] || continue
        fx = Float64(samples.fix_gavx[i])
        isnan(fx) && continue
        fx == prev_fx && continue  # same fixation
        prev_fx = fx

        fy = Float64(samples.fix_gavy[i])
        # Find which AOI this fixation falls in
        aoi_idx = 0
        for (ai, aoi) in enumerate(aois)
            if contains(aoi, fx, fy)
                aoi_idx = ai
                break
            end
        end
        push!(fix_sequence, aoi_idx)
    end

    # Count transitions (skip fixations outside all AOIs)
    for i = 2:length(fix_sequence)
        from = fix_sequence[i-1]
        to = fix_sequence[i]
        from == 0 && continue
        to == 0 && continue
        mat[from, to] += 1.0
    end

    # Normalize rows to probabilities
    if normalize
        for r = 1:n_aois
            row_sum = sum(mat[r, :])
            if row_sum > 0
                mat[r, :] ./= row_sum
            end
        end
    end

    return (matrix = mat, labels = labels)
end

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
    tm =
        transition_matrix(df, aois; selection = selection, eye = eye, normalize = normalize)
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
