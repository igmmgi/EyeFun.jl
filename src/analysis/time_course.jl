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
    time_window::Union{Nothing,Tuple} = nothing,
)
    samples = _apply_selection(df, selection)
    """
        nrow

    Internal documentation.
    """
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
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

    res = combine(grouped) do g
        t = _trial_relative_time(g)
        vals = Float64.(g[!, val_col])

        # Filter NaNs
        valid = @. !isnan(t) && !isnan(vals)
        v_valid = Float64.(g[valid, val_col])
        t_valid = Float64.(t[valid])

        if !isnothing(time_window)
            t_start, t_end = _resolve_time_window(g, time_window)
            time_mask = t_start .<= t_valid .<= t_end
            t_valid = t_valid[time_mask]
            v_valid = v_valid[time_mask]
        end

        # Anchor bins using robust integer division based on 0
        bin_centers = @. (fld(t_valid, bin_ms) * bin_ms) + (bin_ms / 2.0)

        sub_df = DataFrame(time_bin = bin_centers, value = v_valid; copycols = false)
        if nrow(sub_df) == 0
            return DataFrame(time_bin = Float64[], value = Float64[], n = Int[])
        end
        return combine(groupby(sub_df, :time_bin), :value => mean => :value, nrow => :n)
    end

    expected_cols = vcat(group_cols, [:time_bin, :value, :n])
    return select!(res, expected_cols)
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
aois = [RectAOI("Target", 250, 250, 300, 300), RectAOI("Distractor", 950, 250, 300, 300)]
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
    time_window::Union{Nothing,Tuple} = nothing,
)
    samples = _apply_selection(df, selection)
    """
        nrow

    Internal documentation.
    """
    nrow(samples) == 0 && error("No samples found for the given selection.")

    grouped, group_cols = _valid_groups(samples, group_by)

    eye = _resolve_eye(samples, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col = ecols.gx, ecols.gy

    aoi_names = [a.name for a in aois]
    aoi_syms = Symbol.(aoi_names)
    n_aois = length(aois)

    res = combine(grouped) do g
        t = _trial_relative_time(g)
        gx = Float64.(g[!, gx_col])
        gy = Float64.(g[!, gy_col])

        valid = @. !isnan(t) && !isnan(gx) && !isnan(gy)
        t_valid = Float64.(t[valid])
        fx = g[valid, gx_col]
        fy = g[valid, gy_col]

        if !isnothing(time_window)
            t_start, t_end = _resolve_time_window(g, time_window)
            time_mask = t_start .<= t_valid .<= t_end
            t_valid = t_valid[time_mask]
            fx = fx[time_mask]
            fy = fy[time_mask]
        end

        # Anchor bins
        bin_centers = @. (fld(t_valid, bin_ms) * bin_ms) + (bin_ms / 2.0)

        # Map each valid point to exactly one AOI (the first that contains it), or 0 for outside
        aoi_idx = zeros(Int, length(t_valid))
        for i in eachindex(t_valid)
            for ai = 1:n_aois
                if in_aoi(aois[ai], fx[i], fy[i])
                    aoi_idx[i] = ai
                    break
                end
            end
        end

        sub_df = DataFrame(time_bin = bin_centers; copycols = false)
        for ai = 1:n_aois
            sub_df[!, aoi_syms[ai]] = (aoi_idx .== ai)
        end
        sub_df[!, :outside] = (aoi_idx .== 0)

        if nrow(sub_df) == 0
            empty_res = DataFrame(time_bin = Float64[])
            for sym in aoi_syms
                empty_res[!, sym] = Float64[]
            end
            empty_res[!, :outside] = Float64[]
            return empty_res
        end

        # Computing mean over booleans yields exact grouped proportions natively
        return combine(
            groupby(sub_df, :time_bin),
            [n => mean => n for n in propertynames(sub_df) if n != :time_bin],
        )
    end

    expected_cols = vcat(group_cols, [:time_bin], aoi_syms, [:outside])
    return select!(res, expected_cols)
end
