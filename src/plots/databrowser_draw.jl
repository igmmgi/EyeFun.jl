# ── Interactive Eye Data Viewer ─────────────────────────────────────────────── #

"""
    EyeViewerMediaState

Observable state for the interactive eye data viewer.
"""
mutable struct EyeViewerMediaState
    trial::Observable{Int}      # current segment index
    frame::Observable{Int}
    show_samples::Observable{Bool}
    show_heatmap::Observable{Bool}
    show_saccades::Observable{Bool}
    show_fixations::Observable{Bool}
    show_blinks::Observable{Bool}
    show_messages::Observable{Bool}
    show_aois::Observable{Bool}
    selected_saccade::Observable{Int}
    selected_fixation::Observable{Int}
    segments::Vector{Any}
    split_by::Union{Nothing,Symbol,Vector{Symbol}}
    screen_res::Tuple{Int,Int}
    eye::Symbol
    gx_col::Symbol
    gy_col::Symbol
    pa_col::Symbol
    spatial_zoom::Union{Nothing,NTuple{4,Float64}}
    window_samples::Int         # 0 = show all, >0 = visible window size
    aois::Union{Nothing,Vector{<:AOI}}
    bg_stimulus::Any               # optional function: segment_id -> Vector{AbstractEyeFunMedia}
end



"""Point-to-line-segment distance."""
function _point_to_segment_dist(px, py, x1, y1, x2, y2)
    dx, dy = x2 - x1, y2 - y1
    len_sq = dx^2 + dy^2
    if len_sq ≈ 0
        return sqrt((px - x1)^2 + (py - y1)^2)
    end
    t = clamp(((px - x1) * dx + (py - y1) * dy) / len_sq, 0.0, 1.0)
    proj_x, proj_y = x1 + t * dx, y1 + t * dy
    return sqrt((px - proj_x)^2 + (py - proj_y)^2)
end


# ── Helper: get trial data ─────────────────────────────────────────────────── #

"""Extract data for a given segment based on split_by."""
function _dbnew_get_segment_data(df::EyeData, segment, split_by)
    if isnothing(split_by)
        return df.df  # whole DataFrame
    elseif split_by isa Symbol
        return filter(r -> !ismissing(r[split_by]) && r[split_by] == segment, df.df)
    else  # Vector{Symbol}
        return filter(
            r -> all(s -> !ismissing(r[s]) && r[s] == segment[s], split_by),
            df.df,
        )
    end
end

"""Generate a human-readable label for the current segment."""
function _dbnew_segment_label(state)
    idx = state.trial[]
    n = length(state.segments)
    seg = state.segments[idx]
    if isnothing(state.split_by)
        return "All Data"
    elseif state.split_by isa Symbol
        name = titlecase(string(state.split_by))
        return "$(name) $(seg) ($(idx)/$(n))"
    else
        parts = ["$(titlecase(string(s))) $(seg[s])" for s in state.split_by]
        return join(parts, " ") * " ($(idx)/$(n))"
    end
end

"""Draw blink shading bands on a time-series axis."""
function _dbnew_draw_blink_bands!(ax, g::AbstractDataFrame, t::Vector{Float64}, state)
    !state.show_blinks[] && return
    !hasproperty(g, :in_blink) && return

    bm = g.in_blink
    xlo = Float64[]
    xhi = Float64[]
    blink_start = 0
    for i in eachindex(bm)
        if bm[i] && (i == 1 || !bm[i-1])
            blink_start = i
        end
        if !bm[i] && i > 1 && bm[i-1] && blink_start > 0
            push!(xlo, t[blink_start])
            push!(xhi, t[i-1])
            blink_start = 0
        end
    end
    # Handle blink at end of trial
    if blink_start > 0
        push!(xlo, t[blink_start])
        push!(xhi, t[end])
    end

    if !isempty(xlo)
        vspan!(ax, xlo, xhi; color = (:salmon, 0.3))
    end
end

# ── Media Rendering ───────────────────────────────────────────────────────────── #

