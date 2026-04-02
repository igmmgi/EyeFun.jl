"""
    fixation_metrics(df::EyeData, aois::Vector{<:AOI};
                     selection=nothing, eye=:auto, group_by=:trial)

Compute per-AOI fixation-level metrics commonly used in reading and scene viewing research.

Returns a DataFrame with columns:
- Group columns (e.g. `:trial`)
- `aoi` — AOI name
- `first_fixation_duration` — duration of the first fixation landing in this AOI (ms)
- `first_fixation_onset` — time of first fixation onset relative to trial start (ms)
- `gaze_duration` — sum of all fixation durations from first entry until first exit (ms)
- `total_time` — total fixation time in this AOI across all visits (ms)
- `fixation_count` — number of fixations in this AOI
- `revisits` — number of re-entries after the first exit
- `skipped` — Bool, true if no fixation landed in this AOI

# Example
```julia
aois = [RectAOI("Word1", 150, 420, 100, 40), RectAOI("Word2", 270, 420, 100, 40)]
fm = fixation_metrics(df, aois; selection=(trial=1:20,))
# Filter skipped AOIs
filter(r -> !r.skipped, fm)
```
"""
function fixation_metrics(
    df::EyeData,
    aois::Vector{<:AOI};
    selection=nothing,
    group_by=:trial,
    time_window::Union{Nothing,Tuple}=nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    hasproperty(samples, :fix_gavx) ||
        error("No fixation columns. Run event detection first.")

    grouped, _ = _valid_groups(samples, group_by)

    return combine(grouped) do g
        # Extract ordered fixation sequence for this trial
        fixations = _extract_trial_fixations(g, aois, time_window)

        group_rows = NamedTuple[]

        # Compute metrics per AOI
        for (ai, aoi) in enumerate(aois)
            aoi_fixes = filter(f -> f.aoi_idx == ai, fixations)

            if isempty(aoi_fixes)
                push!(
                    group_rows,
                    (;
                        aoi=aoi.name,
                        first_fixation_duration=NaN,
                        first_fixation_onset=NaN,
                        gaze_duration=NaN,
                        total_time=0.0,
                        fixation_count=0,
                        revisits=0,
                        skipped=true,
                    )
                )
                continue
            end

            # First fixation
            ff = aoi_fixes[1]
            ffd = ff.dur_ms
            ff_onset = ff.onset_ms

            # Gaze duration: sum from first entry until first exit
            gaze_dur = 0.0
            for fix in fixations
                if fix.onset_ms < ff.onset_ms
                    continue  # before first entry
                end
                if fix.aoi_idx == ai
                    gaze_dur += fix.dur_ms
                else
                    break  # first fixation outside this AOI after entering
                end
            end

            # Total time
            total = sum(f.dur_ms for f in aoi_fixes)

            # Revisits: count re-entries after leaving
            visits = 0
            was_inside = false
            for fix in fixations
                if fix.aoi_idx == ai
                    if !was_inside
                        visits += 1
                    end
                    was_inside = true
                else
                    was_inside = false
                end
            end
            revisits = max(0, visits - 1)

            push!(
                group_rows,
                (;
                    aoi=aoi.name,
                    first_fixation_duration=ffd,
                    first_fixation_onset=ff_onset,
                    gaze_duration=gaze_dur,
                    total_time=total,
                    fixation_count=length(aoi_fixes),
                    revisits=revisits,
                    skipped=false,
                )
            )
        end
        return DataFrame(group_rows)
    end
end

"""Extract ordered fixation list with AOI assignments for a trial group."""
function _extract_trial_fixations(g::AbstractDataFrame, aois::Vector{<:AOI}, time_window)
    fixations = NamedTuple{(:aoi_idx, :dur_ms, :onset_ms),Tuple{Int,Float64,Float64}}[]

    t0 = Float64(g.time[1])
    prev_fx = NaN

    for i = 1:nrow(g)
        g.in_fix[i] || continue
        fx = Float64(g.fix_gavx[i])
        isnan(fx) && continue
        fx == prev_fx && continue  # same fixation
        prev_fx = fx

        fy = Float64(g.fix_gavy[i])
        dur_ms = Float64(g.fix_dur[i])
        onset_ms = Float64(g.time[i]) - t0

        if !isnothing(time_window)
            t_start, t_end = _resolve_time_window(g, time_window)
            fix_end = onset_ms + dur_ms

            if fix_end <= t_start || onset_ms >= t_end
                continue
            end

            if onset_ms < t_start
                dur_ms -= (t_start - onset_ms)
                onset_ms = t_start
            end

            if onset_ms + dur_ms > t_end
                dur_ms -= (onset_ms + dur_ms - t_end)
            end
            
            dur_ms <= 0 && continue
        end

        # Find AOI (0 = outside all AOIs)
        aoi_idx = 0
        for (ai, aoi) in enumerate(aois)
            if in_aoi(aoi, fx, fy)
                aoi_idx = ai
                break
            end
        end

        push!(fixations, (aoi_idx=aoi_idx, dur_ms=dur_ms, onset_ms=onset_ms))
    end

    return fixations
end
