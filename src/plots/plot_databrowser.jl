# ── Interactive Eye Data Viewer ─────────────────────────────────────────────── #

"""
    EyeViewerState

Observable state for the interactive eye data viewer.
"""
mutable struct EyeViewerState
    trial::Observable{Int}      # current segment index
    frame::Observable{Int}
    show_samples::Observable{Bool}
    show_heatmap::Observable{Bool}
    show_saccades::Observable{Bool}
    show_fixations::Observable{Bool}
    show_blinks::Observable{Bool}
    show_messages::Observable{Bool}
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
end

# ── Saccade info ───────────────────────────────────────────────────────────── #

const SaccadeInfo = @NamedTuple{
    x1::Float64,
    y1::Float64,
    x2::Float64,
    y2::Float64,
    time_idx::Int,
    angle::Float64,
    amplitude::Float64,
}

"""Extract unique saccades from a trial sub-DataFrame."""
function _extract_saccades(g::DataFrame)
    saccades = SaccadeInfo[]
    !hasproperty(g, :sacc_gstx) && return saccades
    prev_stx = NaN
    for i in eachindex(g.sacc_gstx)
        if g.in_sacc[i] && !isnan(g.sacc_gstx[i]) && Float64(g.sacc_gstx[i]) != prev_stx
            x1, y1 = Float64(g.sacc_gstx[i]), Float64(g.sacc_gsty[i])
            x2, y2 = Float64(g.sacc_genx[i]), Float64(g.sacc_geny[i])
            if !isnan(x1) && !isnan(y1) && !isnan(x2) && !isnan(y2)
                dx, dy = x2 - x1, -(y2 - y1)  # flip Y for screen coords
                push!(
                    saccades,
                    (
                        x1 = x1,
                        y1 = y1,
                        x2 = x2,
                        y2 = y2,
                        time_idx = i,
                        angle = atan(dx, dy),  # compass bearing: 0=up, π/2=right
                        amplitude = sqrt(dx^2 + dy^2),
                    ),
                )
            end
            prev_stx = Float64(g.sacc_gstx[i])
        end
    end
    return saccades
end

const FixationInfo =
    @NamedTuple{x::Float64, y::Float64, dur::Float64, time_start::Int, time_end::Int}

"""Extract unique fixations from a trial sub-DataFrame."""
function _extract_fixations(g::DataFrame)
    fixations = FixationInfo[]
    !hasproperty(g, :fix_gavx) && return fixations
    !hasproperty(g, :fix_gavy) && return fixations

    i = 1
    n = length(g.fix_gavx)
    while i <= n
        if g.in_fix[i] && !isnan(g.fix_gavx[i]) && !isnan(g.fix_gavy[i])
            fx = Float64(g.fix_gavx[i])
            # Find extent of this fixation
            t_start = i
            t_end = i
            for j = i:n
                if g.in_fix[j] && Float64(g.fix_gavx[j]) == fx
                    t_end = j
                else
                    break
                end
            end
            push!(
                fixations,
                (
                    x = fx,
                    y = Float64(g.fix_gavy[i]),
                    dur = Float64(g.fix_dur[i]),
                    time_start = t_start,
                    time_end = t_end,
                ),
            )
            i = t_end + 1
        else
            i += 1
        end
    end
    return fixations
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

# ── Helper: compute velocity ───────────────────────────────────────────────── #

"""Compute 2D gaze velocity using 5-sample central difference."""
function _compute_velocity(gx::Vector{Float64}, gy::Vector{Float64})
    n = length(gx)
    vx = fill(NaN, n)
    vy = fill(NaN, n)
    n < 5 && return vx, vy
    for i = 3:(n-2)
        vx[i] = (gx[i+2] + gx[i+1] - gx[i-1] - gx[i-2]) / 6.0
        vy[i] = (gy[i+2] + gy[i+1] - gy[i-1] - gy[i-2]) / 6.0
    end
    return vx, vy
end

# ── Helper: get trial data ─────────────────────────────────────────────────── #

"""Extract data for a given segment based on split_by."""
function _get_segment_data(df::EyeData, segment, split_by)
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
function _segment_label(state)
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
function _draw_blink_bands!(ax, g::AbstractDataFrame, t::Vector{Float64}, state)
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

# ── Draw functions ─────────────────────────────────────────────────────────── #

