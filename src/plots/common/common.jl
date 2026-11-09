"""Select gaze columns based on eye keyword and data availability.
Thin wrapper around `_resolve_eye` + `_get_gaze_vecs` for convenience in plot code."""
function _select_eye(samples::AbstractDataFrame, eye::Symbol)
    resolved = _resolve_eye(samples, eye)
    gx, gy = _get_gaze_vecs(samples, resolved)
    label =
        resolved == :left ? "Left eye" :
        resolved == :right ? "Right eye" : "Both eyes"
    return gx, gy, label
end

"""Format a plot title, e.g. "Gaze: Trial=1" or "Gaze: Trial=1:10, Stimulus=Face"."""
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
    for (i, aoi) in enumerate(aois)
        c = isnothing(aoi.color) ? colors[mod1(i, length(colors))] : aoi.color
        _draw_single_aoi!(ax, aoi, c)
    end
end

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

function _draw_single_aoi!(ax, aoi::CircleAOI, c)
    θ = range(0, 2π; length = 64)
    xs = aoi.cx .+ aoi.radius .* cos.(θ)
    ys = aoi.cy .+ aoi.radius .* sin.(θ)
    poly!(ax, Point2f.(xs, ys); color = (c, 0.15), strokewidth = 2, strokecolor = c)
    _aoi_label!(ax, aoi.cx, aoi.cy - aoi.radius, aoi.name, c)
end

function _draw_single_aoi!(ax, aoi::EllipseAOI, c)
    θ = range(0, 2π; length = 64)
    xs = aoi.cx .+ aoi.rx .* cos.(θ)
    ys = aoi.cy .+ aoi.ry .* sin.(θ)
    poly!(ax, Point2f.(xs, ys); color = (c, 0.15), strokewidth = 2, strokecolor = c)
    _aoi_label!(ax, aoi.cx, aoi.cy - aoi.ry, aoi.name, c)
end

function _draw_single_aoi!(ax, aoi::PolygonAOI, c)
    pts = Point2f.(aoi.vertices)
    poly!(ax, pts; color = (c, 0.15), strokewidth = 2, strokecolor = c)
    cx = mean(first.(aoi.vertices))
    cy = minimum(last.(aoi.vertices))
    _aoi_label!(ax, cx, cy, aoi.name, c)
end

function _draw_aoi_shape_only!(ax, aoi::RectAOI, c)
    poly!(
        ax,
        Makie.Rect(aoi.cx - aoi.width / 2, aoi.cy - aoi.height / 2, aoi.width, aoi.height);
        color = (c, 0.10),
        strokewidth = 2,
        strokecolor = c,
        linestyle = :dash,
    )
    return aoi.cx, aoi.cy - aoi.height / 2
end

function _draw_aoi_shape_only!(ax, aoi::CircleAOI, c)
    θ = range(0, 2π; length = 64)
    pts = Point2f.(aoi.cx .+ aoi.radius .* cos.(θ), aoi.cy .+ aoi.radius .* sin.(θ))
    poly!(ax, pts; color = (c, 0.10), strokewidth = 2, strokecolor = c, linestyle = :dash)
    return aoi.cx, aoi.cy - aoi.radius
end

function _draw_aoi_shape_only!(ax, aoi::EllipseAOI, c)
    θ = range(0, 2π; length = 64)
    pts = Point2f.(aoi.cx .+ aoi.rx .* cos.(θ), aoi.cy .+ aoi.ry .* sin.(θ))
    poly!(ax, pts; color = (c, 0.10), strokewidth = 2, strokecolor = c, linestyle = :dash)
    return aoi.cx, aoi.cy - aoi.ry
end

function _draw_aoi_shape_only!(ax, aoi::PolygonAOI, c)
    pts = Point2f.(aoi.vertices)
    poly!(ax, pts; color = (c, 0.10), strokewidth = 2, strokecolor = c, linestyle = :dash)
    return mean(first.(aoi.vertices)), minimum(last.(aoi.vertices))
end

function _draw_aoi_shape_only!(ax, aoi::DynamicAOI, c)
    lx, ly = 0.0, 0.0
    for (idx, w) in enumerate(aoi.windows)
        wx, wy = _draw_aoi_shape_only!(ax, w[3], c)
        idx == 1 && ((lx, ly) = (wx, wy))
    end
    return lx, ly
end

function _draw_single_aoi!(ax, aoi::DynamicAOI, c)
    lx, ly = _draw_aoi_shape_only!(ax, aoi, c)
    _aoi_label!(ax, lx, ly, aoi.name, c)
end

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

