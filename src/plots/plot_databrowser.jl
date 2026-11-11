function _match_stimulus_key(filename::AbstractString, stim_dict::Dict, stim_keys::Vector)
    clean_val_with_ext = split(filename, r"[/\\]")[end]
    haskey(stim_dict, clean_val_with_ext) && return clean_val_with_ext
    clean_val_no_ext = lowercase(splitext(clean_val_with_ext)[1])
    for k in stim_keys
        if lowercase(splitext(k)[1]) == clean_val_no_ext
            return k
        end
    end
    return nothing
end

function _parse_imgload_directive(
    msg::AbstractString,
    stim_dict::Dict,
    stim_keys::Vector,
    sx::Real,
    sy::Real,
)::Union{Nothing,AbstractEyeFunMedia}
    occursin("IMGLOAD", msg) || return nothing
    parts = split(msg)
    idx = findfirst(==("IMGLOAD"), parts)
    (isnothing(idx) || length(parts) < idx + 2) && return nothing

    pos_cmd = parts[idx+1]
    filename = ""
    cx, cy = Float64(sx) / 2, Float64(sy) / 2
    topleft = false
    pos_x, pos_y = 0.0, 0.0

    if pos_cmd == "CENTER" || pos_cmd == "FILL"
        filename = parts[end]
    elseif pos_cmd == "TOP_LEFT" || pos_cmd == "TOPLEFT"
        filename = parts[end]
        topleft = true
    else
        px = tryparse(Float64, pos_cmd)
        py = tryparse(Float64, get(parts, idx + 2, ""))
        if !isnothing(px) && !isnothing(py) && length(parts) >= idx + 3
            filename = join(parts[(idx+3):end], " ")
            pos_x, pos_y = px, py
            topleft = true
        else
            filename = parts[end]
        end
    end
    isempty(filename) && return nothing

    match_k = _match_stimulus_key(filename, stim_dict, stim_keys)
    isnothing(match_k) && return nothing

    val = stim_dict[match_k]
    if topleft
        @debug "Parsed IMGLOAD top-left layout" pos_x pos_y match_k
        if val isa AbstractMatrix
            h, w = size(val)
            cx, cy = pos_x + w / 2, pos_y + h / 2
        elseif val isa AbstractString && isfile(val)
            h, w = image_size(val)
            cx, cy = pos_x + w / 2, pos_y + h / 2
        else
            cx, cy = pos_x, pos_y
        end
    else
        @debug "Parsed IMGLOAD centered layout" match_k
    end
    return _to_media_item((val, (cx, cy)), sx, sy)
end

function _discover_segment_stimuli(
    trial_df::AbstractDataFrame,
    stim_dict::Dict,
    stim_keys::Vector,
    sx::Real,
    sy::Real,
)
    matched_media = AbstractEyeFunMedia[]

    if hasproperty(trial_df, :message)
        for msg in skipmissing(trial_df.message)
            item = _parse_imgload_directive(msg, stim_dict, stim_keys, sx, sy)
            !isnothing(item) && push!(matched_media, item)
        end
    end

    if isempty(matched_media)
        row = trial_df[1, :]
        for col in names(row)
            val = row[col]
            ismissing(val) && continue
            val_str = strip(string(val))
            isempty(val_str) && continue
            match_k = _match_stimulus_key(val_str, stim_dict, stim_keys)
            if !isnothing(match_k)
                item = _to_media_item(stim_dict[match_k], sx, sy)
                if !isnothing(item)
                    push!(matched_media, item)
                    @debug "Found variable stimulus" match_k
                end
            end
        end
    end

    unique!(matched_media)
    if isempty(matched_media)
        @debug "No stimulus media found in IMGLOAD or variables"
        return nothing
    end
    return matched_media
end