"""Draw the spatial view (gaze on screen) for the current trial."""
function _draw_spatial!(
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
            arrows!(
                ax,
                mxs,
                mys,
                dxs,
                dys;
                color = (:green, 0.85),
                arrowsize = 15,
                lengthscale = 1.0,
            )
        end
    end


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
function _draw_xy_trace!(
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
    _draw_blink_bands!(ax, g, t, state)

    !isnan(t[1]) && !isnan(t[end]) && t[1] < t[end] && xlims!(ax, t[1], t[end])
end
function _draw_velocity!(
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
    _draw_blink_bands!(ax, g, t, state)

    !isnan(t[1]) && !isnan(t[end]) && t[1] < t[end] && xlims!(ax, t[1], t[end])
end
function _draw_pupil!(
    ax,
    g::AbstractDataFrame,
    pa::Vector{Float64},
    t::Vector{Float64},
    state,
)
    empty!(ax)

    lines!(ax, t, pa; color = :black, linewidth = 1)

    # Blink shading — use vspan! for full-height vertical bands
    _draw_blink_bands!(ax, g, t, state)

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


function _draw_saccade_polar!(
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
function _draw_all!(
    axes,
    df::EyeData,
    state,
    trial_label,
    cache::Dict{Symbol,Any};
    reset_zoom::Bool = false,
    window_start::Int = 1,
)
    g_full = _get_segment_data(df, state.segments[state.trial[]], state.split_by)
    n_full = nrow(g_full)
    n_full == 0 && return

    trial_label[] = _segment_label(state)

    # Extract events from FULL data (heavy — cached for _redraw_window!)
    saccades_full = _extract_saccades(g_full)
    fixations_full = _extract_fixations(g_full)
    t_full = _trial_time(g_full)

    # Compute velocity for cursor tracking
    gx = Float64.(g_full[!, state.gx_col])
    gy = Float64.(g_full[!, state.gy_col])
    vx, vy = _compute_velocity(gx, gy)
    spd = sqrt.(vx .^ 2 .+ vy .^ 2)

    # Cache full segment data
    cache[:g] = g_full
    cache[:saccades] = saccades_full
    cache[:fixations] = fixations_full
    cache[:t_full] = t_full
    cache[:n_full] = n_full
    cache[:speed] = spd

    # Draw windowed view
    _redraw_window!(
        axes,
        state,
        cache;
        reset_zoom = reset_zoom,
        window_start = window_start,
    )
end

"""Fast redraw using cached full-segment data — used by scroll slider."""
function _redraw_window!(
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

    _draw_spatial!(
        axes[1],
        gx,
        gy,
        state,
        saccades_draw,
        fixations_draw;
        reset_zoom = reset_zoom,
    )
    _draw_saccade_polar!(axes[2], state, saccades_draw, cache)
    _draw_xy_trace!(axes[3], g, gx, gy, t, state, saccades_draw, fixations_draw, cache)
    _draw_velocity!(axes[4], g, t, speed_win, state, saccades_draw, fixations_draw, cache)
    _draw_pupil!(axes[5], g, pa, t, state)
end

# ── Cursor dots ────────────────────────────────────────────────────────────── #

"""Add cursor scatter dots to all axes (call after _draw_all! which clears axes)."""
function _add_cursor_dots!(axes, cursor_obs)
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
function _update_cursor!(cursor_obs, cache::Dict{Symbol,Any}, state)
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

"""
    plot_databrowser(df::EyeData; eye=:auto, split_by=:trial)

Open an interactive eye-tracking data viewer.

# Parameters
- `split_by`: How to segment data for browsing.
  - `split_by=:trial` (default) — one page per trial
  - `split_by=[:block, :trial]` — multi-level grouping
  - `split_by=nothing` — show entire DataFrame as one view

# Layout
- **Left**: Spatial gaze view (gaze position on screen with fixations/saccades)
- **Right top**: XY position trace over time
- **Right middle**: Gaze velocity over time
- **Right bottom**: Pupil size over time

# Controls
- **◀ / ▶ buttons**: Navigate to previous/next segment
- **Textbox**: Type a value and press Enter to jump directly (single-column split only)
- **Sample slider**: Drag to scrub through samples; black dots track position
- **Play/Pause**: Animate through samples; speed slider controls playback rate
- **Checkboxes**: Toggle samples, saccades, fixations, blinks, messages

# Keyboard
- `←`/`→`: Previous/next segment
- `r`: Reset to first segment

# Example
```julia
df = read_eyelink_edf_dataframe("data.edf"; trial_time_zero="TRIALID")
plot_databrowser(df)
plot_databrowser(df; split_by=nothing)
plot_databrowser(df; split_by=[:block, :trial])
```
"""
function plot_databrowser(
    df::EyeData;
    eye::Symbol = :auto,
    split_by::Union{Nothing,Symbol,Vector{Symbol}} = :trial,
    display_plot::Bool = true,
)

    # Resolve eye
    resolved_eye = _resolve_eye(df, eye)
    gx_col = resolved_eye == :left ? :gxL : :gxR
    gy_col = resolved_eye == :left ? :gyL : :gyR
    pa_col = resolved_eye == :left ? :paL : :paR

    # Compute segments from split_by
    if isnothing(split_by)
        segments = Any[1]  # single pseudo-segment
    elseif split_by isa Symbol
        segments = Any[v for v in sort(unique(skipmissing(df.df[!, split_by])))]
    else
        # Multi-column: get unique combos as NamedTuples
        cols = Symbol.(split_by)
        combos = unique(df.df[!, cols])
        # Remove rows with missing values
        combos = filter(r -> all(c -> !ismissing(r[c]), cols), combos)
        # Sort by columns in order
        sort!(combos, cols)
        segments =
            Any[NamedTuple{Tuple(cols)}(Tuple(r[c] for c in cols)) for r in eachrow(combos)]
    end
    isempty(segments) && error("No segments found in DataFrame for split_by=$(split_by).")

    # Initialize auto_window
    g_first = _get_segment_data(df, segments[1], split_by)
    auto_window = isnothing(split_by) && nrow(g_first) > 5000 ? 5000 : 0

    # Create state
    state = EyeViewerState(
        Observable(1),          # segment index
        Observable(1),          # frame
        Observable(true),       # show_samples
        Observable(false),      # show_heatmap
        Observable(true),       # show_saccades
        Observable(true),       # show_fixations
        Observable(false),      # show_blinks
        Observable(false),      # show_messages
        Observable(0),          # selected_saccade
        Observable(0),          # selected_fixation
        segments,
        split_by,
        df.screen_res,
        resolved_eye,
        gx_col,
        gy_col,
        pa_col,
        nothing,                # spatial_zoom
        auto_window,             # window_samples
    )

    # ── Figure layout ──────────────────────────────────────────────────────── #
    fig = Figure(size = (1920, 1080), padding = (0, 0, 0, 0))

    g_left = fig[1, 1] = GridLayout()
    g_right = fig[1, 2] = GridLayout()

    # Left column: spatial (top) + polar (bottom)
    ax_spatial = Axis(
        g_left[1:2, 1];
        xlabel = "X (px)",
        ylabel = "Y (px)",
        aspect = DataAspect(),
        yreversed = true,
        title = "Gaze Position",
        xgridvisible = false,
        ygridvisible = false,
        halign = :left,
    )

    ax_polar = PolarAxis(
        g_left[3, 1];
        title = "Saccade Directions",
        theta_0 = -π / 2,
        direction = -1,
        thetaticklabelsize = 10,
        rtickangle = π / 6,
        rticklabelsize = 10,
    )

    # Right column: time-series (rows 1:3)
    ax_xy = Axis(
        g_right[1:4, 1];
        ylabel = "Position (px)",
        xgridvisible = false,
        ygridvisible = false,
    )
    hidexdecorations!(ax_xy; label = true)

    ax_vel = Axis(
        g_right[5, 1];
        ylabel = "Velocity (px/s)",
        xgridvisible = false,
        ygridvisible = false,
    )
    hidexdecorations!(ax_vel; label = true)

    ax_pup = Axis(
        g_right[6, 1];
        xlabel = "Time (ms)",
        ylabel = "Pupil",
        xgridvisible = false,
        ygridvisible = false,
    )

    linkxaxes!(ax_xy, ax_vel, ax_pup)

    axes = [ax_spatial, ax_polar, ax_xy, ax_vel, ax_pup]

    # ── Controls ───────────────────────────────────────────────────────────── #

    # Left column (under spatial): navigation + toggles
    left_controls = fig[2, 1] = GridLayout(valign = :top)

    # Trial navigation + toggles — single horizontal row
    trial_label = Observable(_segment_label(state))
    n_segs = length(state.segments)


    window_view_obs = Observable(state.window_samples > 0)

    # ◀ label ▶ [textbox] | toggles...
    col = 1
    if isnothing(state.split_by)
        # Single segment — just show "All Data" label, no navigation
        Label(
            left_controls[1, col],
            "All Data";
            fontsize = 14,
            halign = :center,
            tellwidth = true,
        )
        col += 1

        tog_win =
            Toggle(left_controls[1, col]; active = window_view_obs[], tellwidth = true)
        col += 1
        Label(
            left_controls[1, col],
            "Windowed";
            fontsize = 12,
            halign = :left,
            tellwidth = true,
        )
        col += 1

        on(tog_win.active) do val
            window_view_obs[] = val
        end

        btn_prev = nothing
        btn_next = nothing
        tb_trial = nothing
    else
        btn_prev = Button(left_controls[1, col]; label = "◀", width = 36, tellwidth = true)
        col += 1
        Label(
            left_controls[1, col],
            trial_label;
            fontsize = 14,
            halign = :center,
            tellwidth = true,
        )
        col += 1
        btn_next = Button(left_controls[1, col]; label = "▶", width = 36, tellwidth = true)
        col += 1
        tb_trial = Textbox(
            left_controls[1, col];
            placeholder = "Trial #",
            validator = Int,
            width = 70,
            stored_string = nothing,
            tellwidth = true,
            reset_on_defocus = true,
        )
        col += 1
    end

    toggles = [
        ("Samples", state.show_samples),
        ("Heatmap", state.show_heatmap),
        ("Fixations", state.show_fixations),
        ("Saccades", state.show_saccades),
        ("Blinks", state.show_blinks),
        ("Messages", state.show_messages),
    ]

    tcol = 0
    for (i, (label, obs)) in enumerate(toggles)
        tcol += 1
        tog = Toggle(left_controls[2, tcol]; active = obs[], tellwidth = true)
        tcol += 1
        Label(
            left_controls[2, tcol],
            label;
            fontsize = 12,
            halign = :left,
            tellwidth = true,
        )
        on(tog.active) do val
            obs[] = val
            _draw_all!(
                axes,
                df,
                state,
                trial_label,
                _cache;
                window_start = isnothing(sl_scroll) ? 1 : round(Int, sl_scroll.value[]),
            )
            _add_cursor_dots!(axes, cursor_obs)
            _update_cursor!(cursor_obs, _cache, state)
            _create_overlay_plots!()
        end
    end
    colgap!(left_controls, 4)
    rowgap!(left_controls, 4)

    # Scrubber area: sliders in column 2 aligned exactly with plots
    slider_controls = fig[2, 2] = GridLayout(valign = :top)

    g1 = _get_segment_data(df, state.segments[1], state.split_by)
    n_samples_init = max(1, nrow(g1))
    ws = state.window_samples
    _is_windowed = ws > 0 && n_samples_init > ws

    # Row 1: play button (col 1) + frame slider (col 2)
    frame_range = _is_windowed ? ws : n_samples_init
    btn_play = Button(
        slider_controls[1, 1];
        label = "▶",
        fontsize = 14,
        tellwidth = false,
        halign = :right,
    )
    sl_frame = Slider(
        slider_controls[1, 2];
        range = 1:frame_range,
        startvalue = 1,
        snap = true,
        tellwidth = false,
    )

    # Row 2: speed label (col 1) + speed slider (col 2)
    lbl_speed = Label(
        slider_controls[2, 1],
        "Speed:";
        fontsize = 11,
        halign = :right,
        tellwidth = false,
    )
    sample_rate = round(
        Int,
        1.0 / max(
            1e-6,
            (
                nrow(g1) > 1 ?
                (Float64(g1[end, :time]) - Float64(g1[1, :time])) / (nrow(g1) - 1) /
                1000.0 : 0.001
            ),
        ),
    )
    realtime_step = max(1, round(Int, sample_rate / 30))
    max_speed = realtime_step * 2
    sl_speed = Slider(
        slider_controls[2, 2];
        range = 1:1:max_speed,
        startvalue = realtime_step,
        snap = true,
        tellwidth = false,
    )

    # Row 3: scroll play button (col 1) + scroll slider (col 2)
    btn_scroll_play = Button(
        slider_controls[3, 1];
        label = "▶",
        fontsize = 11,
        tellwidth = false,
        halign = :right,
    )
    scroll_max = max(1, n_samples_init - (window_view_obs[] ? 5000 : 10000) + 1)
    sl_scroll = Slider(
        slider_controls[3, 2];
        range = 1:scroll_max,
        startvalue = 1,
        snap = false,
        tellwidth = false,
    )

    on(window_view_obs) do is_win
        btn_scroll_play.blockscene.visible = is_win && isnothing(state.split_by)
        sl_scroll.blockscene.visible = is_win && isnothing(state.split_by)

        state.window_samples = is_win ? 5000 : 0
        ws = state.window_samples
        n = max(
            1,
            nrow(_get_segment_data(df, state.segments[state.trial[]], state.split_by)),
        )

        frame_range = (ws > 0 && n > ws) ? ws : n
        sl_frame.range[] = 1:frame_range

        if ws > 0 && n > ws
            sl_scroll.range[] = 1:max(1, n-ws+1)
            # Avoid triggering the slider hook synchronously if possible, safely bypass set_close_to! cascade
            sl_scroll.value.val = 1
        end

        _redraw_window!(axes, state, _cache; reset_zoom = true, window_start = 1)
        _add_cursor_dots!(axes, cursor_obs)
        _update_cursor!(cursor_obs, _cache, state)
        _create_overlay_plots!()
    end

    # Initialize visibility
    btn_scroll_play.blockscene.visible = window_view_obs[] && isnothing(state.split_by)
    sl_scroll.blockscene.visible = window_view_obs[] && isnothing(state.split_by)

    # Play/pause states
    _playing = Observable(false)
    _scroll_playing = Observable(false)

    on(btn_play.clicks) do _
        _playing[] = !_playing[]
        btn_play.label[] = _playing[] ? "||" : "▶"
        if _playing[]
            @async begin
                while _playing[]
                    current = sl_frame.value[]
                    n = length(sl_frame.range[])
                    if current >= n
                        set_close_to!(sl_frame, 1)  # loop within window
                    else
                        step = max(1, round(Int, sl_speed.value[]))
                        set_close_to!(sl_frame, min(current + step, n))
                    end
                    sleep(1 / 30)
                end
            end
        end
    end

    # Scroll play button — advances window through data
    on(btn_scroll_play.clicks) do _
        _scroll_playing[] = !_scroll_playing[]
        btn_scroll_play.label[] = _scroll_playing[] ? "||" : "▶"
        if _scroll_playing[]
            @async begin
                while _scroll_playing[]
                    current = round(Int, sl_scroll.value[])
                    scroll_range = sl_scroll.range[]
                    if current >= last(scroll_range)
                        set_close_to!(sl_scroll, first(scroll_range))  # loop
                    else
                        step = max(1, round(Int, sl_speed.value[] * 10))
                        set_close_to!(sl_scroll, min(current + step, last(scroll_range)))
                    end
                    sleep(1 / 30)
                end
            end
        end
    end

    # ── Cursor dot observables ─────────────────────────────────────────────── #
    cursor_obs = Dict(
        :spatial_pts => Observable(Point2f[(0, 0)]),
        :xy_x_pt => Observable(Point2f[(0, 0)]),
        :xy_y_pt => Observable(Point2f[(0, 0)]),
        :vel_pts => Observable(Point2f[(0, 0)]),
        :pup_pts => Observable(Point2f[(0, 0)]),
    )

    # ── Trial navigation helper ─────────────────────────────────────────────── #

    function _goto_trial!(idx::Int)
        idx = clamp(idx, 1, length(state.segments))
        _playing[] = false
        btn_play.label[] = "▶"
        _scroll_playing[] = false
        btn_scroll_play.label[] = "▶"
        state.trial[] = idx
        state.selected_saccade[] = 0
        state.selected_fixation[] = 0
        g = _get_segment_data(df, state.segments[idx], state.split_by)
        n = max(1, nrow(g))

        # Update windowed state
        ws = state.window_samples
        if ws > 0 && n > ws
            if !isnothing(sl_scroll)
                sl_scroll.range[] = 1:max(1, n-ws+1)
                set_close_to!(sl_scroll, 1)
            end
            sl_frame.range[] = 1:ws
        else
            sl_frame.range[] = 1:n
        end
        set_close_to!(sl_frame, 1)
        state.frame[] = 1
        w_start = isnothing(sl_scroll) ? 1 : sl_scroll.value[]
        _draw_all!(
            axes,
            df,
            state,
            trial_label,
            _cache;
            reset_zoom = true,
            window_start = w_start,
        )
        _add_cursor_dots!(axes, cursor_obs)
        _update_cursor!(cursor_obs, _cache, state)
        _create_overlay_plots!()
    end

    # ── Observers ──────────────────────────────────────────────────────────── #

    # ◀ / ▶ buttons
    if !isnothing(btn_prev)
        on(btn_prev.clicks) do _
            state.trial[] > 1 && _goto_trial!(state.trial[] - 1)
        end
    end
    if !isnothing(btn_next)
        on(btn_next.clicks) do _
            state.trial[] < length(state.segments) && _goto_trial!(state.trial[] + 1)
        end
    end

    # Textbox — jump to trial number
    if !isnothing(tb_trial)
        on(tb_trial.stored_string) do s
            isnothing(s) && return
            trial_num = tryparse(Int, s)
            isnothing(trial_num) && return
            idx = findfirst(==(trial_num), state.segments)
            if !isnothing(idx)
                _goto_trial!(idx)
            end
        end
    end

    # Frame slider — cursor within visible window
    on(sl_frame.value) do f
        # Convert window-relative frame to full-data frame
        w_start = get(_cache, :window_start, 1)
        state.frame[] = w_start + f - 1
        _update_cursor!(cursor_obs, _cache, state)
    end

    # Scroll slider — changes visible window
    if !isnothing(sl_scroll)
        on(sl_scroll.value) do w
            w_start = round(Int, w)
            _redraw_window!(axes, state, _cache; window_start = w_start)
            _add_cursor_dots!(axes, cursor_obs)
            _create_overlay_plots!()
            # Re-map cursor to new window
            state.frame[] = w_start + sl_frame.value[] - 1
            _update_cursor!(cursor_obs, _cache, state)
        end
    end

    # ── Keyboard events ────────────────────────────────────────────────────── #
    on(events(fig).keyboardbutton) do event
        if event.action == Keyboard.press || event.action == Keyboard.repeat
            if event.key == Keyboard.right
                if state.trial[] < length(state.segments)
                    _goto_trial!(state.trial[] + 1)
                end
                return Consume(true)
            elseif event.key == Keyboard.left
                if state.trial[] > 1
                    _goto_trial!(state.trial[] - 1)
                end
                return Consume(true)
            elseif event.key == Keyboard.r
                _goto_trial!(1)
                return Consume(true)
            elseif event.key == Keyboard.escape
                state.selected_saccade[] = 0
                state.selected_fixation[] = 0
                _update_highlight_overlay!()
                return Consume(true)
            end
        end
        return Consume(false)
    end

    # ── Selection highlight overlay (Observable-based, no plot creation on click) ── #

    # Persistent overlay Observables
    _hl_sacc_spatial_pts = Observable(Point2f[])
    _hl_sacc_xy_t = Observable(Float64[])
    _hl_sacc_vel_t = Observable(Float64[])

    _hl_sacc_vis = Observable(false)

    _hl_fix_spatial_pts = Observable(Point2f[])
    _hl_fix_spatial_ms = Observable(10.0)
    _hl_fix_xy_pts = Observable(Point2f[(0, 0), (0, 0), (0, 0), (0, 0)])
    _hl_fix_vel_pts = Observable(Point2f[(0, 0), (0, 0), (0, 0), (0, 0)])
    _hl_fix_vis = Observable(false)

    # Create/recreate persistent overlay plots (must be called after any _draw_all!)
    function _create_overlay_plots!()
        lines!(
            axes[1],
            _hl_sacc_spatial_pts;
            color = (:green, 0.9),
            linewidth = 6,
            visible = _hl_sacc_vis,
        )
        vlines!(
            axes[3],
            _hl_sacc_xy_t;
            color = (:green, 0.7),
            linewidth = 3,
            visible = _hl_sacc_vis,
        )
        vlines!(
            axes[4],
            _hl_sacc_vel_t;
            color = (:green, 0.7),
            linewidth = 3,
            visible = _hl_sacc_vis,
        )

        scatter!(
            axes[1],
            _hl_fix_spatial_pts;
            color = (:red, 0.1),
            markersize = _hl_fix_spatial_ms,
            marker = :circle,
            strokewidth = 3,
            strokecolor = :red,
            visible = _hl_fix_vis,
        )
        poly!(axes[3], _hl_fix_xy_pts; color = (:red, 0.5), visible = _hl_fix_vis)
        poly!(axes[4], _hl_fix_vel_pts; color = (:red, 0.5), visible = _hl_fix_vis)
    end

    function _update_highlight_overlay!()
        haskey(_cache, :saccades_win) || return
        saccades = _cache[:saccades_win]::Vector{SaccadeInfo}
        fixations = get(_cache, :fixations_win, FixationInfo[])::Vector{FixationInfo}

        # Use cached windowed time (matches what's plotted on axes)
        t = get(_cache, :t_win, Float64[])::Vector{Float64}
        isempty(t) && return

        # Saccade highlight
        sel_s = state.selected_saccade[]
        # Remove any previous polar highlight
        polar_plots = get!(_cache, :polar_plots, Any[])
        for p in filter(x -> x isa Lines, polar_plots)
            delete!(axes[2], p)
        end
        filter!(x -> !(x isa Lines), polar_plots)

        if sel_s > 0 && sel_s <= length(saccades)
            s = saccades[sel_s]
            _hl_sacc_spatial_pts[] = [Point2f(s.x1, s.y1), Point2f(s.x2, s.y2)]
            ti = clamp(s.time_idx, 1, length(t))
            _hl_sacc_xy_t[] = [t[ti]]
            _hl_sacc_vel_t[] = [t[ti]]
            # Add polar highlight line
            r_max = max(3.0, length(saccades) * 0.5)
            hl = lines!(
                axes[2],
                [s.angle, s.angle],
                [0.0, r_max];
                color = :red,
                linewidth = 2,
            )
            push!(polar_plots, hl)
            _hl_sacc_vis[] = true
        else
            _hl_sacc_vis[] = false
        end

        # Fixation highlight
        sel_f = state.selected_fixation[]
        if sel_f > 0 && sel_f <= length(fixations)
            f = fixations[sel_f]
            _hl_fix_spatial_pts[] = [Point2f(f.x, f.y)]
            _hl_fix_spatial_ms[] = max(3.0, min(f.dur / 10.0, 40.0))

            t_lo = t[clamp(f.time_start, 1, length(t))]
            t_hi = t[clamp(f.time_end, 1, length(t))]

            xy_h = _cache[:xy_bar_h]
            vel_h = _cache[:vel_bar_h]
            _hl_fix_xy_pts[] = Point2f[(t_lo, 0), (t_hi, 0), (t_hi, xy_h), (t_lo, xy_h)]
            _hl_fix_vel_pts[] = Point2f[(t_lo, 0), (t_hi, 0), (t_hi, vel_h), (t_lo, vel_h)]

            _hl_fix_vis[] = true
        else
            _hl_fix_vis[] = false
        end
    end



    # Helper: select or clear fixation
    function _toggle_fixation!(idx::Int, within_threshold::Bool)
        if within_threshold && state.selected_fixation[] == idx
            state.selected_fixation[] = 0   # toggle off
        elseif within_threshold
            state.selected_fixation[] = idx
            state.selected_saccade[] = 0
        else
            state.selected_fixation[] = 0
        end
        _update_highlight_overlay!()
    end

    # Helper: select or clear saccade
    function _toggle_saccade!(idx::Int, within_threshold::Bool)
        if within_threshold && state.selected_saccade[] == idx
            state.selected_saccade[] = 0   # toggle off
        elseif within_threshold
            state.selected_saccade[] = idx
            state.selected_fixation[] = 0
        else
            state.selected_saccade[] = 0
        end
        _update_highlight_overlay!()
    end

    # Spatial axis: click near fixation circle or saccade line
    register_interaction!(ax_spatial, :event_select) do event::MouseEvent, axis
        if event.type === MouseEventTypes.leftclick
            px, py = event.data[1], event.data[2]

            haskey(_cache, :saccades) || return Consume(false)
            saccades = get(_cache, :saccades_win, SaccadeInfo[])::Vector{SaccadeInfo}
            fixations = get(_cache, :fixations_win, FixationInfo[])::Vector{FixationInfo}

            # Check fixations first (distance to center)
            best_fix_dist = Inf
            best_fix_idx = 0
            for (fi, f) in enumerate(fixations)
                d = sqrt((px - f.x)^2 + (py - f.y)^2)
                if d < best_fix_dist
                    best_fix_dist = d
                    best_fix_idx = fi
                end
            end

            # Check saccades (distance to line)
            best_sacc_dist = Inf
            best_sacc_idx = 0
            for (si, s) in enumerate(saccades)
                d = _point_to_segment_dist(px, py, s.x1, s.y1, s.x2, s.y2)
                if d < best_sacc_dist
                    best_sacc_dist = d
                    best_sacc_idx = si
                end
            end

            # Select whichever is closer, with thresholds
            fix_ok = best_fix_dist < 40.0
            sacc_ok = best_sacc_dist < 30.0

            if fix_ok && (!sacc_ok || best_fix_dist <= best_sacc_dist)
                _toggle_fixation!(best_fix_idx, true)
            elseif sacc_ok
                _toggle_saccade!(best_sacc_idx, true)
            else
                state.selected_saccade[] = 0
                state.selected_fixation[] = 0
                _update_highlight_overlay!()
            end
            return Consume(true)
        end
        return Consume(false)
    end

    # Time-series helper: select saccade or fixation by time
    function _make_time_select_handler()
        return (event::MouseEvent, axis) -> begin
            if event.type === MouseEventTypes.leftclick
                click_t = event.data[1]

                haskey(_cache, :saccades) || return Consume(false)
                saccades =
                    get(_cache, :saccades_win, SaccadeInfo[])::Vector{SaccadeInfo}
                fixations =
                    get(_cache, :fixations_win, FixationInfo[])::Vector{FixationInfo}

                # Use cached windowed time (matches axes)
                t = get(_cache, :t_win, Float64[])::Vector{Float64}
                isempty(t) && return Consume(false)
                t_range = length(t) > 1 ? t[end] - t[1] : 1.0
                threshold = t_range * 0.02

                # Check saccades FIRST (nearest vline) — prioritize over fixations
                best_sacc_dist = Inf
                best_sacc_idx = 0
                for (si, s) in enumerate(saccades)
                    sacc_t = t[s.time_idx]
                    d = abs(click_t - sacc_t)
                    if d < best_sacc_dist
                        best_sacc_dist = d
                        best_sacc_idx = si
                    end
                end

                # Check fixations (click within time range)
                fix_idx = 0
                for (fi, f) in enumerate(fixations)
                    if t[f.time_start] <= click_t <= t[f.time_end]
                        fix_idx = fi
                        break
                    end
                end

                if best_sacc_dist < threshold
                    _toggle_saccade!(best_sacc_idx, true)
                elseif fix_idx > 0
                    _toggle_fixation!(fix_idx, true)
                else
                    state.selected_saccade[] = 0
                    state.selected_fixation[] = 0
                    _update_highlight_overlay!()
                end
                return Consume(true)
            end
            return Consume(false)
        end
    end

    register_interaction!(ax_xy, :event_select, _make_time_select_handler())
    register_interaction!(ax_vel, :event_select, _make_time_select_handler())

    # Polar axis: click to select nearest saccade by angle
    on(events(ax_polar.scene).mousebutton) do event
        if event.action == Mouse.press && event.button == Mouse.left
            # Check click is within polar axis viewport
            mpos = events(ax_polar.scene).mouseposition[]
            area = ax_polar.scene.viewport[]
            (
                area.origin[1] <= mpos[1] <= area.origin[1] + area.widths[1] &&
                area.origin[2] <= mpos[2] <= area.origin[2] + area.widths[2]
            ) || return Consume(false)
            # overlay returns Cartesian data coords (center at origin)
            mp = mouseposition(ax_polar.overlay)
            # Display angle in internal Cartesian space
            display_angle = atan(mp[2], mp[1])

            # Inverse PolarAxis transform: display = theta_0 + direction * data
            # theta_0=-π/2, direction=-1 → data = π/2 - display
            click_data_angle = π / 2 - display_angle

            haskey(_cache, :saccades) || return Consume(false)
            saccades = get(_cache, :saccades_win, SaccadeInfo[])::Vector{SaccadeInfo}
            isempty(saccades) && return Consume(false)

            # Find nearest saccade by angular distance
            best_dist = Inf
            best_idx = 0
            for (si, s) in enumerate(saccades)
                d = abs(mod(s.angle - click_data_angle + π, 2π) - π)
                if d < best_dist
                    best_dist = d
                    best_idx = si
                end
            end

            _toggle_saccade!(best_idx, best_dist < π / 6)
            return Consume(true)
        end
        return Consume(false)
    end

    # ── Initial draw ───────────────────────────────────────────────────────── #
    _cache = Dict{Symbol,Any}()
    _draw_all!(axes, df, state, trial_label, _cache; reset_zoom = true, window_start = 1)
    _add_cursor_dots!(axes, cursor_obs)
    _update_cursor!(cursor_obs, _cache, state)
    _create_overlay_plots!()

    # Figure layout columns and UI rows
    colsize!(fig.layout, 1, Relative(0.58))
    colsize!(fig.layout, 2, Relative(0.42))
    colgap!(fig.layout, 8)

    colsize!(slider_controls, 2, Relative(1.05))

    # Proportion main rows: 90% for plots, 10% for UI controls
    rowsize!(fig.layout, 1, Relative(0.90))
    rowsize!(fig.layout, 2, Relative(0.10))

    # Left column row heights: Spatial gets 2.0, Polar gets 1.25
    rowsize!(g_left, 1, Auto(2.0))
    rowsize!(g_left, 2, Auto(1.25))

    # Right column row heights: Position plot twice as high as Velocity and Pupil
    rowsize!(g_right, 1, Auto(2.0))
    rowsize!(g_right, 2, Auto(1.0))
    rowsize!(g_right, 3, Auto(1.0))



    if display_plot
        display(fig)
    end

    return fig, state
end
