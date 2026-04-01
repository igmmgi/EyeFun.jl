# ── Core analysis helpers ──────────────────────────────────────────────────── #
"""
    _resolve_eye(df, eye; cols=:gaze) -> Symbol

Resolve `:auto` eye selection to `:left` or `:right`. `cols` determines which
columns to check: `:gaze` checks `gxL/gxR`, `:pupil` checks `paL/paR`.
"""
function _resolve_eye(dat, eye::Symbol; cols::Symbol=:gaze)

    if eye ∉ (:left, :L, :l, :right, :R, :r, :auto)
        error("Invalid eye=:$eye. Use :left, :right, :L, :R, or :auto.")
    end
    if cols ∉ (:gaze, :pupil)
        error("Invalid cols=:$cols. Use :gaze or :pupil.")
    end

    df = dat isa EyeData ? dat.df : dat
    eye in (:left, :L, :l) && return :left
    eye in (:right, :R, :r) && return :right

    # From here on, eye MUST be :auto. We try to infer the active eye from the data.
    if cols == :pupil
        hasproperty(df, :paL) && return :left
        hasproperty(df, :paR) && return :right
    else # gaze
        hasproperty(df, :gxL) && return :left
        hasproperty(df, :gxR) && return :right
    end

    error("DataFrame does not contain recognized eye columns.")
end

"""
    _eye_columns(eye::Symbol) -> NamedTuple{(:gx, :gy, :pa), NTuple{3, Symbol}}

Return the column names for gaze X, gaze Y, and pupil area for the given eye.
"""
_eye_columns(eye::Symbol) = eye == :left ? (gx=:gxL, gy=:gyL, pa=:paL) : (gx=:gxR, gy=:gyR, pa=:paR)

"""
    _resolve_group_cols(df, group_by) -> Vector{Symbol}

Normalize `group_by` kwarg to a Vector{Symbol} and validate that all columns exist.
Accepts `:trial`, `[:block, :trial]`, or any Symbol/Vector{Symbol}.
"""
function _resolve_group_cols(dat, group_by)
    df = dat isa EyeData ? dat.df : dat
    cols = group_by isa Symbol ? [group_by] : collect(Symbol, group_by)
    issubset(cols, propertynames(df)) || error("Grouping columns $cols not found in DataFrame.")
    return cols
end
"""
    _valid_groups(df_or_samples, group_by) -> (grouped, group_cols)

Resolve group columns, filter rows with missing group values, and return
a grouped DataFrame and the resolved column list. This eliminates the
repeated 3-line boilerplate pattern found in most analysis functions.
"""
function _valid_groups(df_or_samples, group_by)
    d = df_or_samples isa EyeData ? df_or_samples.df : df_or_samples
    group_cols = _resolve_group_cols(d, group_by)
    valid_df = dropmissing(d, group_cols)
    return groupby(valid_df, group_cols), group_cols
end

"""
    counts(v::AbstractVector{Bool}) -> Int

Count the number of onset transitions (false → true) in a Bool vector.
Useful for counting discrete events in sample-level annotation columns.

# Example
```julia
counts(df.in_fix)     # number of fixations
counts(df.in_sacc)    # number of saccades
counts(df.in_blink)   # number of blinks
```
"""
function counts(v::AbstractVector{Bool})
    count(i -> v[i] && (i == 1 || !v[i-1]), eachindex(v))
end


# ── data_quality ───────────────────────────────────────────────────────────── #
"""
    data_quality(df::EyeData; eye=:auto, group_by=:trial)

Compute per-group data quality metrics. Returns a DataFrame with columns:

- grouping columns (e.g. `trial`, or `block` + `trial`)
- `total_samples` — total samples in group
- `valid_samples` — non-NaN gaze samples
- `tracking_loss_pct` — percentage of NaN gaze samples
- `blink_count` — number of blinks
- `blink_rate` — blinks per second
- `mean_pupil` — mean pupil size (excluding NaN)
- `duration_ms` — duration in ms

# Example
```julia
dq = data_quality(df)
filter(r -> r.tracking_loss_pct > 50, dq)  # find bad trials

# Multi-block design
dq = data_quality(df; group_by=[:block, :trial])
```
"""
function data_quality(df::EyeData; eye::Symbol=:auto, group_by=:trial)
    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, pa_col = ecols.gx, ecols.pa
    sr = df.sample_rate

    grouped, _ = _valid_groups(df, group_by)

    return combine(grouped) do g
        n = nrow(g)

        gx = g[!, gx_col]
        valid = count(!isnan, gx)
        loss_pct = (n - valid) / n * 100.0

        # Blink count
        blink_n = hasproperty(g, :in_blink) ? counts(g.in_blink) : 0

        # Duration and blink rate
        dur_ms = n / sr * 1000.0
        blink_rate = blink_n * sr / n

        # Mean pupil
        pa = g[!, pa_col]
        pa_valid = filter(!isnan, pa)
        mean_pa = isempty(pa_valid) ? NaN : mean(pa_valid)

        (;
            total_samples=n,
            valid_samples=valid,
            tracking_loss_pct=round(loss_pct; digits=1),
            blink_count=blink_n,
            blink_rate=round(blink_rate; digits=2),
            mean_pupil=round(mean_pa; digits=1),
            duration_ms=round(Int, dur_ms),
        )
    end