function _make_bg_stimulus_callback(
    df::EyeData,
    split_by::Union{Nothing,Symbol,Vector{Symbol}},
    seg_lookup::Dict{Any,AbstractDataFrame},
    stimuli::Union{Nothing,Dict},
    match_stimuli::Union{Nothing,Function},
    sx::Real,
    sy::Real,
)
    stim_dict = isnothing(stimuli) ? Dict{String,Any}() : stimuli
    cached_vars = !isnothing(match_stimuli) ? variables(df) : nothing
    stim_keys = collect(keys(stim_dict))

    return function (segment_id)
        if !isnothing(match_stimuli)
            all_vars = cached_vars::DataFrame
            segment_vars = if split_by isa Symbol || isnothing(split_by)
                col = isnothing(split_by) ? :trial : split_by
                hasproperty(all_vars, col) ?
                filter(r -> (!ismissing(r[col]) && r[col] == segment_id), all_vars) :
                DataFrame()
            else
                cols = Symbol.(split_by)
                all(c -> hasproperty(all_vars, c), cols) ?
                filter(
                    r -> Tuple(r[c] for c in cols) == Tuple(segment_id[c] for c in cols),
                    all_vars,
                ) : DataFrame()
            end

            row_arg = if nrow(segment_vars) > 0
                segment_vars[1, :]
            else
                tdf = get(seg_lookup, segment_id, nothing)
                (isnothing(tdf) || nrow(tdf) == 0) && return nothing
                tdf[1, :]
            end

            return applicable(match_stimuli, row_arg, stim_dict) ?
                   match_stimuli(row_arg, stim_dict) :
                   match_stimuli(row_arg)
        end

        trial_df = get(seg_lookup, segment_id, nothing)
        (isnothing(trial_df) || nrow(trial_df) == 0) && return nothing
        return _discover_segment_stimuli(trial_df, stim_dict, stim_keys, sx, sy)
    end
end

function _play_segment_audio(state::EyeViewerMediaState)
    isnothing(state.bg_stimulus) && return
    try
        segment_id = state.segments[state.trial[]]
        stim_vals = state.bg_stimulus(segment_id)
        isnothing(stim_vals) && return
        sx, sy = state.screen_res
        media_items = _normalize_media_items(stim_vals, sx, sy)

        # Concatenate in-memory audio buffers into a single stream to avoid ALSA lock contention
        audio_buffers = Any[]
        audio_fs = nothing
        audio_paths = String[]
        for item in media_items
            item isa AudioMedia || continue
            if item.content isa Tuple
                push!(audio_buffers, item.content[1])
                audio_fs = item.content[2]
            elseif item.content isa AbstractString
                push!(audio_paths, item.content)
            end
        end

        if !isempty(audio_paths)
            @async begin
                for i in eachindex(audio_paths)
                    wait(play_wav(audio_paths[i]))
                    i < length(audio_paths) && sleep(0.3)
                end
            end
        end
        if !isempty(audio_buffers) && !isnothing(audio_fs)
            n_sil = round(Int, 0.3 * audio_fs)
            first_buf = audio_buffers[1]
            silence =
                ndims(first_buf) == 1 ? zeros(Float64, n_sil) :
                zeros(Float64, n_sil, size(first_buf, 2))
            combined = first_buf
            for i = 2:length(audio_buffers)
                combined = vcat(combined, silence, audio_buffers[i])
            end
            play_wav((combined, audio_fs))
        end
    catch e
        @warn "Failed to play segment audio" exception = e
    end
end