"""
    _bin_samples(px, py, xlims, ylims, bins)

Bin 2D gaze positions into a grid. Returns (x_centers, y_centers, counts).
"""
function _bin_samples(px, py, xlims, ylims, bins)
    nx, ny = bins isa Integer ? (Int(bins), Int(bins)) : (Int(bins[1]), Int(bins[2]))
    (nx <= 0 || ny <= 0) && error("bins must have positive dimensions (got $bins).")
    x0, x1 = Float64(xlims[1]), Float64(xlims[2])
    y0, y1 = Float64(ylims[1]), Float64(ylims[2])
    x_edges = range(x0, x1; length = nx + 1)
    y_edges = range(y0, y1; length = ny + 1)
    inv_dx = x1 > x0 ? nx / (x1 - x0) : 0.0
    inv_dy = y1 > y0 ? ny / (y1 - y0) : 0.0

    counts = zeros(Float64, nx, ny)
    @inbounds for i in eachindex(px, py)
        xv = Float64(px[i])
        yv = Float64(py[i])
        if x0 <= xv <= x1 && y0 <= yv <= y1
            xi = xv == x1 ? nx : (floor(Int, (xv - x0) * inv_dx) + 1)
            yi = yv == y1 ? ny : (floor(Int, (yv - y0) * inv_dy) + 1)
            if 1 <= xi <= nx && 1 <= yi <= ny
                counts[xi, yi] += 1.0
            end
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
    @inbounds for j = 1:ny
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
                kv = kernel_1d[di+k+1]
                s += kv * data[ii, j]
                w += kv
            end
            tmp[i, j] = s / w
        end
    end

    # Smooth along dim 2 (cols)
    @inbounds for i = 1:nx
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
                kv = kernel_1d[dj+k+1]
                s += kv * tmp[i, jj]
                w += kv
            end
            out[i, j] = s / w
        end
    end

    return out
end

function _plot_trial_group_cols(samples::AbstractDataFrame)::Vector{Symbol}
    has_tr = hasproperty(samples, :trial)
    multi_p = _has_multiple_participants(samples)
    if has_tr && multi_p
        return [:participant, :trial]
    elseif has_tr
        return [:trial]
    elseif multi_p
        return [:participant]
    else
        return Symbol[]
    end
end

@inline function _is_new_plot_trial(
    tr_col::Union{Nothing,AbstractVector},
    p_col::Union{Nothing,AbstractVector},
    times::Union{Nothing,AbstractVector},
    i::Int,
)::Bool
    i <= 1 && return true
    if !isnothing(tr_col) && !isequal(@inbounds(tr_col[i]), @inbounds(tr_col[i-1]))
        return true
    end
    if !isnothing(p_col) && !isequal(@inbounds(p_col[i]), @inbounds(p_col[i-1]))
        return true
    end
    if !isnothing(times) && Float64(@inbounds(times[i])) < Float64(@inbounds(times[i-1]))
        return true
    end
    return false
end

function _nonmissing_col_mask(col::AbstractVector)
    mask = BitVector(undef, length(col))
    @inbounds for i in eachindex(col)
        mask[i] = !ismissing(col[i])
    end
    return mask
end

"""
Filter `samples` by `split_by` and return `(groups, split_vals, n_panels)`, capping panel count at `max_panels`.
"""
function _prepare_split_panels(samples, split_by; max_panels = 4)
    if !isnothing(split_by)
        hasproperty(samples, split_by) ||
            error("Column :$split_by not found for splitting.")
        col = samples[!, split_by]
        mask = _nonmissing_col_mask(col)
        groups = @view samples[mask, :]
        split_vals = sort(unique(groups[!, split_by]))
    else
        groups = samples
        split_vals = [nothing]
    end
    if length(split_vals) > max_panels
        @warn "Plotting $(length(split_vals)) panels exceeds max_panels=$max_panels; truncating to first $max_panels. Use plot_databrowser() to browse all segments."
        split_vals = split_vals[1:max_panels]
    end
    n_panels = length(split_vals)
    n_panels == 0 && error("No non-missing values in :$split_by for splitting.")
    return groups, split_vals, n_panels
end

function _panel_view(groups::AbstractDataFrame, split_by, fval)
    isnothing(fval) && return groups
    mask = trues(nrow(groups))
    _mark_equal!(mask, groups[!, split_by], fval)
    return @view groups[mask, :]
end

"""
Build the Makie Figure object with correct horizontal expansion logic for `split_by` plots.
Supports aspect_ratio locking for 2D spatial plots (heatmap, fixations, scanpath).
"""
function _create_split_figure(
    split_by,
    n_panels;
    panel_w = 450,
    fig_h = nothing,
    aspect_ratio = nothing,
)
    if !isnothing(aspect_ratio)
        panel_h = round(Int, panel_w / aspect_ratio)
        h = !isnothing(split_by) ? panel_h + 80 : 650
        w = !isnothing(split_by) ? panel_w : round(Int, 650 * aspect_ratio)
        fig_w = !isnothing(split_by) ? (w * n_panels + 100) : w
        return Figure(size = (fig_w, h))
    else
        w = !isnothing(split_by) ? panel_w : 900
        h = isnothing(fig_h) ? 500 : fig_h
        fig_w = !isnothing(split_by) ? (w * n_panels + 50) : w
        return Figure(size = (fig_w, h))
    end
end