function _render_media_items!(ax, items, sx, sy)
    for stim_val in items
        # Typed media
        if stim_val isa AudioMedia
            text!(
                ax,
                sx / 2,
                sy * 0.95;
                text = "AUDIO ATTACHED (Press [Space] to Play)",
                align = (:center, :top),
                fontsize = 18,
                color = :white,
                glowwidth = 3,
                glowcolor = :black,
            )

        elseif stim_val isa TextMedia
            pos_x = isnothing(stim_val.position) ? sx / 2 : stim_val.position[1]
            pos_y = isnothing(stim_val.position) ? sy / 2 : stim_val.position[2]
            text!(
                ax,
                pos_x,
                pos_y;
                text = stim_val.content,
                align = (:center, :center),
                fontsize = stim_val.fontsize,
                word_wrap_width = 500,
                color = stim_val.color,
            )

        elseif stim_val isa ImageMedia
            img_mat =
                stim_val.content isa AbstractString ? load_image(stim_val.content) :
                stim_val.content
            img_rotated = permutedims(img_mat, (2, 1))

            if !isnothing(stim_val.bbox)
                Makie.image!(
                    ax,
                    stim_val.bbox[1] .. stim_val.bbox[2],
                    stim_val.bbox[3] .. stim_val.bbox[4],
                    img_rotated,
                )
            else
                cx, cy = isnothing(stim_val.position) ? (sx / 2, sy / 2) : stim_val.position
                w, h = size(img_rotated)
                Makie.image!(
                    ax,
                    (cx - w / 2) .. (cx + w / 2),
                    (cy - h / 2) .. (cy + h / 2),
                    img_rotated,
                )
            end

            # Legacy: loose Tuples and Strings
        else
            is_audio_tuple =
                stim_val isa Tuple &&
                length(stim_val) >= 2 &&
                stim_val[2] isa Number &&
                stim_val[1] isa AbstractArray
            if is_audio_tuple ||
               (stim_val isa AbstractString && endswith(lowercase(stim_val), ".wav"))
                text!(
                    ax,
                    sx / 2,
                    sy * 0.95;
                    text = "AUDIO ATTACHED (Press [Space] to Play)",
                    align = (:center, :top),
                    fontsize = 18,
                    color = :white,
                    glowwidth = 3,
                    glowcolor = :black,
                )
            elseif stim_val isa AbstractString && (
                endswith(lowercase(stim_val), ".txt") ||
                endswith(lowercase(stim_val), ".csv")
            )
                disp_txt = length(stim_val) > 400 ? stim_val[1:400] * "..." : stim_val
                text!(
                    ax,
                    sx / 2,
                    sy / 2;
                    text = disp_txt,
                    align = (:center, :center),
                    fontsize = 16,
                    word_wrap_width = 500,
                    color = :black,
                )

            else
                img_mat = nothing
                bbox = nothing
                center = nothing

                if stim_val isa Tuple &&
                   length(stim_val) == 2 &&
                   stim_val[1] isa AbstractMatrix
                    img_mat = stim_val[1]
                    coord = stim_val[2]
                    if coord isa Tuple && length(coord) == 4
                        bbox = coord
                    elseif coord isa Tuple && length(coord) == 2
                        center = coord
                    end
                elseif stim_val isa AbstractMatrix
                    img_mat = stim_val
                    center = (sx / 2, sy / 2) # Fallback to Center 
                elseif stim_val isa AbstractString
                    img_mat = load_image(stim_val)
                    center = (sx / 2, sy / 2) # Fallback to Center 
                end

                if !isnothing(img_mat)
                    # permutedims instead of rotr90: avoids flipping on yreversed axes
                    img_rotated = permutedims(img_mat, (2, 1))

                    if !isnothing(bbox)
                        # (xmin, xmax, ymin, ymax) Box stretch
                        x_range = bbox[1] .. bbox[2]
                        y_range = bbox[3] .. bbox[4]
                        Makie.image!(ax, x_range, y_range, img_rotated)
                    elseif !isnothing(center)
                        w, h = size(img_rotated)
                        cx, cy = center
                        x_range = (cx - w / 2) .. (cx + w / 2)
                        y_range = (cy - h / 2) .. (cy + h / 2)
                        Makie.image!(ax, x_range, y_range, img_rotated)
                    end
                end
            end
        end
    end
