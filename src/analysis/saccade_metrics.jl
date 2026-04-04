"""
    saccade_metrics(df::EyeData; selection=nothing, eye=:auto, group_by=:trial, time_window=nothing)

Extract individual saccadic geometric characteristics, including trajectory curvature
(maximum orthogonal deviation from a straight line).

`time_window` supports `(start, end)` tuples with numbers or column symbols to define
a boundary dynamically per-trial (e.g., `(:target_onset, :target_offset)`).

Returns a DataFrame with one row per valid saccade, containing:
- Group columns (e.g., `:trial`)
- `saccade_idx` — sequential index of the saccade within the valid trial window
- `duration` — duration of the saccade (ms)
- `amplitude_deg` — native amplitude of the saccade in degrees of visual angle
- `peak_velocity` — peak velocity of the saccade (°/s)
- `start_x`, `start_y` — coordinate beginning
- `end_x`, `end_y` — coordinate ending
- `max_curvature_px` — maximum absolute orthogonal deviation from a straight path (in pixels)
- `curvature_ratio` — normalized curvature (`max_curvature_px / amplitude_px`)
"""
function saccade_metrics(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :trial,
    time_window::Union{Nothing,Tuple} = nothing,
)
    samples = _apply_selection(df, selection)
    """
        nrow

    Internal documentation.
    """
    nrow(samples) == 0 && error("No samples found for the given selection.")

    hasproperty(samples, :in_sacc) ||
        error("No saccade tracking columns. Run event detection first.")

    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    res = combine(grouped) do g
        group_rows = NamedTuple[]

        tr = _trial_relative_time(g)
        in_sacc = g.in_sacc
        gx = Float64.(g[!, gx_col])
        gy = Float64.(g[!, gy_col])

        has_ampl = hasproperty(g, :sacc_ampl)
        has_pvel = hasproperty(g, :sacc_pvel)

        t_start, t_end = -Inf, Inf
        if !isnothing(time_window)
            tw_s, tw_e = _resolve_time_window(g, time_window)
            t_start = Float64(tw_s)
            t_end = Float64(tw_e)
        end

        n = nrow(g)
        i = 1
        saccade_idx = 1

        while i <= n
            if in_sacc[i]
                j = i
                while j <= n && in_sacc[j]
                    j += 1
                end

                # Saccade time bounds check (must start within window)
                sacc_t = tr[i]
                if t_start <= sacc_t <= t_end
                    run = i:(j-1)

                    # Extract valid pixel coordinates
                    valid_coords =
                        filter(k -> !isnan(gx[k]) && !isnan(gy[k]), collect(run))

                    if length(valid_coords) >= 2
                        first_k = valid_coords[1]
                        last_k = valid_coords[end]

                        xs, ys = gx[first_k], gy[first_k]
                        xe, ye = gx[last_k], gy[last_k]

                        dx = xe - xs
                        dy = ye - ys
                        amplitude_px = sqrt(dx^2 + dy^2)

                        # Extract maximum orthogonal curvature in pixels
                        max_curvature_px = 0.0
                        if amplitude_px > 1e-6
                            for k in valid_coords
                                xi, yi = gx[k], gy[k]
                                dist =
                                    abs(dx * (ys - yi) - (xs - xi) * dy) / amplitude_px
                                if dist > max_curvature_px
                                    max_curvature_px = dist
                                end
                            end
                        end

                        # Normalize curvature against trajectory length
                        curvature_ratio =
                            amplitude_px > 1e-6 ? max_curvature_px / amplitude_px : 0.0

                        ampl_deg = has_ampl ? Float64(g.sacc_ampl[first_k]) : NaN
                        pvel = has_pvel ? Float64(g.sacc_pvel[first_k]) : NaN
                        dur = length(run) * (1000.0 / df.sample_rate)

                        push!(
                            group_rows,
                            (;
                                saccade_idx = saccade_idx,
                                duration = round(dur; digits = 2),
                                start_x = round(xs; digits = 2),
                                start_y = round(ys; digits = 2),
                                end_x = round(xe; digits = 2),
                                end_y = round(ye; digits = 2),
                                amplitude_deg = round(ampl_deg; digits = 4),
                                peak_velocity = round(pvel; digits = 4),
                                max_curvature_px = round(max_curvature_px; digits = 4),
                                curvature_ratio = round(curvature_ratio; digits = 4),
                            ),
                        )
                        saccade_idx += 1
                    end
                end
                i = j
            else
                i += 1
            end
        end
        return DataFrame(group_rows)
    end

    # Empty safety guard
    if nrow(res) == 0
        expected_cols = vcat(
            group_cols,
            [
                :saccade_idx,
                :duration,
                :start_x,
                :start_y,
                :end_x,
                :end_y,
                :amplitude_deg,
                :peak_velocity,
                :max_curvature_px,
                :curvature_ratio,
            ],
        )
        return DataFrame([name => [] for name in expected_cols])
    end

    return res
end
