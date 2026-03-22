# ── Shared plotting helpers ────────────────────────────────────────────────── #

"""Select gaze columns based on eye keyword and data availability."""
function _select_eye(samples::DataFrame, eye::Symbol)
    has_left = hasproperty(samples, :gxL) && !all(isnan, samples.gxL)
    has_right = hasproperty(samples, :gxR) && !all(isnan, samples.gxR)

    # Normalize short forms
    eye in (:L, :l) && (eye = :left)
    eye in (:R, :r) && (eye = :right)

    if eye == :auto
        eye =
            has_left ? :left :
            (has_right ? :right : error("No valid gaze data found in either eye"))
    end

    if eye == :left
        has_left || error(
            "No left-eye gaze data available (gxL is all NaN). This may be a right-eye recording.",
        )
        return samples.gxL, samples.gyL, "Left eye"
    elseif eye == :right
        has_right || error(
            "No right-eye gaze data available (gxR is all NaN). This may be a left-eye recording.",
        )
        return samples.gxR, samples.gyR, "Right eye"
    else
        error("Invalid eye=:$eye. Use :left, :right, :L, :R, or :auto.")
    end
end

# ── Selection filter ───────────────────────────────────────────────────────── #

"""
Filter a DataFrame by a NamedTuple of column=value pairs.
All conditions must match (AND logic). Also supports plain `Int` for trial number.

# Examples
    _apply_selection(df, nothing)                        # no filter
    _apply_selection(df, 5)                              # trial == 5
    _apply_selection(df, (trial=1,))                     # trial == 1
    _apply_selection(df, (trial=1, stimulus="Face"))     # trial 1 AND stimulus == "Face"
    _apply_selection(df, (stimulus="Face",))             # all trials with stimulus == "Face"
"""
function _apply_selection(df::EyeData, selection)
    selection === nothing && return df

    # Backward compat: plain Int → filter by trial
    if selection isa Int
        hasproperty(df.df, :trial) || error("No :trial column in data")
        return filter(r -> !ismissing(r.trial) && r.trial == selection, df.df)
    end

    # NamedTuple: match all key=value pairs (AND logic)
    # Supports scalar values (==) and collections like ranges/vectors (in)
    if selection isa NamedTuple
        result = df.df
        for (col, val) in pairs(selection)
            hasproperty(result, col) ||
                error("Column :$col not found in data. Available: $(names(result))")
            if val isa Union{AbstractVector,AbstractRange}
                result = filter(r -> !ismissing(r[col]) && r[col] in val, result)
            else
                result = filter(r -> !ismissing(r[col]) && r[col] == val, result)
            end
        end
        return result
    end

    error(
        "Unsupported selection type: $(typeof(selection)). Use a NamedTuple, e.g. (trial=1, stimulus=\"Face\").",
    )
end

"""Draw AOI rectangles on an axis. `aois` is a Dict of name => (x1, y1, x2, y2)."""
function _draw_aois!(ax, aois::Dict)
    isempty(aois) && return
    colors = Makie.wong_colors()
    for (i, (name, bounds)) in enumerate(sort(collect(aois)))
        x1, y1, x2, y2 = bounds
        c = colors[mod1(i, length(colors))]
        poly!(
            ax,
            Makie.Rect(x1, y1, x2-x1, y2-y1);
            color = (c, 0.15),
            strokewidth = 2,
            strokecolor = c,
        )
        Makie.text!(
            ax,
            (x1 + x2) / 2,
            y1;
            text = name,
            align = (:center, :bottom),
            fontsize = 12,
            color = c,
            font = :bold,
        )
    end
end

# ── Binning & smoothing ───────────────────────────────────────────────────── #

"""
    _bin_samples(px, py, xlims, ylims, bins)

Bin 2D gaze positions into a grid. Returns (x_centers, y_centers, counts).
"""
function _bin_samples(px, py, xlims, ylims, bins)
    nx, ny = bins
    x_edges = range(xlims[1], xlims[2]; length = nx + 1)
    y_edges = range(ylims[1], ylims[2]; length = ny + 1)

    counts = zeros(Float64, nx, ny)
    for i in eachindex(px)
        xi = searchsortedlast(x_edges, px[i])
        yi = searchsortedlast(y_edges, py[i])
        if 1 <= xi <= nx && 1 <= yi <= ny
            counts[xi, yi] += 1.0
        end
    end

    x_centers = [(x_edges[i] + x_edges[i+1]) / 2 for i = 1:nx]
    y_centers = [(y_edges[i] + y_edges[i+1]) / 2 for i = 1:ny]

    return x_centers, y_centers, counts
end

"""
    _gaussian_smooth(data, sigma)

Apply 2D Gaussian smoothing to a matrix. `sigma` is in bins (grid cells).
"""
function _gaussian_smooth(data::Matrix{Float64}, sigma::Real)
    sigma <= 0 && return data
    k = ceil(Int, 3 * sigma)
    kernel_1d = [exp(-x^2 / (2 * sigma^2)) for x = (-k):k]
    kernel_1d ./= sum(kernel_1d)

    # Separable convolution: smooth rows, then columns
    nx, ny = size(data)
    tmp = zeros(Float64, nx, ny)
    out = zeros(Float64, nx, ny)

    # Smooth along dim 1 (rows)
    for j = 1:ny, i = 1:nx
        s = 0.0
        w = 0.0
        for di = (-k):k
            ii = clamp(i + di, 1, nx)
            s += kernel_1d[di+k+1] * data[ii, j]
            w += kernel_1d[di+k+1]
        end
        tmp[i, j] = s / w
    end

    # Smooth along dim 2 (cols)
    for j = 1:ny, i = 1:nx
        s = 0.0
        w = 0.0
        for dj = (-k):k
            jj = clamp(j + dj, 1, ny)
            s += kernel_1d[dj+k+1] * tmp[i, jj]
            w += kernel_1d[dj+k+1]
        end
        out[i, j] = s / w
    end

    return out
end
