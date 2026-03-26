# ── plot_sequence ──────────────────────────────────────────────────────────── #

"""
    plot_sequence(df::EyeData; selection=nothing, group_by=:trial, max_trials=20)

Event sequence chart showing fixation, saccade, and blink periods as
horizontal color bars for each trial.

Green = fixation, blue = saccade, red = blink, gray = tracking loss.

# Example
```julia
plot_sequence(df; selection=(trial=1:10,))
plot_sequence(df; group_by=[:block, :trial], max_trials=15)
```
"""
function plot_sequence(
    df::EyeData;
    selection = nothing,
    group_by = :trial,
    max_trials::Int = 20,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    group_cols = _resolve_group_cols(samples, group_by)
    valid_df = filter(r -> all(s -> !ismissing(r[s]), group_cols), samples)
    groups = collect(groupby(valid_df, group_cols))

    n_groups = min(length(groups), max_trials)
    sr = df.sample_rate

    # Pre-compute labels
    labels = String[]
    for gi = 1:n_groups
        g = groups[gi]
        label = _group_labels(g, group_cols)
        push!(labels, join(["$(v)" for v in values(label)], "/"))
    end

    fig = Figure(size = (900, max(300, n_groups * 30 + 80)))
    ax = Axis(
        fig[1, 1];
        xlabel = "Time (ms)",
        ylabel = "",
        title = _format_title("Event Sequence", selection),
        yticks = (1:n_groups, labels),
    )

    for gi = 1:n_groups
        g = groups[gi]
        nsamp = nrow(g)
        t_end = (nsamp - 1) / sr * 1000.0

        y_lo = gi - 0.35
        y_hi = gi + 0.35

        # Background: gray for tracking loss
        poly!(
            ax,
            Point2f[(0, y_lo), (t_end, y_lo), (t_end, y_hi), (0, y_hi)];
            color = (:gray80, 0.5),
        )

        # Fixations
        if hasproperty(g, :in_fix)
            _draw_event_bars!(ax, g.in_fix, sr, y_lo, y_hi, (:green, 0.7))
        end

        # Saccades
        if hasproperty(g, :in_sacc)
            _draw_event_bars!(ax, g.in_sacc, sr, y_lo, y_hi, (:dodgerblue, 0.7))
        end

        # Blinks
        if hasproperty(g, :in_blink)
            _draw_event_bars!(ax, g.in_blink, sr, y_lo, y_hi, (:red, 0.6))
        end
    end

    # Legend
    elem_fix = PolyElement(color = (:green, 0.7))
    elem_sacc = PolyElement(color = (:dodgerblue, 0.7))
    elem_blink = PolyElement(color = (:red, 0.6))
    Legend(
        fig[2, 1],
        [elem_fix, elem_sacc, elem_blink],
        ["Fixation", "Saccade", "Blink"];
        orientation = :horizontal,
        tellheight = true,
        tellwidth = false,
    )

    return fig
end

"""Draw horizontal bars for event runs (fixation/saccade/blink)."""
function _draw_event_bars!(ax, event_col, sr, y_lo, y_hi, color)
    n = length(event_col)
    i = 1
    while i <= n
        if event_col[i]
            j = i
            while j <= n && event_col[j]
                j += 1
            end
            t_start = (i - 1) / sr * 1000.0
            t_stop = (j - 1) / sr * 1000.0
            poly!(
                ax,
                Point2f[(t_start, y_lo), (t_stop, y_lo), (t_stop, y_hi), (t_start, y_hi)];
                color = color,
            )
            i = j
        else
            i += 1
        end
    end
end
