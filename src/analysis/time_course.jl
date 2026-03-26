# ── Time Course Analysis ───────────────────────────────────────────────────── #

"""
    time_bin(df::EyeData; selection=nothing, bin_ms=50, measure=:pupil,
             eye=:auto, group_by=:trial)

Bin time-series data into fixed-width time bins and compute mean values per bin.

Returns a DataFrame with columns:
- Group columns (e.g. `:trial`)
- `time_bin` — bin center in ms
- `value` — mean value within the bin
- `n` — number of valid samples in the bin

# Measures
- `:pupil` — pupil size
- `:gaze_x` — horizontal gaze position
- `:gaze_y` — vertical gaze position
- `:velocity` — gaze velocity (if available)

# Example
```julia
binned = time_bin(df; bin_ms=100, measure=:pupil, selection=(trial=1:10,))
# Use for growth curve analysis or time-course plots
```
"""
function time_bin(
    df::EyeData;
    selection = nothing,
    bin_ms::Int = 50,
    measure::Symbol = :pupil,
    eye::Symbol = :auto,
    group_by = :trial,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    group_cols = _resolve_group_cols(samples, group_by)
    valid_df = filter(r -> all(s -> !ismissing(r[s]), group_cols), samples)

    eye = _resolve_eye(valid_df, eye)
    ecols = _eye_columns(eye)

    # Select measure column
    val_col = if measure == :pupil
        ecols.pa
    elseif measure == :gaze_x
        ecols.gx
    elseif measure == :gaze_y
        ecols.gy
    else
        error("Unknown measure=:$measure. Use :pupil, :gaze_x, or :gaze_y.")
    end

    rows = NamedTuple[]

    for g in groupby(valid_df, group_cols)
        label = _group_labels(g, group_cols)

        # Get time relative to trial start
        if hasproperty(g, :time_rel) && !all(ismissing, g.time_rel)
            t = Float64[ismissing(v) ? NaN : Float64(v) for v in g.time_rel]
        else
            t_raw = Float64.(g.time)
            t = t_raw .- t_raw[1]
        end

        vals = Float64.(g[!, val_col])

        # Determine bin edges
        t_valid = filter(!isnan, t)
        isempty(t_valid) && continue
        t_min, t_max = minimum(t_valid), maximum(t_valid)
        bin_edges = t_min:bin_ms:t_max

        for b = 1:(length(bin_edges)-1)
            lo = bin_edges[b]
            hi = bin_edges[b+1]
            center = (lo + hi) / 2.0

            mask = lo .<= t .< hi
            bin_vals = vals[mask]
            valid_vals = filter(!isnan, bin_vals)

            push!(
                rows,
                merge(
                    label,
                    (
                        time_bin = center,
                        value = isempty(valid_vals) ? NaN : mean(valid_vals),
                        n = length(valid_vals),
                    ),
                ),
            )
        end
    end

    return DataFrame(rows)
end

"""
    proportion_of_looks(df::EyeData, aois::Vector{<:AOI};
                        selection=nothing, bin_ms=50, eye=:auto, group_by=:trial)

Compute the proportion of gaze samples falling in each AOI per time bin.

Returns a DataFrame with columns:
- Group columns (e.g. `:trial`)
- `time_bin` — bin center in ms
- One column per AOI name — proportion of looks (0.0–1.0)
- `outside` — proportion of looks outside all AOIs

Common in Visual World Paradigm (VWP) research.

# Example
```julia
aois = [RectAOI("Target", 100, 100, 400, 400), RectAOI("Distractor", 800, 100, 1100, 400)]
pol = proportion_of_looks(df, aois; bin_ms=20, selection=(trial=1:20,))
```
"""
function proportion_of_looks(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    bin_ms::Int = 50,
    eye::Symbol = :auto,
    group_by = :trial,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    group_cols = _resolve_group_cols(samples, group_by)
    valid_df = filter(r -> all(s -> !ismissing(r[s]), group_cols), samples)

    eye = _resolve_eye(valid_df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    aoi_names = [a.name for a in aois]
    n_aois = length(aois)

    rows = NamedTuple[]

    for g in groupby(valid_df, group_cols)
        label = _group_labels(g, group_cols)

        # Time
        if hasproperty(g, :time_rel) && !all(ismissing, g.time_rel)
            t = Float64[ismissing(v) ? NaN : Float64(v) for v in g.time_rel]
        else
            t_raw = Float64.(g.time)
            t = t_raw .- t_raw[1]
        end

        gx = Float64.(g[!, gx_col])
        gy = Float64.(g[!, gy_col])

        t_valid = filter(!isnan, t)
        isempty(t_valid) && continue
        t_min, t_max = minimum(t_valid), maximum(t_valid)
        bin_edges = t_min:bin_ms:t_max

        for b = 1:(length(bin_edges)-1)
            lo = bin_edges[b]
            hi = bin_edges[b+1]
            center = (lo + hi) / 2.0

            mask = lo .<= t .< hi
            bin_gx = gx[mask]
            bin_gy = gy[mask]

            # Count valid samples and hits per AOI
            n_valid = 0
            counts = zeros(Int, n_aois)
            for j in eachindex(bin_gx)
                isnan(bin_gx[j]) && continue
                isnan(bin_gy[j]) && continue
                n_valid += 1
                for ai = 1:n_aois
                    if contains(aois[ai], bin_gx[j], bin_gy[j])
                        counts[ai] += 1
                        break
                    end
                end
            end

            # Build row with per-AOI proportions
            props = NamedTuple{Tuple(Symbol.(aoi_names))}(
                Tuple(n_valid > 0 ? counts[ai] / n_valid : NaN for ai = 1:n_aois),
            )
            outside = n_valid > 0 ? (n_valid - sum(counts)) / n_valid : NaN

            push!(rows, merge(label, (time_bin = center,), props, (outside = outside,)))
        end
    end

    return DataFrame(rows)
end