end

# ── group_summary ──────────────────────────────────────────────────────────── #

"""
    group_summary(df::EyeData; group_by=:trial, by=nothing, eye=:auto)

Aggregate fixation, saccade, and pupil statistics per group, optionally
grouped by condition columns. Returns a DataFrame with summary statistics.

`group_by` defines the base grouping (default `:trial`). Use
`group_by=[:block, :trial]` for multi-block designs.

`by` adds extra condition columns for grouping (e.g., `:type`).

Returns a DataFrame with columns:
- `n_fixations`, `mean_fix_dur`, `median_fix_dur`
- `n_saccades`, `mean_sacc_ampl`, `mean_sacc_pvel`
- `n_blinks`, `mean_pupil`, `tracking_loss_pct`
- Plus grouping columns

# Example
```julia
group_summary(df; group_by=[:block, :trial])
group_summary(df; by=:type)
group_summary(df; group_by=[:block, :trial], by=[:participant, :type])
```
"""
function group_summary(df::EyeData; group_by=:trial, by=nothing, eye::Symbol=:auto)
    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, pa_col = ecols.gx, ecols.pa

    by_cols = isnothing(by) ? Symbol[] : (by isa Symbol ? [by] : collect(Symbol, by))
    base_cols = group_by isa Symbol ? [group_by] : collect(Symbol, group_by)
    all_group_cols = vcat(by_cols, base_cols)

    grouped, _ = _valid_groups(df, all_group_cols)

    return combine(grouped) do g
        gx = g[!, gx_col]
        pa = g[!, pa_col]

        # Tracking loss
        n_samples = nrow(g)
        valid_n = count(!isnan, gx)
        loss_pct = round((n_samples - valid_n) / n_samples * 100.0; digits=1)

        # Fixation stats using vectorized onset detection
        n_fix = 0
        fix_durs = Float64[]
        if hasproperty(g, :in_fix) && hasproperty(g, :fix_gavx)
            in_fix = g.in_fix
            onset_mask = in_fix .& .![false; in_fix[1:end-1]]
            valid_onsets = onset_mask .& .!isnan.(g.fix_gavx)

            n_fix = count(valid_onsets)
            fix_durs = Float64.(g.fix_dur[valid_onsets])
        end

        # Saccade stats using vectorized onset detection
        n_sacc = 0
        sacc_ampls = Float64[]
        sacc_pvels = Float64[]
        if hasproperty(g, :in_sacc) && hasproperty(g, :sacc_pvel)
            in_sacc = g.in_sacc
            onset_mask = in_sacc .& .![false; in_sacc[1:end-1]]
            valid_onsets = onset_mask .& .!isnan.(g.sacc_pvel)

            n_sacc = count(valid_onsets)
            sacc_pvels = Float64.(g.sacc_pvel[valid_onsets])
            sacc_ampls = filter(!isnan, Float64.(g.sacc_ampl[valid_onsets]))
        end

        # Blink count
        n_blinks = hasproperty(g, :in_blink) ? counts(g.in_blink) : 0

        # Mean pupil
        pa_valid = filter(!isnan, pa)
        mean_pa = isempty(pa_valid) ? NaN : round(mean(pa_valid); digits=1)

        (;
            n_fixations=n_fix,
            mean_fix_dur=isempty(fix_durs) ? NaN : round(mean(fix_durs); digits=1),
            median_fix_dur=isempty(fix_durs) ? NaN : round(median(fix_durs); digits=1),
            n_saccades=n_sacc,
            mean_sacc_ampl=isempty(sacc_ampls) ? NaN : round(mean(sacc_ampls); digits=2),
            mean_sacc_pvel=isempty(sacc_pvels) ? NaN : round(mean(sacc_pvels); digits=1),
            n_blinks=n_blinks,
            mean_pupil=mean_pa,
            tracking_loss_pct=loss_pct,
        )
    end
end

"""
    _trial_relative_time(g::AbstractDataFrame) -> Vector{Float64}

Extract sample times relative to trial start. Uses `time_rel` column if
available; otherwise computes `time .- time[1]`.
"""
function _trial_relative_time(g::AbstractDataFrame)
    if hasproperty(g, :time_rel) && !all(ismissing, g.time_rel)
        return Float64[ismissing(v) ? NaN : Float64(v) for v in g.time_rel]
    else
        t_raw = Float64.(g.time)
        return t_raw .- t_raw[1]
    end
end
