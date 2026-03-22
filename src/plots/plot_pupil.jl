# ── plot_pupil ─────────────────────────────────────────────────────────────── #

"""
    plot_pupil(df::EyeData; selection=nothing, eye=:auto)

Plot pupil size over time. Shades blink periods in gray.

Uses `time_rel` for X axis if available, otherwise absolute time offset.
"""
function plot_pupil(df::EyeData; selection = nothing, eye::Symbol = :auto)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    # Select pupil column based on eye
    eye in (:L, :l) && (eye = :left)
    eye in (:R, :r) && (eye = :right)

    has_left = hasproperty(samples, :paL) && !all(isnan, samples.paL)
    has_right = hasproperty(samples, :paR) && !all(isnan, samples.paR)

    if eye == :auto
        eye =
            has_left ? :left :
            (has_right ? :right : error("No valid pupil data found in either eye"))
    end

    if eye == :left
        has_left || error("No left-eye pupil data.")
        pa = Float64.(samples.paL)
        eye_label = "Left eye"
    else
        has_right || error("No right-eye pupil data.")
        pa = Float64.(samples.paR)
        eye_label = "Right eye"
    end

    # Time axis
    has_rel = hasproperty(samples, :time_rel)
    if has_rel && !all(ismissing, samples.time_rel)
        t = Float64[ismissing(v) ? NaN : Float64(v) for v in samples.time_rel]
        t_label = "Time (ms, relative)"
    else
        time_ms = Float64.(samples.time)
        t = time_ms .- time_ms[1]
        t_label = "Time (ms)"
    end

    title_sel = selection !== nothing ? " ($selection)" : ""
    title = "Pupil$title_sel ($eye_label)"

    fig = Figure(size = (900, 400))
    ax = Axis(fig[1, 1]; xlabel = t_label, ylabel = "Pupil size", title = title)

    # Helper to extract time and pupil for a sub-dataframe
    function _get_trial_tp(sub)
        if eye == :left
            pa_sub = Float64.(sub.paL)
        else
            pa_sub = Float64.(sub.paR)
        end
        if has_rel && !all(ismissing, sub.time_rel)
            t_sub = Float64[ismissing(v) ? NaN : Float64(v) for v in sub.time_rel]
        else
            time_ms_sub = Float64.(sub.time)
            t_sub = time_ms_sub .- time_ms_sub[1]
        end
        return t_sub, pa_sub
    end

    # Draw per-trial to avoid connecting lines between trials
    has_trials = hasproperty(samples, :trial)
    if has_trials && length(unique(skipmissing(samples.trial))) > 1
        trial_data = filter(r -> !ismissing(r.trial), samples)
        for g in groupby(trial_data, :trial)
            sub = DataFrame(g)
            t_sub, pa_sub = _get_trial_tp(sub)

            # Shade blink periods for this trial
            if hasproperty(sub, :in_blink)
                bm = sub.in_blink
                i = 1
                while i <= length(bm)
                    if bm[i]
                        j = i
                        while j <= length(bm) && bm[j]
                            ;
                            j += 1;
                        end
                        Makie.vspan!(
                            ax,
                            [t_sub[i]],
                            [t_sub[min(j, length(t_sub))]];
                            color = (:gray, 0.15),
                        )
                        i = j
                    else
                        i += 1
                    end
                end
            end

            lines!(ax, t_sub, pa_sub; color = :black, linewidth = 0.5)
        end
    else
        # Single trial or no trial column
        if hasproperty(samples, :in_blink)
            blink_mask = samples.in_blink
            i = 1
            while i <= length(blink_mask)
                if blink_mask[i]
                    j = i
                    while j <= length(blink_mask) && blink_mask[j]
                        ;
                        j += 1;
                    end
                    Makie.vspan!(ax, [t[i]], [t[min(j, length(t))]]; color = (:gray, 0.2))
                    i = j
                else
                    i += 1
                end
            end
        end
        lines!(ax, t, pa; color = :black, linewidth = 0.5)
    end

    return fig
end
