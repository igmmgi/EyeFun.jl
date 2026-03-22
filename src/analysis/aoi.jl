# ── aoi_metrics ────────────────────────────────────────────────────────────── #

"""
    aoi_metrics(df::EyeData, aois::Dict{String, <:Tuple};
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
- `aois`: dictionary mapping AOI names to `(x1, y1, x2, y2)` bounding boxes
- `selection`: optional selection predicate to filter samples
- `eye`: which eye to use (`:auto`, `:left`, `:right`)
- `group_by`: grouping column(s) (default `:trial`)

# Example
```julia
aois = Dict("Face" => (400, 200, 800, 600))
am = aoi_metrics(df, aois; group_by=[:block, :trial])
```
"""
function aoi_metrics(
    df::EyeData,
    aois::Dict{String,<:Tuple};
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :trial,
)
    samples = selection !== nothing ? _apply_selection(df, selection) : df.df
    nrow(samples) == 0 && error("No samples found.")
    group_cols = _resolve_group_cols(samples, group_by)

    eye = _resolve_eye(samples, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    has_rel = hasproperty(samples, :time_rel)
    sr = df.sample_rate
    aoi_names = sort(collect(keys(aois)))

    rows = NamedTuple[]

    valid_df = filter(r -> all(s -> !ismissing(r[s]), group_cols), samples)

    for g in groupby(valid_df, group_cols)
        label = _group_labels(g, group_cols)
        gx = g[!, gx_col]
        gy = g[!, gy_col]

        # Time reference
        if has_rel && !all(ismissing, g.time_rel)
            t = Float64[ismissing(v) ? NaN : Float64(v) for v in g.time_rel]
        else
            t_raw = Float64.(g.time)
            t = t_raw .- t_raw[1]
        end

        for aoi_name in aoi_names
            x1, y1, x2, y2 = aois[aoi_name]

            # Compute in_aoi without intermediate allocations
            in_aoi = @. !isnan(gx) & !isnan(gy) & (gx >= x1) & (gx <= x2) & (gy >= y1) &
               (gy <= y2)

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
                    # Detect fixation onset (transition into fixation)
                    is_onset = col_in_fix[i] && (i == 1 || !col_in_fix[i-1])
                    if is_onset && !isnan(col_fx[i]) && !isnan(col_fy[i])
                        if x1 <= col_fx[i] <= x2 && y1 <= col_fy[i] <= y2
                            fix_count += 1
                            if isnan(first_fix_time) && !isnan(t[i])
                                first_fix_time = t[i]
                                first_fix_dur = Float64(col_fd[i])
                            end
                        end
                    end
                end
            else
                # Fallback: first sample in AOI
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
                        aoi = aoi_name,
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
