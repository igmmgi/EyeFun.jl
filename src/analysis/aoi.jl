# ── aoi_metrics ────────────────────────────────────────────────────────────── #

"""
    aoi_metrics(df::EyeData, aois::Vector{<:AOI};
                selection=nothing, eye=:auto, group_by=:trial)

Compute standard Area of Interest metrics per group. Returns a DataFrame with:

- grouping columns (e.g. `trial`, or `block` + `trial`)
- `aoi` — AOI name
- `dwell_time_ms` — total time spent in AOI
- `fixation_count` — number of fixations landing in AOI
- `first_fixation_time_ms` — time of first gaze entry
- `first_fixation_duration_ms` — duration of the first fixation in AOI
- `entry_count` — number of gaze entries into AOI

# Parameters
- `aois`: vector of AOI objects (RectAOI, CircleAOI, EllipseAOI, PolygonAOI)
- `selection`: optional selection predicate to filter samples
- `eye`: which eye to use (`:auto`, `:left`, `:right`)
- `group_by`: grouping column(s) (default `:trial`)

# Example
```julia
aois = [RectAOI("Face", 400, 200, 800, 600)]
am = aoi_metrics(df, aois; group_by=[:block, :trial])
```
"""
function aoi_metrics(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :trial,
    time_window::Union{Nothing,Tuple} = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found.")
    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    sr = df.sample_rate

    return combine(grouped) do g
        gx_full = g[!, gx_col]
        gy_full = g[!, gy_col]
        t_full = _trial_relative_time(g)

        if !isnothing(time_window)
            t_start, t_end = _resolve_time_window(g, time_window)
            time_mask = t_start .<= t_full .<= t_end
            gx = gx_full[time_mask]
            gy = gy_full[time_mask]
            t = t_full[time_mask]
        else
            gx, gy, t = gx_full, gy_full, t_full
        end

        group_rows = NamedTuple[]

        for aoi in aois
            # Compute sample-level AOI membership mask
            aoi_mask = Bool[
                !isnan(gx[i]) && !isnan(gy[i]) && in_aoi(aoi, gx[i], gy[i]) for
                i in eachindex(gx)
            ]

            # Dwell time in ms (using actual sample rate)
            dwell = round(sum(aoi_mask) / sr * 1000.0; digits = 1)

            # Entry count (transitions from outside → inside)
            entries = counts(aoi_mask)

            # First fixation time and duration
            first_fix_time = NaN
            first_fix_dur = NaN
            fix_count = 0
            if hasproperty(g, :in_fix) && hasproperty(g, :fix_gavx) && hasproperty(g, :fix_gavy)
                in_fix = g.in_fix
                onset_mask = in_fix .& .![false; in_fix[1:end-1]]
                valid_onsets = onset_mask .& .!isnan.(g.fix_gavx) .& .!isnan.(g.fix_gavy)
                
                fx = g.fix_gavx[valid_onsets]
                fy = g.fix_gavy[valid_onsets]
                fd = Float64.(g.fix_dur[valid_onsets])
                ft = t_full[valid_onsets]

                if !isnothing(time_window)
                    t_start, t_end = _resolve_time_window(g, time_window)
                    valid_idx = Int[]
                    for i in eachindex(ft)
                        onset = ft[i]
                        dur = fd[i]
                        f_end = onset + dur
                        if f_end > t_start && onset < t_end
                            if onset < t_start
                                dur -= (t_start - onset)
                                onset = t_start
                            end
                            if onset + dur > t_end
                                dur -= (onset + dur - t_end)
                            end
                            if dur > 0
                                ft[i] = onset
                                fd[i] = dur
                                push!(valid_idx, i)
                            end
                        end
                    end
                    fx = fx[valid_idx]
                    fy = fy[valid_idx]
                    fd = fd[valid_idx]
                    ft = ft[valid_idx]
                end

                in_aoi_fix = Bool[in_aoi(aoi, x, y) for (x, y) in zip(fx, fy)]
                fix_count = count(in_aoi_fix)
                
                if fix_count > 0
                    first_idx = findfirst(in_aoi_fix)
                    first_fix_time = ft[first_idx]
                    first_fix_dur = fd[first_idx]
                end
            else
                first_idx = findfirst(aoi_mask .& .!isnan.(t))
                if !isnothing(first_idx)
                    first_fix_time = t[first_idx]
                end
            end

            push!(
                group_rows,
                (;
                    aoi = aoi.name,
                    dwell_time_ms = dwell,
                    fixation_count = fix_count,
                    first_fixation_time_ms = isnan(first_fix_time) ? missing :
                                             round(first_fix_time; digits = 1),
                    first_fixation_duration_ms = isnan(first_fix_dur) ? missing :
                                                 round(first_fix_dur; digits = 1),
                    entry_count = entries,
                )
            )
        end
        return DataFrame(group_rows)
    end
end