end

# ── Draw functions ─────────────────────────────────────────────────────────── #

"""Draw the spatial view (gaze on screen) for the current trial."""
function _dbnew_draw_spatial!(
    ax,
    gx::Vector{Float64},
    gy::Vector{Float64},
    state,
    saccades::Vector{SaccadeInfo},
    fixations::Vector{FixationInfo};
    reset_zoom::Bool = false,
)
    # Save current zoom before clearing (if user has zoomed)
    if !reset_zoom && !isnothing(state.spatial_zoom)
        # Keep existing zoom
    else
        cur_lims = ax.finallimits[]
        if cur_lims.widths[1] > 0 && !reset_zoom
            state.spatial_zoom = (
                cur_lims.origin[1],
                cur_lims.origin[1] + cur_lims.widths[1],
                cur_lims.origin[2],
                cur_lims.origin[2] + cur_lims.widths[2],
            )
        else
            state.spatial_zoom = nothing
        end
    end

    empty!(ax)

    sx, sy = state.screen_res

    # Screen boundary
    lines!(ax, [0, sx, sx, 0, 0], [0, 0, sy, sy, 0]; color = :grey70, linewidth = 1)

    # Screen center crosshair
    lines!(ax, [sx / 2, sx / 2], [0, sy]; color = :grey85, linewidth = 0.5)
    lines!(ax, [0, sx], [sy / 2, sy / 2]; color = :grey85, linewidth = 0.5)

    # Background image drawing
    if !isnothing(state.bg_stimulus)
        try
            segment_id = state.segments[state.trial[]]
            stim_vals = state.bg_stimulus(segment_id)

            if !isnothing(stim_vals)
                items = stim_vals isa AbstractVector ? collect(stim_vals) : Any[stim_vals]
                # Sort items if they support z_index to ensure correct layering
                sort!(
                    items,
                    by = x ->
                        (x isa AbstractEyeFunMedia && hasproperty(x, :z_index)) ?
                        x.z_index : 0,
                )

                _render_media_items!(ax, items, sx, sy)
            end
        catch e
            @warn "❌ [Spatial Renderer] Failed to draw bg_stimulus for segment" exception =
                e
        end
    end

    # Gaze trace or Heatmap
    valid = .!isnan.(gx) .& .!isnan.(gy)
    if any(valid)
        if state.show_heatmap[]
            px = gx[valid]
            py = gy[valid]
            x_c, y_c, counts =
                _bin_samples(px, py, (0.0, Float64(sx)), (0.0, Float64(sy)), (50, 50))
            vals = _gaussian_smooth(counts, 2.0)
            Makie.heatmap!(ax, x_c, y_c, vals; colormap = :inferno, interpolate = true)
        elseif state.show_samples[]
            lines!(ax, gx[valid], gy[valid]; color = (:black, 0.5), linewidth = 1)
        end
    end

    # Fixations (use pre-extracted list)
    if state.show_fixations[]
        fxs = Float64[]
        fys = Float64[]
        sizes = Float64[]
        labels = String[]
        for (fi, f) in enumerate(fixations)
            push!(fxs, f.x)
            push!(fys, f.y)
            push!(sizes, max(3.0, min(f.dur / 10.0, 40.0)))
            push!(labels, string(fi))
        end
        if !isempty(fxs)
            scatter!(
                ax,
                fxs,
                fys;
                markersize = sizes,
                color = (:red, 0.4),
                marker = :circle,
            )
            text!(
                ax,
                fxs,
                fys;
                text = labels,
                color = :black,
                fontsize = 10,
                align = (:center, :center),
            )
        end
    end

    # Saccades
    if state.show_saccades[]
        slx = Float64[]
        sly = Float64[]
        mxs, mys, dxs, dys = Float64[], Float64[], Float64[], Float64[]
        for s in saccades
            push!(slx, s.x1, s.x2, NaN)
            push!(sly, s.y1, s.y2, NaN)
            m_x, m_y = (s.x1 + s.x2) / 2, (s.y1 + s.y2) / 2
            push!(mxs, m_x)
            push!(mys, m_y)
            # Arrow direction, scaled to be visible
            push!(dxs, (s.x2 - s.x1) * 0.1)
            push!(dys, (s.y2 - s.y1) * 0.1)
        end
        if !isempty(slx)
            lines!(ax, slx, sly; color = (:green, 0.85), linewidth = 2.5)
        end
        if !isempty(mxs)
            arrows2d!(
                ax,
                mxs,
                mys,
                dxs,
                dys;
                color = (:green, 0.85),
                tipwidth = 15,
                tiplength = 15,
                lengthscale = 1.0,
            )
        end
    end


    state.show_aois[] && !isnothing(state.aois) && _draw_aois!(ax, state.aois)

    if reset_zoom || isnothing(state.spatial_zoom)
        xlims!(ax, -50, sx + 50)
        ylims!(ax, sy + 50, -50)   # reversed: high at top → 0,0 at top-left
        state.spatial_zoom = nothing
    else
        xl, xh, yl, yh = state.spatial_zoom
        xlims!(ax, xl, xh)
        ylims!(ax, yh, yl)   # keep reversed order
    end