"""
    plot_databrowser(df::EyeData; eye=:auto, split_by=nothing, aois=nothing,
                     bg_stimulus=nothing, stimuli=nothing, match_stimuli=nothing,
                     prefix=nothing, display_plot=true) -> (Figure, EyeViewerMediaState)

Open an interactive eye-tracking data viewer and return `(fig, state)`.

# Keyword Arguments
- `eye`: Which eye to use: `:auto` (default), `:left`, `:right`, or `:both`.
- `split_by`: How to segment data for browsing.
  - `nothing` (default): show entire DataFrame as one continuous view
  - `:trial`: one page per trial
  - `[:block, :trial]`: multi-level grouping
- `aois`: Optional `Vector{<:AOI}` overlaid on the spatial view.
- `bg_stimulus`: A function `segment_id -> Vector{AbstractEyeFunMedia}` (or a single
  media object) that provides per-trial background stimuli. Supports `ImageMedia`,
  `AudioMedia`, and `TextMedia` objects.
- `stimuli`: A `Dict{String, Any}` of pre-loaded assets (from `read_stimuli`) used
  together with `match_stimuli` for automatic per-trial lookup.
- `match_stimuli`: A function `row -> Vector{AbstractEyeFunMedia}` or
  `(row, stimuli) -> Vector{AbstractEyeFunMedia}`, where `row` is the `DataFrameRow`
  of trial variables (from `variables(df)`, or the first sample row of the segment),
  used to bind entries in `stimuli` to each segment.
- `prefix`: Optional column prefix (`Symbol`) for custom event columns (e.g. `:alg`).
- `display_plot`: Whether to immediately call `display(fig)` (default `true`).

# Layout
- **Left**: Spatial gaze view (gaze position on screen with optional stimulus overlay)
- **Top right**: Polar rose chart of saccade directions
- **Middle top**: XY position trace over time
- **Middle bottom**: Gaze velocity over time
- **Bottom**: Pupil size over time

# Controls
- **◀ / ▶ buttons**: Navigate to previous/next segment
- **Textbox**: Type a value and press Enter to jump directly (single-column split only)
- **Sample slider**: Drag to scrub through samples; black dots track position
- **Play/Pause**: Animate through samples; speed slider controls playback rate
- **Checkboxes**: Toggle samples, heatmap, saccades, fixations, blinks, messages, AOIs
- **Space**: Play attached audio (when `bg_stimulus` provides an `AudioMedia`)

# Keyboard
- `←`/`→`: Previous/next segment
- `r`: Reset zoom to default

# Example
```julia
using EyeFun, GLMakie

df = read_et_data("data.edf"; trial_time_zero="TRIALID")
fig, state = plot_databrowser(df)
fig, state = plot_databrowser(df; split_by=:trial)
fig, state = plot_databrowser(df; split_by=[:block, :trial])

# With background stimuli matched from a trial variable column `row.image`
stim = read_stimuli("/path/to/stimuli")
fig, state = plot_databrowser(df; split_by=:trial, stimuli=stim,
                              match_stimuli=(row, stim) -> [ImageMedia(content=stim[row.image])])
```
"""
function plot_databrowser(
    df::EyeData;
    eye::Symbol = :auto,
    split_by::Union{Nothing,Symbol,Vector{Symbol}} = nothing,
    aois::Union{Nothing,Vector{<:AOI}} = nothing,
    bg_stimulus::Any = nothing,
    stimuli::Union{Nothing,Dict} = nothing,
    match_stimuli::Union{Nothing,Function} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
    display_plot::Bool = true,
)
    resolved_eye = _resolve_eye(df, eye)
    if resolved_eye === :both
        _check_and_merge_eye_coords(df.df, :gxL, :gxR, df.coords)
        _check_and_merge_eye_coords(df.df, :gyL, :gyR, df.coords)
    end
    ecols = _eye_columns(resolved_eye)
    gx_col, gy_col, pa_col = ecols.gx, ecols.gy, ecols.pa
    coord_mode = _col_coord_mode(df.df, gx_col, df.coords)
    ppd_val = Float64(pixels_per_degree(df))
    unit_lbl = coord_mode === :deg ? "°" : "px"
    sx, sy = df.screen_res

    # Pre-group segments for trial switching and stimulus lookup
    if isnothing(split_by)
        segments = Any[1]  # single pseudo-segment
        segment_views = AbstractDataFrame[df.df]
    elseif split_by isa Symbol
        gd = groupby(df.df, split_by; sort = true, skipmissing = true)
        segments = Any[k[1] for k in keys(gd)]
        segment_views = AbstractDataFrame[gd[i] for i = 1:length(gd)]
    else
        cols = Symbol.(split_by)
        gd = groupby(df.df, cols; sort = true, skipmissing = true)
        segments = Any[NamedTuple{Tuple(cols)}(Tuple(k)) for k in keys(gd)]
        segment_views = AbstractDataFrame[gd[i] for i = 1:length(gd)]
    end
    isempty(segments) && error("No segments found in DataFrame for split_by=$(split_by).")
    seg_lookup = Dict{Any,AbstractDataFrame}(
        segments[i] => segment_views[i] for i in eachindex(segments)
    )

    if !isnothing(stimuli) || !isnothing(match_stimuli)
        bg_stimulus = _make_bg_stimulus_callback(
            df,
            split_by,
            seg_lookup,
            stimuli,
            match_stimuli,
            sx,
            sy,
        )
    end

    g_first = segment_views[1]
    auto_window = isnothing(split_by) && nrow(g_first) > 5000 ? 5000 : 0

    state = EyeViewerMediaState(;
        segments,
        split_by,
        screen_res = df.screen_res,
        eye = resolved_eye,
        gx_col,
        gy_col,
        pa_col,
        window_samples = auto_window,
        aois,
        bg_stimulus,
        segment_views,
        prefix,
        coord_mode,
        ppd = ppd_val,
    )

    fig = Figure(size = (1920, 1080), padding = (0, 0, 0, 0))

    g_left = fig[1, 1] = GridLayout()
    g_right = fig[1, 2] = GridLayout()

    # Left column: spatial (row 1) + polar (row 2)
    ax_spatial = Axis(
        g_left[1, 1];
        xlabel = "X ($unit_lbl)",
        ylabel = "Y ($unit_lbl)",
        aspect = DataAspect(),
        yreversed = true,
        title = "Gaze Position",
        xgridvisible = false,
        ygridvisible = false,
        halign = :left,
    )

    ax_polar = PolarAxis(
        g_left[2, 1];
        title = "Saccade Directions",
        theta_0 = -π / 2,
        direction = -1,
        thetaticklabelsize = 10,
        rtickangle = π / 6,
        rticklabelsize = 10,
    )

    # Right column: time-series (rows 1:3)
    ax_xy = Axis(
        g_right[1, 1];
        ylabel = "Position ($unit_lbl)",
        xgridvisible = false,
        ygridvisible = false,
    )
    hidexdecorations!(ax_xy; label = true)

    ax_vel = Axis(
        g_right[2, 1];
        ylabel = "Velocity (°/s)",
        xgridvisible = false,
        ygridvisible = false,
    )
    hidexdecorations!(ax_vel; label = true)

    ax_pup = Axis(
        g_right[3, 1];
        xlabel = "Time (ms)",
        ylabel = "Pupil",
        xgridvisible = false,
        ygridvisible = false,
    )

    linkxaxes!(ax_xy, ax_vel, ax_pup)

    axes = [ax_spatial, ax_polar, ax_xy, ax_vel, ax_pup]

    _cache = Dict{Symbol,Any}()
    cursor_obs = Dict(
        :spatial_pts => Observable(Point2f[(0, 0)]),
        :xy_x_pt => Observable(Point2f[(0, 0)]),
        :xy_y_pt => Observable(Point2f[(0, 0)]),
        :vel_pts => Observable(Point2f[(0, 0)]),
        :pup_pts => Observable(Point2f[(0, 0)]),
    )

    # Persistent selection highlight observables
    _hl_sacc_spatial_pts = Observable(Point2f[])
    _hl_sacc_xy_t = Observable(Float64[])
    _hl_sacc_vel_t = Observable(Float64[])
    _hl_sacc_vis = Observable(false)

    _hl_fix_spatial_pts = Observable(Point2f[])
    _hl_fix_spatial_ms = Observable(10.0)
    _hl_fix_xy_pts = Observable(Point2f[(0, 0), (0, 0), (0, 0), (0, 0)])
    _hl_fix_vel_pts = Observable(Point2f[(0, 0), (0, 0), (0, 0), (0, 0)])
    _hl_fix_vis = Observable(false)

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
        if !haskey(_cache, :saccades_win)
            _hl_sacc_vis[] = false
            _hl_fix_vis[] = false
            return
        end
        saccades = _cache[:saccades_win]::Vector{SaccadeInfo}
        fixations = get(_cache, :fixations_win, FixationInfo[])::Vector{FixationInfo}

        t = get(_cache, :t_win, Float64[])::Vector{Float64}
        if isempty(t)
            _hl_sacc_vis[] = false
            _hl_fix_vis[] = false
            return
        end

        sel_s = state.selected_saccade[]
        if state.show_saccades[] && sel_s > 0 && sel_s <= length(saccades)
            s = saccades[sel_s]
            _hl_sacc_spatial_pts[] = [Point2f(s.x1, s.y1), Point2f(s.x2, s.y2)]
            ti = clamp(s.time_idx, 1, length(t))
            _hl_sacc_xy_t[] = [t[ti]]
            _hl_sacc_vel_t[] = [t[ti]]
            _hl_sacc_vis[] = true
        else
            _hl_sacc_vis[] = false
        end

        sel_f = state.selected_fixation[]
        if state.show_fixations[] && sel_f > 0 && sel_f <= length(fixations)
            f = fixations[sel_f]
            _hl_fix_spatial_pts[] = [Point2f(f.x, f.y)]
            _hl_fix_spatial_ms[] = max(3.0, min(f.dur / 10.0, 40.0))

            t_lo = t[clamp(f.time_start, 1, length(t))]
            t_hi = t[clamp(f.time_end, 1, length(t))]

            xy_h = Float64(get(_cache, :xy_bar_h, 0.0))
            vel_h = Float64(get(_cache, :vel_bar_h, 0.0))
            _hl_fix_xy_pts[] = Point2f[(t_lo, 0), (t_hi, 0), (t_hi, xy_h), (t_lo, xy_h)]
            _hl_fix_vel_pts[] = Point2f[(t_lo, 0), (t_hi, 0), (t_hi, vel_h), (t_lo, vel_h)]

            _hl_fix_vis[] = true
        else
            _hl_fix_vis[] = false
        end
    end

    function _refresh_view!(;
        full::Bool = false,
        reset_zoom::Bool = false,
        window_start::Int = 1,
    )
        if full
            _db_draw_all!(
                axes,
                df,
                state,
                trial_label,
                _cache;
                reset_zoom = reset_zoom,
                window_start = window_start,
            )
        else
            _db_redraw_window!(
                axes,
                state,
                _cache;
                reset_zoom = reset_zoom,
                window_start = window_start,
            )
        end
        _db_add_cursor_dots!(axes, cursor_obs)
        _db_update_cursor!(cursor_obs, _cache, state)
        _create_overlay_plots!()
        _update_highlight_overlay!()
        return nothing
    end

    # Left column (under spatial): navigation + toggles
    left_controls = fig[2, 1] = GridLayout(valign = :top)

    trial_label = Observable(_db_segment_label(state))
    window_view_obs = Observable(state.window_samples > 0)

    col = 1
    if isnothing(state.split_by)
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
            placeholder = "Jump...",
            width = 70,
            stored_string = nothing,
            tellwidth = true,
            reset_on_defocus = true,
        )
        col += 1
    end

    # Scrubber area: sliders in column 2 aligned with time-series plots
    slider_controls = fig[2, 2] = GridLayout(valign = :top)

    g1 = state.segment_views[1]
    n_samples_init = max(1, nrow(g1))
    ws = state.window_samples
    _is_windowed = ws > 0 && n_samples_init > ws

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

    Label(
        slider_controls[2, 1],
        "Speed:";
        fontsize = 11,
        halign = :right,
        tellwidth = false,
    )
    sample_rate = max(1, round(Int, df.sample_rate > 0.0 ? df.sample_rate : 1000.0))
    realtime_step = max(1, round(Int, sample_rate / 30))
    max_speed = realtime_step * 2
    sl_speed = Slider(
        slider_controls[2, 2];
        range = 1:1:max_speed,
        startvalue = realtime_step,
        snap = true,
        tellwidth = false,
    )

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

    toggles = [
        ("Samples", state.show_samples),
        ("Heatmap", state.show_heatmap),
        ("Fixations", state.show_fixations),
        ("Saccades", state.show_saccades),
        ("Blinks", state.show_blinks),
        ("Messages", state.show_messages),
    ]

    if !isnothing(state.aois) && !isempty(state.aois)
        push!(toggles, ("AOIs", state.show_aois))
    end

    tcol = 0
    for (label, obs) in toggles
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
            _refresh_view!(window_start = round(Int, sl_scroll.value[]))
        end
    end
    colgap!(left_controls, 4)
    rowgap!(left_controls, 4)

    _suppress_slider_cb = Ref(false)

    on(window_view_obs) do is_win
        btn_scroll_play.blockscene.visible = is_win && isnothing(state.split_by)
        sl_scroll.blockscene.visible = is_win && isnothing(state.split_by)

        state.window_samples = is_win ? 5000 : 0
        ws = state.window_samples
        n = max(1, nrow(state.segment_views[state.trial[]]))

        frame_range = (ws > 0 && n > ws) ? ws : n
        _suppress_slider_cb[] = true
        try
            sl_frame.range[] = 1:frame_range
            if ws > 0 && n > ws
                sl_scroll.range[] = 1:max(1, n-ws+1)
                set_close_to!(sl_scroll, 1)
            end
        finally
            _suppress_slider_cb[] = false
        end

        _refresh_view!(reset_zoom = true, window_start = 1)
    end

    btn_scroll_play.blockscene.visible = window_view_obs[] && isnothing(state.split_by)
    sl_scroll.blockscene.visible = window_view_obs[] && isnothing(state.split_by)

    # Play/pause states & generation counters so rapid clicks never spawn duplicate loops
    _playing = Observable(false)
    _scroll_playing = Observable(false)
    _play_gen = Ref(0)
    _scroll_gen = Ref(0)
    _had_open_window = Ref(events(fig).window_open[])

    on(events(fig).window_open) do is_open
        if is_open
            _had_open_window[] = true
        else
            _playing[] = false
            _scroll_playing[] = false
            _play_gen[] += 1
            _scroll_gen[] += 1
        end
    end

    on(btn_play.clicks) do _
        _playing[] = !_playing[]
        _play_gen[] += 1
        my_gen = _play_gen[]
        btn_play.label[] = _playing[] ? "||" : "▶"
        if _playing[]
            @async begin
                while _playing[] &&
                          _play_gen[] == my_gen &&
                          (!_had_open_window[] || events(fig).window_open[])
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

    on(btn_scroll_play.clicks) do _
        _scroll_playing[] = !_scroll_playing[]
        _scroll_gen[] += 1
        my_gen = _scroll_gen[]
        btn_scroll_play.label[] = _scroll_playing[] ? "||" : "▶"
        if _scroll_playing[]
            @async begin
                while _scroll_playing[] &&
                          _scroll_gen[] == my_gen &&
                          (!_had_open_window[] || events(fig).window_open[])
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

    function _goto_trial!(idx::Int)
        idx = clamp(idx, 1, length(state.segments))
        _playing[] = false
        _play_gen[] += 1
        btn_play.label[] = "▶"
        _scroll_playing[] = false
        _scroll_gen[] += 1
        btn_scroll_play.label[] = "▶"
        state.trial[] = idx
        state.selected_saccade[] = 0
        state.selected_fixation[] = 0
        g = state.segment_views[idx]
        n = max(1, nrow(g))

        ws = state.window_samples
        _suppress_slider_cb[] = true
        try
            if ws > 0 && n > ws
                sl_scroll.range[] = 1:max(1, n-ws+1)
                set_close_to!(sl_scroll, 1)
                sl_frame.range[] = 1:ws
            else
                sl_frame.range[] = 1:n
            end
            set_close_to!(sl_frame, 1)
        finally
            _suppress_slider_cb[] = false
        end
        state.frame[] = 1
        w_start = ws > 0 && n > ws ? round(Int, sl_scroll.value[]) : 1
        _refresh_view!(full = true, reset_zoom = true, window_start = w_start)
    end

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

    if !isnothing(tb_trial)
        on(tb_trial.stored_string) do s
            isnothing(s) && return
            st = strip(s)
            isempty(st) && return
            trial_num = tryparse(Int, st)
            idx = nothing
            if !isnothing(trial_num)
                idx = findfirst(seg -> isequal(seg, trial_num), state.segments)
                if isnothing(idx) && 1 <= trial_num <= length(state.segments)
                    idx = trial_num
                end
            end
            if isnothing(idx)
                st_low = lowercase(st)
                idx = findfirst(state.segments) do seg
                    if seg isa NamedTuple
                        lbl1 = lowercase(join([string(v) for v in values(seg)], "/"))
                        lbl2 = lowercase(join([string(v) for v in values(seg)], " "))
                        return st_low == lbl1 || st_low == lbl2
                    else
                        return lowercase(string(seg)) == st_low
                    end
                end
            end
            if !isnothing(idx)
                _goto_trial!(idx)
            end
        end
    end

    on(sl_frame.value) do f
        _suppress_slider_cb[] && return
        w_start = get(_cache, :window_start, 1)
        state.frame[] = w_start + f - 1
        _db_update_cursor!(cursor_obs, _cache, state)
    end

    on(sl_scroll.value) do w
        _suppress_slider_cb[] && return
        w_start = round(Int, w)
        state.frame[] = w_start + sl_frame.value[] - 1
        _refresh_view!(window_start = w_start)
    end

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
                _refresh_view!(
                    reset_zoom = true,
                    window_start = get(_cache, :window_start, 1),
                )
                return Consume(true)
            elseif event.key == Keyboard.escape
                state.selected_saccade[] = 0
                state.selected_fixation[] = 0
                _update_highlight_overlay!()
                return Consume(true)
            elseif event.key == Keyboard.space && event.action == Keyboard.press
                _play_segment_audio(state)
                return Consume(true)
            end
        end
        return Consume(false)
    end

    function _toggle_fixation!(idx::Int)
        if state.selected_fixation[] == idx
            state.selected_fixation[] = 0
        else
            state.selected_fixation[] = idx
            state.selected_saccade[] = 0
        end
        _update_highlight_overlay!()
    end

    function _toggle_saccade!(idx::Int)
        if state.selected_saccade[] == idx
            state.selected_saccade[] = 0
        else
            state.selected_saccade[] = idx
            state.selected_fixation[] = 0
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

            # Select whichever is closer, with coordinate-aware thresholds
            click_scale = (state.coord_mode === :deg && state.ppd > 0.0) ? (1.0 / state.ppd) : 1.0
            fix_ok = state.show_fixations[] && best_fix_dist < 40.0 * click_scale
            sacc_ok = state.show_saccades[] && best_sacc_dist < 30.0 * click_scale

            if fix_ok && (!sacc_ok || best_fix_dist <= best_sacc_dist)
                _toggle_fixation!(best_fix_idx)
            elseif sacc_ok
                _toggle_saccade!(best_sacc_idx)
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

                t = get(_cache, :t_win, Float64[])::Vector{Float64}
                isempty(t) && return Consume(false)
                t_range = length(t) > 1 ? t[end] - t[1] : 1.0
                threshold = t_range * 0.02

                # Check saccades first (nearest vline), prioritizing over fixations
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

                if state.show_saccades[] && best_sacc_dist < threshold
                    _toggle_saccade!(best_sacc_idx)
                elseif state.show_fixations[] && fix_idx > 0
                    _toggle_fixation!(fix_idx)
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

    _refresh_view!(full = true, reset_zoom = true, window_start = 1)

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
