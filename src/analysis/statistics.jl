# ── Statistical Helpers ────────────────────────────────────────────────────── #

"""
    prepare_analysis_data(df::EyeData; selection=nothing, eye=:auto,
                          group_by=:trial, measures=[:pupil])

Reshape eye-tracking data into a clean, one-row-per-sample long-format DataFrame
suitable for statistical modeling (e.g. with `MixedModels.jl`).

Returns a DataFrame with columns:
- Group columns (e.g. `:trial`)
- `time` — time in ms (relative to trial start)
- `sample` — sample index within trial
- Requested measure columns (e.g. `:pupil`, `:gaze_x`, `:gaze_y`)
- Event columns if present (`:in_fix`, `:in_sacc`, `:in_blink`)

Missing/NaN samples are excluded.

# Measures
- `:pupil` — pupil size
- `:gaze_x` — horizontal gaze position
- `:gaze_y` — vertical gaze position
- `:velocity` — gaze velocity (computed if not present)

# Example
```julia
df_model = prepare_analysis_data(df; measures=[:pupil, :gaze_x], selection=(trial=1:20,))
# Ready for MixedModels.jl:
# fit(MixedModel, @formula(pupil ~ condition * time + (time | participant)), df_model)
```
"""
function prepare_analysis_data(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :trial,
    measures::Vector{Symbol} = [:pupil],
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
    ecols = _eye_columns(eye)

    # Pre-resolve measure columns
    measure_cols = Symbol[]
    for m in measures
        col = if m == :pupil
            ecols.pa
        elseif m == :gaze_x
            ecols.gx
        elseif m == :gaze_y
            ecols.gy
        else
            error("Unknown measure :$m. Use :pupil, :gaze_x, or :gaze_y.")
        end
        push!(measure_cols, col)
    end

    rows = NamedTuple[]

    for g in grouped
        label = _group_labels(g, group_cols)
        t = _trial_relative_time(g)

        for i = 1:nrow(g)
            isnan(t[i]) && continue

            # Check all measure columns for validity
            skip = false
            for mc in measure_cols
                if isnan(Float64(g[i, mc]))
                    skip = true
                    break
                end
            end
            skip && continue

            row = merge(
                label,
                (time = t[i], sample = i),
                NamedTuple{Tuple(measures)}(Tuple(Float64(g[i, mc]) for mc in measure_cols)),
            )

            # Add event flags if present
            if hasproperty(g, :in_fix)
                row = merge(row, (in_fix = g.in_fix[i],))
            end
            if hasproperty(g, :in_sacc)
                row = merge(row, (in_sacc = g.in_sacc[i],))
            end
            if hasproperty(g, :in_blink)
                row = merge(row, (in_blink = g.in_blink[i],))
            end

            push!(rows, row)
        end
    end

    return DataFrame(rows)
end

"""
    growth_curve_data(df::DataFrame; time_col=:time_bin, degree=3)

Add orthogonal polynomial time columns to a DataFrame for growth curve analysis.

Takes output from `time_bin()` or `proportion_of_looks()` and adds columns
`ot1`, `ot2`, ..., `otN` containing orthogonal polynomial values computed
over the time column.

These columns are suitable as fixed and random effects in mixed-effects models
(see Mirman, 2014, *Growth Curve Analysis*).

# Example
```julia
# Typical workflow:
binned = time_bin(df; bin_ms=50, measure=:pupil, selection=(trial=1:40,))
gcd = growth_curve_data(binned; degree=3)
# gcd now has columns: ..., ot1, ot2, ot3

# Then in MixedModels.jl:
# fit(MixedModel,
#     @formula(value ~ (ot1 + ot2 + ot3) * condition + (ot1 + ot2 | participant)),
#     gcd)
```
"""
function growth_curve_data(df::DataFrame; time_col::Symbol = :time_bin, degree::Int = 3)
    hasproperty(df, time_col) ||
        error("Column :$time_col not found. Specify time_col= or use time_bin() first.")
    nrow(df) == 0 && error("Empty DataFrame.")

    # Get unique sorted time values
    time_vals = sort(unique(df[!, time_col]))
    n_times = length(time_vals)
    degree = min(degree, n_times - 1)  # can't exceed n-1

    # Compute orthogonal polynomials using Gram-Schmidt
    polys = _orthogonal_polynomials(time_vals, degree)

    # Map polynomial values back to each row
    time_to_idx = Dict(t => i for (i, t) in enumerate(time_vals))

    result = copy(df)
    for d = 1:degree
        col_name = Symbol("ot$d")
        result[!, col_name] = [polys[time_to_idx[t], d] for t in result[!, time_col]]
    end

    return result
end

"""Compute orthogonal polynomials via Gram-Schmidt on evenly-spaced points."""
function _orthogonal_polynomials(x::Vector{<:Real}, degree::Int)
    n = length(x)
    # Normalize x to [-1, 1]
    x_min, x_max = extrema(x)
    x_norm = if x_max > x_min
        2.0 .* (Float64.(x) .- x_min) ./ (x_max - x_min) .- 1.0
    else
        zeros(n)
    end

    # Raw polynomial matrix
    raw = zeros(n, degree + 1)
    for d = 0:degree
        raw[:, d+1] = x_norm .^ d
    end

    # Gram-Schmidt orthogonalization
    ortho = zeros(n, degree + 1)
    for d = 1:(degree+1)
        v = raw[:, d]
        for j = 1:(d-1)
            proj = _dot(v, ortho[:, j]) / _dot(ortho[:, j], ortho[:, j])
            v = v .- proj .* ortho[:, j]
        end
        # Normalize
        norm_v = sqrt(_dot(v, v))
        ortho[:, d] = norm_v > 0 ? v ./ norm_v : v
    end

    # Return columns 2:(degree+1) — skip the intercept (constant)
    return ortho[:, 2:(degree+1)]
end

# Dot product helper (non-allocating, avoids LinearAlgebra dependency)
_dot(a, b) = sum(a[i] * b[i] for i in eachindex(a))