end

"""Draw the XY position trace panel."""
function _dbnew_draw_xy_trace!(
    ax,
    g::AbstractDataFrame,
    gx::Vector{Float64},
    gy::Vector{Float64},
    t::Vector{Float64},
    state,
    saccades::Vector{SaccadeInfo},
    fixations::Vector{FixationInfo},
    cache::Dict{Symbol,Any},
)
    empty!(ax)

    lines!(ax, t, gx; color = :dodgerblue, linewidth = 1)
    lines!(ax, t, gy; color = :darkorange, linewidth = 1)

    # Inline labels at start of each trace (replaces legend to avoid redraw accumulation)
    first_valid = findfirst(i -> !isnan(gx[i]) && !isnan(t[i]), eachindex(gx))
    if !isnothing(first_valid)
        text!(
            ax,
            t[first_valid],
            gx[first_valid];
            text = "x",
            color = :dodgerblue,
            fontsize = 13,
            font = :bold,
            align = (:right, :center),
            offset = (5, 0),
        )
    end
    first_valid_y = findfirst(i -> !isnan(gy[i]) && !isnan(t[i]), eachindex(gy))
    if !isnothing(first_valid_y)
        text!(
            ax,
            t[first_valid_y],
            gy[first_valid_y];
            text = "y",
            color = :darkorange,
            fontsize = 13,
            font = :bold,
            align = (:right, :center),
            offset = (5, 0),
        )
    end

    sx, sy = state.screen_res
    hlines!(ax, [sx / 2.0]; color = :grey70, linewidth = 0.5, linestyle = :dash)
    hlines!(ax, [sy / 2.0]; color = :grey80, linewidth = 0.5, linestyle = :dash)

    # Bar height = 5% of visible axis extent
    autolimits!(ax)
    lims = ax.finallimits[]
    bar_h = abs(lims.widths[2]) * 0.05
    cache[:xy_bar_h] = bar_h

    # Fixation bars first (drawn below saccade markers)
    if state.show_fixations[]
        rects = Rect2f[]
        for f in fixations
            ts = max(1, f.time_start)
            te = min(length(t), f.time_end)
            if ts <= te
                x = t[ts]
                w = t[te] - x
                push!(rects, Rect2f(x, 0.0, max(w, 1e-5), bar_h))
            end
        end
        if !isempty(rects)
            poly!(ax, rects; color = (:red, 0.3))
        end
    end

    # Saccade markers on top
    if state.show_saccades[]
        sx = [t[s.time_idx] for s in saccades if 1 <= s.time_idx <= length(t)]
        if !isempty(sx)
            vlines!(ax, sx; color = (:green, 0.4), linewidth = 1)
        end
    end

    # Message markers
    if state.show_messages[] && hasproperty(g, :message)
        msg_x = Float64[]
        for i in eachindex(g.message)
            if !ismissing(g.message[i]) && g.message[i] != ""
                push!(msg_x, t[i])
            end
        end
        if !isempty(msg_x)
            vlines!(ax, msg_x; color = (:black, 0.6), linewidth = 1.5, linestyle = :dash)
        end
    end

    # Blink shading
    _dbnew_draw_blink_bands!(ax, g, t, state)

    !isnan(t[1]) && !isnan(t[end]) && t[1] < t[end] && xlims!(ax, t[1], t[end])
