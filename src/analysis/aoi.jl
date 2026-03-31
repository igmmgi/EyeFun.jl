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
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found.")
    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    sr = df.sample_rate

    rows = NamedTuple[]

    for g in grouped
        label = _group_labels(g, group_cols)
        gx = g[!, gx_col]
        gy = g[!, gy_col]

        t = _trial_relative_time(g)

        for aoi in aois
            # Compute in_aoi using contains() dispatch
            in_aoi = Bool[
                !isnan(gx[i]) && !isnan(gy[i]) && contains(aoi, gx[i], gy[i]) for
                i in eachindex(gx)
            ]

            # Dwell time in ms (using actual sample rate)
            dwell = round(sum(in_aoi) / sr * 1000.0; digits = 1)

            # Entry count (transitions from outside → inside)
            entries = counts(in_aoi)

            # First fixation time and duration
            first_fix_time = NaN
            first_fix_dur = NaN
            fix_count = 0
            if hasproperty(g, :fix_gavx) && hasproperty(g, :fix_gavy)
                col_in_fix = g.in_fix
                col_fx = g.fix_gavx
                col_fy = g.fix_gavy
                col_fd = g.fix_dur
                for i in eachindex(col_fx)
                    is_onset = col_in_fix[i] && (i == 1 || !col_in_fix[i-1])
                    if is_onset && !isnan(col_fx[i]) && !isnan(col_fy[i])
                        if contains(aoi, col_fx[i], col_fy[i])
                            fix_count += 1
                            if isnan(first_fix_time) && !isnan(t[i])
                                first_fix_time = t[i]
                                first_fix_dur = Float64(col_fd[i])
                            end
                        end
                    end
                end
            else
                for i in eachindex(in_aoi)
                    if in_aoi[i] && !isnan(t[i])
                        first_fix_time = t[i]
                        break
                    end
                end
            end

            push!(
                rows,
                merge(
                    label,
                    (
                        aoi = aoi.name,
                        dwell_time_ms = dwell,
                        fixation_count = fix_count,
                        first_fixation_time_ms = isnan(first_fix_time) ? missing :
                                                 round(first_fix_time; digits = 1),
                        first_fixation_duration_ms = isnan(first_fix_dur) ? missing :
                                                     round(first_fix_dur; digits = 1),
                        entry_count = entries,
                    ),
                ),
            )
        end
    end

    return DataFrame(rows)
end
