"""
    plot_databrowser(df::EyeData; eye=:auto, split_by=nothing, aois=nothing,
                     bg_stimulus=nothing, stimuli=nothing, match_stimuli=nothing)

Open an interactive eye-tracking data viewer.

# Keyword Arguments
- `eye`: Which eye to use — `:auto` (default), `:left`, or `:right`.
- `split_by`: How to segment data for browsing.
  - `nothing` (default) — show entire DataFrame as one continuous view
  - `:trial` — one page per trial
  - `[:block, :trial]` — multi-level grouping
- `aois`: Optional `Vector{<:AOI}` — AOI overlays drawn on the spatial view.
- `bg_stimulus`: A function `segment_id -> Vector{AbstractEyeFunMedia}` (or a single
  media object) that provides per-trial background stimuli. Supports `ImageMedia`,
  `AudioMedia`, and `TextMedia` objects.
- `stimuli`: A `Dict{String, Any}` of pre-loaded assets (from `read_stimuli`) used
  together with `match_stimuli` for automatic per-trial lookup.
- `match_stimuli`: A function `segment_id -> Vector{AbstractEyeFunMedia}` used to
  bind entries in the `stimuli` dict to trials.

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
df = read_et_data("data.edf"; trial_time_zero="TRIALID")
plot_databrowser(df)
plot_databrowser(df; split_by=:trial)
plot_databrowser(df; split_by=[:block, :trial])

# With background stimuli
stim = read_stimuli("/path/to/stimuli")
plot_databrowser(df; split_by=:trial, stimuli=stim,
                 match_stimuli=id -> [ImageMedia(content=stim["\$id.png"])])
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
    display_plot::Bool = true,
)

    # Resolve eye
    resolved_eye = _resolve_eye(df, eye)
    gx_col = resolved_eye == :left ? :gxL : :gxR
    gy_col = resolved_eye == :left ? :gyL : :gyR
    pa_col = resolved_eye == :left ? :paL : :paR

    if !isnothing(stimuli)
        bg_stimulus = function (segment_id)
            # User-provided layout parser
            if !isnothing(match_stimuli)
                # Get trial variables for this segment
                all_vars = EyeFun.variables(df)
                segment_vars = if split_by isa Symbol || isnothing(split_by)
                    col = isnothing(split_by) ? :trial : split_by
                    filter(r -> (!ismissing(r[col]) && r[col] == segment_id), all_vars)
                else
                    cols = Symbol.(split_by)
                    filter(
                        r ->
                            Tuple(r[c] for c in cols) == Tuple(segment_id[c] for c in cols),
                        all_vars,
                    )
                end

                # Check for completely missing segments
                nrow(segment_vars) == 0 && return nothing

                return match_stimuli(segment_vars[1, :], stimuli)
            end

            # Standard Fallback: Auto-discovery logic
            trial_df = _dbnew_get_segment_data(df, segment_id, split_by)
            nrow(trial_df) == 0 && return nothing

            matched_media = Any[]
            row = trial_df[1, :]

            stim_keys = collect(keys(stimuli))

            # Auto-discovery: 1. Scan message log for !V IMGLOAD directives
            if hasproperty(trial_df, :message)
                for msg in skipmissing(trial_df.message)
                    if occursin("IMGLOAD", msg)
                        parts = split(msg)
                        idx = findfirst(x -> x == "IMGLOAD", parts)
                        if !isnothing(idx) && length(parts) >= idx + 2
                            pos_cmd = parts[idx+1]

                            filename = ""
                            cx, cy = sx / 2, sy / 2  # Default to center
                            topleft = false
                            pos_x, pos_y = nothing, nothing

                            if pos_cmd == "CENTER" || pos_cmd == "FILL"
                                filename = length(parts) > idx + 1 ? parts[end] : ""
                            elseif pos_cmd == "TOP_LEFT" || pos_cmd == "TOPLEFT"
                                filename = length(parts) > idx + 1 ? parts[end] : ""
                                pos_x, pos_y = 0.0, 0.0
                                topleft = true
                            else
                                # Check if it's explicit coordinates: IMGLOAD X Y file.png
                                px = tryparse(Float64, parts[idx+1])
                                py = tryparse(Float64, get(parts, idx + 2, ""))
                                if !isnothing(px) &&
                                   !isnothing(py) &&
                                   length(parts) >= idx + 3
                                    filename = join(parts[(idx+3):end], " ")
                                    pos_x, pos_y = px, py
                                    topleft = true
                                else
                                    filename = parts[end]
                                end
                            end

                            if !isempty(filename)
                                clean_val_with_ext = split(filename, r"[/\\]")[end]
                                clean_val_no_ext = splitext(clean_val_with_ext)[1]

                                match_k = nothing
                                if haskey(stimuli, clean_val_with_ext)
                                    match_k = clean_val_with_ext
                                else
                                    for k in stim_keys
                                        if lowercase(splitext(k)[1]) ==
                                           lowercase(clean_val_no_ext)
                                            match_k = k
                                            break
                                        end
                                    end
                                end

                                if !isnothing(match_k)
                                    if topleft && !isnothing(pos_x) && !isnothing(pos_y)
                                        println(
                                            "✨ [Auto-Discovery] Parsed IMGLOAD Top-Left Layout at X=$(pos_x), Y=$(pos_y) for ",
                                            match_k,
                                        )
                                        # Convert top-left hook to center geometry (w/2, h/2 offset)
                                        mat = stimuli[match_k]
                                        if mat isa AbstractMatrix
                                            w, h = size(rotr90(mat))
                                            push!(
                                                matched_media,
                                                (mat, (pos_x + w / 2, pos_y + h / 2)),
                                            )
                                        else
                                            push!(matched_media, (mat, (pos_x, pos_y)))
                                        end
                                    else
                                        println(
                                            "✨ [Auto-Discovery] Parsed IMGLOAD Centered Layout (Screen Center) for ",
                                            match_k,
                                        )
                                        push!(matched_media, (stimuli[match_k], (cx, cy)))
                                    end
                                end
                            end
                        end
                    end
                end
            end

            # Auto-discovery: 2. Fallback to generic variable metadata strings
            if isempty(matched_media)
                for col in names(row)
                    val = row[col]
                    ismissing(val) && continue

                    val_str = strip(string(val))
                    isempty(val_str) && continue

                    clean_val_with_ext = split(val_str, r"[/\\]")[end]
                    clean_val_no_ext = splitext(clean_val_with_ext)[1]

                    if haskey(stimuli, clean_val_with_ext)
                        push!(matched_media, stimuli[clean_val_with_ext])
                        println(
                            "✨ [Auto-Discovery] Found Generic Variable Stimulus: ",
                            clean_val_with_ext,
                        )
                        continue
                    end

                    for k in stim_keys
                        if lowercase(splitext(k)[1]) == lowercase(clean_val_no_ext)
                            if k != clean_val_with_ext
                                push!(matched_media, stimuli[k])
                                println(
                                    "✨ [Auto-Discovery] Found Generic Variable Stimulus: ",
                                    k,
                                    " (Fuzzy)",
                                )
                            end
                        end
                    end
                end
            end

            matched_media = unique(matched_media)
            if isempty(matched_media)
                println("❌ [Auto-Discovery] No media directives found in IMGLOAD or Variables.")
                return nothing
            end

            return matched_media
        end
    end

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
    g_first = _dbnew_get_segment_data(df, segments[1], split_by)
    auto_window = isnothing(split_by) && nrow(g_first) > 5000 ? 5000 : 0

    # Create state
    state = EyeViewerMediaState(
        Observable(1),          # segment index
        Observable(1),          # frame
        Observable(true),       # show_samples
        Observable(false),      # show_heatmap
        Observable(true),       # show_saccades
        Observable(true),       # show_fixations
        Observable(false),      # show_blinks
        Observable(false),      # show_messages
        Observable(true),       # show_aois
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
        auto_window,            # window_samples
        aois,                   # aois
        bg_stimulus,               # bg_stimulus
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
    trial_label = Observable(_dbnew_segment_label(state))
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

    # Only add the AOI checkbox if AOIs were actually provided
    if !isnothing(state.aois) && !isempty(state.aois)
        push!(toggles, ("AOIs", state.show_aois))
    end

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
            _dbnew_draw_all!(
                axes,
                df,
                state,
                trial_label,
                _cache;
                window_start = isnothing(sl_scroll) ? 1 : round(Int, sl_scroll.value[]),
            )
            _dbnew_add_cursor_dots!(axes, cursor_obs)
            _dbnew_update_cursor!(cursor_obs, _cache, state)
            _create_overlay_plots!()
        end
    end
    colgap!(left_controls, 4)
    rowgap!(left_controls, 4)

    # Scrubber area: sliders in column 2 aligned exactly with plots
    slider_controls = fig[2, 2] = GridLayout(valign = :top)

    g1 = _dbnew_get_segment_data(df, state.segments[1], state.split_by)
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
            nrow(
                _dbnew_get_segment_data(df, state.segments[state.trial[]], state.split_by),
            ),
        )

        frame_range = (ws > 0 && n > ws) ? ws : n
        sl_frame.range[] = 1:frame_range

        if ws > 0 && n > ws
            sl_scroll.range[] = 1:max(1, n-ws+1)
            # Avoid triggering the slider hook synchronously if possible, safely bypass set_close_to! cascade
            sl_scroll.value.val = 1
        end

        _dbnew_redraw_window!(axes, state, _cache; reset_zoom = true, window_start = 1)
        _dbnew_add_cursor_dots!(axes, cursor_obs)
        _dbnew_update_cursor!(cursor_obs, _cache, state)
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
        g = _dbnew_get_segment_data(df, state.segments[idx], state.split_by)
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
        _dbnew_draw_all!(
            axes,
            df,
            state,
            trial_label,
            _cache;
            reset_zoom = true,
            window_start = w_start,
        )
        _dbnew_add_cursor_dots!(axes, cursor_obs)
        _dbnew_update_cursor!(cursor_obs, _cache, state)
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
        _dbnew_update_cursor!(cursor_obs, _cache, state)
    end

    # Scroll slider — changes visible window
    if !isnothing(sl_scroll)
        on(sl_scroll.value) do w
            w_start = round(Int, w)
            _dbnew_redraw_window!(axes, state, _cache; window_start = w_start)
            _dbnew_add_cursor_dots!(axes, cursor_obs)
            _create_overlay_plots!()
            # Re-map cursor to new window
            state.frame[] = w_start + sl_frame.value[] - 1
            _dbnew_update_cursor!(cursor_obs, _cache, state)
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

    # Create/recreate persistent overlay plots (must be called after any _dbnew_draw_all!)
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


        if sel_s > 0 && sel_s <= length(saccades)
            s = saccades[sel_s]
            _hl_sacc_spatial_pts[] = [Point2f(s.x1, s.y1), Point2f(s.x2, s.y2)]
            ti = clamp(s.time_idx, 1, length(t))
            _hl_sacc_xy_t[] = [t[ti]]
            _hl_sacc_vel_t[] = [t[ti]]

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



    # ── Initial draw ───────────────────────────────────────────────────────── #
    _cache = Dict{Symbol,Any}()
    _dbnew_draw_all!(
        axes,
        df,
        state,
        trial_label,
        _cache;
        reset_zoom = true,
        window_start = 1,
    )
    _dbnew_add_cursor_dots!(axes, cursor_obs)
    _dbnew_update_cursor!(cursor_obs, _cache, state)
    _create_overlay_plots!()

    # ── Multimedia Keyboard Listeners ──────────────────────────────────────── #
    on(events(fig).keyboardbutton) do event
        if event.action == Keyboard.press && event.key == Keyboard.space
            if !isnothing(state.bg_stimulus)
                try
                    segment_id = state.segments[state.trial[]]
                    stim_vals = state.bg_stimulus(segment_id)
                    if !isnothing(stim_vals)
                        items = stim_vals isa AbstractVector ? stim_vals : [stim_vals]
                        # Collect all audio buffers first, then concatenate and play as one stream
                        # to avoid ALSA device lock contention from concurrent @async calls.
                        audio_buffers = []
                        audio_fs = nothing
                        audio_paths = String[]
                        for val in items
                            if val isa AudioMedia && val.content isa Tuple
                                push!(audio_buffers, val.content[1])
                                audio_fs = val.content[2]
                            elseif val isa AudioMedia && val.content isa AbstractString
                                push!(audio_paths, val.content)
                            elseif val isa Tuple &&
                                   length(val) >= 2 &&
                                   val[2] isa Number &&
                                   val[1] isa AbstractArray
                                push!(audio_buffers, val[1])
                                audio_fs = val[2]
                            elseif val isa AbstractString &&
                                   endswith(lowercase(val), ".wav")
                                push!(audio_paths, val)
                            end
                        end
                        if !isempty(audio_paths)
                            @async begin
                                for i in 1:length(audio_paths)
                                    wait(play_wav(audio_paths[i]))
                                    if i < length(audio_paths)
                                        sleep(0.3)
                                    end
                                end
                            end
                        end
                        if !isempty(audio_buffers) && !isnothing(audio_fs)
                            # Insert 0.3s silence between clips
                            silence = zeros(
                                Float64,
                                round(Int, 0.3 * audio_fs),
                                size(audio_buffers[1], 2),
                            )
                            combined = audio_buffers[1]
                            for i = 2:length(audio_buffers)
                                combined = vcat(combined, silence, audio_buffers[i])
                            end
                            play_wav((combined, audio_fs))
                        end
                    end
                catch
                end
            end
        end
        return Consume(false)
    end

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