end
function _dbnew_draw_velocity!(
    ax,
    g::AbstractDataFrame,
    t::Vector{Float64},
    speed::Vector{Float64},
    state,
    saccades::Vector{SaccadeInfo},
    fixations::Vector{FixationInfo},
    cache::Dict{Symbol,Any},
)
    empty!(ax)

    lines!(ax, t, speed; color = :black, linewidth = 1)
    hlines!(ax, [0.0]; color = :grey70, linewidth = 0.5)

    # Bar height = 5% of visible axis extent
    autolimits!(ax)
    lims = ax.finallimits[]
    bar_h = abs(lims.widths[2]) * 0.05
    cache[:vel_bar_h] = bar_h

    # Fixation bars first
    if state.show_fixations[] && hasproperty(g, :fix_gavx)
        rects = Rect2f[]
        for f in fixations
            ts = max(1, f.time_start)
            te = min(length(t), f.time_end)
            if ts <= te
                x = t[ts]
                w = t[te] - x
                push!(rects, Rect2f(x, 0.0, max(w, 1e-5), bar_h))
            end
        end
        if !isempty(rects)
            poly!(ax, rects; color = (:red, 0.3))
        end
    end

    # Saccade markers on top
    if state.show_saccades[]
        sx = [t[s.time_idx] for s in saccades if 1 <= s.time_idx <= length(t)]
        if !isempty(sx)
            vlines!(ax, sx; color = (:green, 0.4), linewidth = 1)
        end
    end

    # Blink shading
    _dbnew_draw_blink_bands!(ax, g, t, state)

    !isnan(t[1]) && !isnan(t[end]) && t[1] < t[end] && xlims!(ax, t[1], t[end])
end
function _dbnew_draw_pupil!(
    ax,
    g::AbstractDataFrame,
    pa::Vector{Float64},
    t::Vector{Float64},
    state,
)
    empty!(ax)

    lines!(ax, t, pa; color = :black, linewidth = 1)

    # Blink shading — use vspan! for full-height vertical bands
    _dbnew_draw_blink_bands!(ax, g, t, state)

    !isnan(t[1]) && !isnan(t[end]) && t[1] < t[end] && xlims!(ax, t[1], t[end])
end

"""Get time vector for a trial sub-DataFrame (uses time_rel if available, else time from 0)."""
function _trial_time(g::AbstractDataFrame)
    if hasproperty(g, :time_rel) && !all(ismissing, g.time_rel)
        t = Float64[ismissing(v) ? NaN : Float64(v) for v in g.time_rel]
        # Check if time is monotonically increasing (single trial)
        # If not (merged trials), use raw sample indices in ms
        if length(t) > 1 &&
           !all(i -> isnan(t[i]) || isnan(t[i-1]) || t[i] >= t[i-1], 2:length(t))
            # Non-monotonic → use raw timestamps offset from first
            t_raw = Float64.(g.time)
            return t_raw .- t_raw[1]
        end
        return t
    else
        t_raw = Float64.(g.time)
        return t_raw .- t_raw[1]
    end
end

"""Draw a polar rose plot of saccade directions for the current trial."""


