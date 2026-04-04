# ── Shared plotting helpers ────────────────────────────────────────────────── #

"""Select gaze columns based on eye keyword and data availability.
Thin wrapper around `_resolve_eye` + `_eye_columns` for convenience in plot code."""
function _select_eye(samples::AbstractDataFrame, eye::Symbol)
    resolved = _resolve_eye(samples, eye)
    ecols = _eye_columns(resolved)
    label = resolved == :left ? "Left eye" : "Right eye"
    return samples[!, ecols.gx], samples[!, ecols.gy], label
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
    isnothing(selection) && return df.df

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

"""Format a clean plot title, e.g. "Gaze: Trial=1" or "Gaze: Trial=1:10, Stimulus=Face"."""
function _format_title(prefix::String, selection)
    isnothing(selection) && return prefix
    if selection isa Int
        return "$prefix: Trial=$selection"
    end
    if selection isa NamedTuple
        parts = [
            "$(titlecase(string(k)))=$(v isa AbstractRange ? "$(first(v)):$(last(v))" : v)"
            for (k, v) in pairs(selection)
        ]
        return "$prefix: $(join(parts, ", "))"
    end
    return prefix
end

"""Draw AOI shapes on an axis."""
function _draw_aois!(ax, aois::Vector{<:AOI})
    isempty(aois) && return
    colors = Makie.wong_colors()
    for (i, aoi) in enumerate(sort(aois; by = a -> a.name))
        c = isnothing(aoi.color) ? colors[mod1(i, length(colors))] : aoi.color
        _draw_single_aoi!(ax, aoi, c)
    end
end

"""
    _draw_single_aoi

Internal documentation.
"""
function _draw_single_aoi!(ax, aoi::RectAOI, c)
    y1 = aoi.cy - aoi.height / 2
    poly!(
        ax,
        Makie.Rect(aoi.cx - aoi.width / 2, y1, aoi.width, aoi.height);
        color = (c, 0.15),
        strokewidth = 2,
        strokecolor = c,
    )
    _aoi_label!(ax, aoi.cx, y1, aoi.name, c)
end

"""
    _draw_single_aoi

Internal documentation.
"""
function _draw_single_aoi!(ax, aoi::CircleAOI, c)
    θ = range(0, 2π; length = 64)
    xs = aoi.cx .+ aoi.radius .* cos.(θ)
    ys = aoi.cy .+ aoi.radius .* sin.(θ)
    poly!(ax, Point2f.(xs, ys); color = (c, 0.15), strokewidth = 2, strokecolor = c)
    _aoi_label!(ax, aoi.cx, aoi.cy - aoi.radius, aoi.name, c)
end

"""
    _draw_single_aoi

Internal documentation.
"""
function _draw_single_aoi!(ax, aoi::EllipseAOI, c)
    θ = range(0, 2π; length = 64)
    xs = aoi.cx .+ aoi.rx .* cos.(θ)
    ys = aoi.cy .+ aoi.ry .* sin.(θ)
    poly!(ax, Point2f.(xs, ys); color = (c, 0.15), strokewidth = 2, strokecolor = c)
    _aoi_label!(ax, aoi.cx, aoi.cy - aoi.ry, aoi.name, c)
end

"""
    _draw_single_aoi

Internal documentation.
"""
function _draw_single_aoi!(ax, aoi::PolygonAOI, c)
    pts = Point2f.(aoi.vertices)
    poly!(ax, pts; color = (c, 0.15), strokewidth = 2, strokecolor = c)
    # Label at centroid
    cx = mean(first.(aoi.vertices))
    cy = minimum(last.(aoi.vertices))
    _aoi_label!(ax, cx, cy, aoi.name, c)
end

"""
    _aoi_label

Internal documentation.
"""
function _aoi_label!(ax, x, y, name, c)
    Makie.text!(
        ax,
        x,
        y;
        text = name,
        align = (:center, :bottom),
        fontsize = 12,
        color = c,
        font = :bold,
    )
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
    for j = 1:ny
        # Interior pixels: kernel is fully in bounds, w == 1.0
        for i = (k+1):(nx-k)
            s = 0.0
            for di = (-k):k
                s += kernel_1d[di+k+1] * data[i+di, j]
            end
            tmp[i, j] = s
        end
        # Edge pixels: need weight normalization
        for i in Iterators.flatten((1:k, (nx-k+1):nx))
            (i < 1 || i > nx) && continue
            s = 0.0
            w = 0.0
            for di = (-k):k
                ii = clamp(i + di, 1, nx)
                s += kernel_1d[di+k+1] * data[ii, j]
                w += kernel_1d[di+k+1]
            end
            tmp[i, j] = s / w
        end
    end

    # Smooth along dim 2 (cols)
    for i = 1:nx
        # Interior pixels
        for j = (k+1):(ny-k)
            s = 0.0
            for dj = (-k):k
                s += kernel_1d[dj+k+1] * tmp[i, j+dj]
            end
            out[i, j] = s
        end
        # Edge pixels
        for j in Iterators.flatten((1:k, (ny-k+1):ny))
            (j < 1 || j > ny) && continue
            s = 0.0
            w = 0.0
            for dj = (-k):k
                jj = clamp(j + dj, 1, ny)
                s += kernel_1d[dj+k+1] * tmp[i, jj]
                w += kernel_1d[dj+k+1]
            end
            out[i, j] = s / w
        end
    end

    return out
end