function _dbnew_draw_saccade_polar!(
    ax,
    state,
    saccades::Vector{SaccadeInfo},
    cache::Dict{Symbol,Any},
)
    polar_plots = get!(cache, :polar_plots, Any[])
    # Remove only our previously added plots (not axis decorations)
    for p in polar_plots
        delete!(ax, p)
    end
    empty!(polar_plots)

    !state.show_saccades[] && return
    isempty(saccades) && return

    angles = [s.angle for s in saccades if isfinite(s.angle)]
    isempty(angles) && return

    n_bins = 36
    bin_width = 2π / n_bins
    bin_edges = range(-π, π; length = n_bins + 1)
    counts = zeros(n_bins)
    for a in angles
        for b = 1:n_bins
            if bin_edges[b] <= a < bin_edges[b+1]
                counts[b] += 1
                break
            end
        end
    end
    bin_centers = [(bin_edges[b] + bin_edges[b+1]) / 2 for b = 1:n_bins]

    maximum(counts) == 0 && return
    p = barplot!(
        ax,
        bin_centers,
        counts;
        width = bin_width,
        color = (:green, 0.7),
        strokewidth = 1.5,
        strokecolor = :darkgreen,
    )
    push!(polar_plots, p)
end

# ── Main draw function ─────────────────────────────────────────────────────── #

"""Redraw all panels for the current trial/segment. Populates cache for click handlers."""
function _dbnew_draw_all!(
    axes,
    df::EyeData,
    state,
    trial_label,
    cache::Dict{Symbol,Any};
    reset_zoom::Bool = false,
    window_start::Int = 1,
)
    g_full = _dbnew_get_segment_data(df, state.segments[state.trial[]], state.split_by)
    n_full = nrow(g_full)
    n_full == 0 && return

    trial_label[] = _dbnew_segment_label(state)

    # Extract events from FULL data (heavy — cached for _dbnew_redraw_window!)
    saccades_full = _extract_saccades(g_full)
    fixations_full = _extract_fixations(g_full)
    t_full = _trial_time(g_full)

    # Compute velocity for cursor tracking
    gx = Float64.(g_full[!, state.gx_col])
    gy = Float64.(g_full[!, state.gy_col])
    ppd = Float64(pixels_per_degree(df))
    spd = _compute_velocity_deg(gx, gy, ppd, df.sample_rate)

    # Cache full segment data
    cache[:g] = g_full
    cache[:saccades] = saccades_full
    cache[:fixations] = fixations_full
    cache[:t_full] = t_full
    cache[:n_full] = n_full
    cache[:speed] = spd

    # Draw windowed view
    _dbnew_redraw_window!(
        axes,
        state,
        cache;
        reset_zoom = reset_zoom,
        window_start = window_start,
    )
end

"""Fast redraw using cached full-segment data — used by scroll slider."""
function _dbnew_redraw_window!(
    axes,
    state,
    cache::Dict{Symbol,Any};
    reset_zoom::Bool = false,
    window_start::Int = 1,
)
    g_full = cache[:g]::DataFrame
    n_full = cache[:n_full]::Int
    saccades_full = cache[:saccades]
    fixations_full = cache[:fixations]

    # Compute window range
    ws = state.window_samples
    if ws > 0 && n_full > ws
        w_start = clamp(window_start, 1, n_full - ws + 1)
        w_end = w_start + ws - 1
    else
        w_start = 1
        w_end = n_full
    end
    g = @view g_full[w_start:w_end, :]
    cache[:window_start] = w_start
    cache[:window_end] = w_end

    # Pre-extract column data once (avoids repeated Float64.() copies in draw functions)
    gx = Float64.(g[!, state.gx_col])
    gy = Float64.(g[!, state.gy_col])
    pa = Float64.(g[!, state.pa_col])

    t_full = cache[:t_full]::Vector{Float64}
    t = t_full[w_start:w_end]

    speed_full = cache[:speed]::Vector{Float64}
    speed_win = speed_full[w_start:w_end]

    # Filter events to visible window and remap indices
    saccades_win = filter(s -> w_start <= s.time_idx <= w_end, saccades_full)
    fixations_win = filter(
        f -> w_start <= f.time_start <= w_end || w_start <= f.time_end <= w_end,
        fixations_full,
    )

    saccades_draw = SaccadeInfo[
        (;
            s.x1,
            s.y1,
            s.x2,
            s.y2,
            time_idx = s.time_idx - w_start + 1,
            s.angle,
            s.amplitude,
        ) for s in saccades_win
    ]
    fixations_draw = FixationInfo[
        (;
            f.x,
            f.y,
            f.dur,
            time_start = max(1, f.time_start - w_start + 1),
            time_end = min(f.time_end - w_start + 1, nrow(g)),
        ) for f in fixations_win
    ]

    # Cache windowed events and time for click handlers
    cache[:saccades_win] = saccades_draw
    cache[:fixations_win] = fixations_draw
    cache[:t_win] = t

    _dbnew_draw_spatial!(
        axes[1],
        gx,
        gy,
        state,
        saccades_draw,
        fixations_draw;
        reset_zoom = reset_zoom,
    )
    _dbnew_draw_saccade_polar!(axes[2], state, saccades_draw, cache)
    _dbnew_draw_xy_trace!(
        axes[3],
        g,
        gx,
        gy,
        t,
        state,
        saccades_draw,
        fixations_draw,
        cache,
    )
    _dbnew_draw_velocity!(
        axes[4],
        g,
        t,
        speed_win,
        state,
        saccades_draw,
        fixations_draw,
        cache,
    )
    _dbnew_draw_pupil!(axes[5], g, pa, t, state)
end

# ── Cursor dots ────────────────────────────────────────────────────────────── #

"""Add cursor scatter dots to all axes (call after _dbnew_draw_all! which clears axes)."""
function _dbnew_add_cursor_dots!(axes, cursor_obs)
    scatter!(
        axes[1],
        cursor_obs[:spatial_pts];
        color = :black,
        markersize = 12,
        marker = :circle,
    )
    # axes[2] is PolarAxis — no cursor dot
    text!(
        axes[3],
        cursor_obs[:xy_x_pt];
        text = "x",
        color = :dodgerblue,
        fontsize = 18,
        font = :bold,
        align = (:center, :center),
    )
    text!(
        axes[3],
        cursor_obs[:xy_y_pt];
        text = "y",
        color = :darkorange,
        fontsize = 18,
        font = :bold,
        align = (:center, :center),
    )
    scatter!(
        axes[4],
        cursor_obs[:vel_pts];
        color = :black,
        markersize = 10,
        marker = :circle,
    )
    scatter!(
        axes[5],
        cursor_obs[:pup_pts];
        color = :black,
        markersize = 10,
        marker = :circle,
    )
end

"""Update the black dot cursor positions across all panels for the current frame."""
function _dbnew_update_cursor!(cursor_obs, cache::Dict{Symbol,Any}, state)
    haskey(cache, :g) || return
    g = cache[:g]::DataFrame
    nrow(g) == 0 && return
    f = clamp(state.frame[], 1, nrow(g))

    gx = Float64(g[f, state.gx_col])
    gy = Float64(g[f, state.gy_col])
    pa = Float64(g[f, state.pa_col])

    # Use cached windowed time for cursor position (matches axes)
    t_win = get(cache, :t_win, Float64[])::Vector{Float64}
    w_start = get(cache, :window_start, 1)
    f_local = clamp(f - w_start + 1, 1, length(t_win))
    isempty(t_win) && return
    t_val = t_win[f_local]

    # Spatial dot
    cursor_obs[:spatial_pts][] = Point2f[(gx, gy)]

    # XY trace text cursors — show both X and Y position
    cursor_obs[:xy_x_pt][] = Point2f[(t_val, gx)]
    cursor_obs[:xy_y_pt][] = Point2f[(t_val, gy)]

    # Velocity dot (use cached speed array)
    speed = cache[:speed]::Vector{Float64}
    speed_val = speed[f]
    cursor_obs[:vel_pts][] = Point2f[(t_val, isnan(speed_val) ? 0.0 : speed_val)]

    # Pupil dot
    cursor_obs[:pup_pts][] = Point2f[(t_val, pa)]
end

# ── Main entry point ───────────────────────────────────────────────────────── #
