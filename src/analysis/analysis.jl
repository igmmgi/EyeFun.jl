# ── Core analysis helpers ──────────────────────────────────────────────────── #
"""
    _resolve_eye(df, eye; cols=:gaze) -> Symbol

Resolve `:auto` eye selection to `:left` or `:right`. `cols` determines which
columns to check: `:gaze` checks `gxL/gxR`, `:pupil` checks `paL/paR`.
"""
function _resolve_eye(df, eye::Symbol; cols::Symbol = :gaze)
    d = df isa EyeData ? df.df : df
    eye in (:left, :L, :l) && return :left
    eye in (:right, :R, :r) && return :right
    if eye == :auto
        if cols == :pupil
            has_left = hasproperty(d, :paL) && any(!isnan, d.paL)
            has_right = hasproperty(d, :paR) && any(!isnan, d.paR)
        else
            has_left = hasproperty(d, :gxL) && any(!isnan, d.gxL)
            has_right = hasproperty(d, :gxR) && any(!isnan, d.gxR)
        end
        has_left && return :left
        has_right && return :right
        error("No valid eye data found in either eye.")
    end
    error("Invalid eye=:$eye. Use :left, :right, :L, :R, or :auto.")
end

"""
    _eye_columns(eye::Symbol) -> NamedTuple{(:gx, :gy, :pa), NTuple{3, Symbol}}

Return the column names for gaze X, gaze Y, and pupil area for the given eye.
"""
function _eye_columns(eye::Symbol)
    if eye == :left
        (gx = :gxL, gy = :gyL, pa = :paL)
    else
        (gx = :gxR, gy = :gyR, pa = :paR)
    end
end

"""
    _resolve_group_cols(df, group_by) -> Vector{Symbol}

Normalize `group_by` kwarg to a Vector{Symbol} and validate that all columns exist.
Accepts `:trial`, `[:block, :trial]`, or any Symbol/Vector{Symbol}.
"""
function _resolve_group_cols(df, group_by)
    d = df isa EyeData ? df.df : df
    cols = group_by isa Symbol ? [group_by] : collect(Symbol, group_by)
    for s in cols
        hasproperty(d, s) || error("Column :$s not found in DataFrame.")
    end
    return cols
end

"""Extract group column values as a NamedTuple from a grouped sub-DataFrame."""
function _group_labels(g::SubDataFrame, group_cols::Vector{Symbol})
    NamedTuple{Tuple(group_cols)}(Tuple(first(g[!, s]) for s in group_cols))
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
function data_quality(df::EyeData; eye::Symbol = :auto, group_by = :trial)
    group_cols = _resolve_group_cols(df, group_by)

    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, pa_col = ecols.gx, ecols.pa
    sr = df.sample_rate

    rows = NamedTuple[]

    valid_df = filter(r -> all(s -> !ismissing(r[s]), group_cols), df.df)

    for g in groupby(valid_df, group_cols)
        label = _group_labels(g, group_cols)
        n = nrow(g)

        gx = g[!, gx_col]
        valid = count(!isnan, gx)
        loss_pct = (n - valid) / n * 100.0

        # Blink count
        blink_n = hasproperty(g, :in_blink) ? counts(g.in_blink) : 0

        # Duration and blink rate
        dur_ms = n / sr * 1000.0
        blink_rate = blink_n * sr / n

        # Mean pupil (inline accumulator avoids allocating filtered array)
        pa = g[!, pa_col]
        pa_sum, pa_n = 0.0, 0
        for v in pa
            if !isnan(v)
                pa_sum += v
                pa_n += 1
            end
        end
        mean_pa = pa_n > 0 ? pa_sum / pa_n : NaN

        push!(
            rows,
            merge(
                label,
                (
                    total_samples = n,
                    valid_samples = valid,
                    tracking_loss_pct = round(loss_pct; digits = 1),
                    blink_count = blink_n,
                    blink_rate = round(blink_rate; digits = 2),
                    mean_pupil = round(mean_pa; digits = 1),
                    duration_ms = round(Int, dur_ms),
                ),
            ),
        )
    end

    return DataFrame(rows)
end

# ── group_summary ──────────────────────────────────────────────────────────── #

"""
    group_summary(df::EyeData; group_by=:trial, by=nothing, eye=:auto)

Aggregate fixation, saccade, and pupil statistics per group, optionally
grouped by condition columns. Returns a DataFrame with summary statistics.

`group_by` defines the base grouping (default `:trial`). Use
`group_by=[:block, :trial]` for multi-block designs.

`by` adds extra condition columns for grouping (e.g., `:type`).

# Returned columns
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
function group_summary(df::EyeData; group_by = :trial, by = nothing, eye::Symbol = :auto)
    base_cols = _resolve_group_cols(df, group_by)

    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, pa_col = ecols.gx, ecols.pa

    # Build full grouping columns
    all_group_cols = copy(base_cols)
    if by !== nothing
        by_syms = by isa Symbol ? [by] : collect(Symbol, by)
        for s in by_syms
            hasproperty(df.df, s) || error("Column :$s not found.")
        end
        all_group_cols = vcat(by_syms, base_cols)
    end

    valid_df = filter(r -> all(s -> !ismissing(r[s]), all_group_cols), df.df)
    rows = NamedTuple[]

    for g in groupby(valid_df, all_group_cols)
        label = _group_labels(g, all_group_cols)
        n = nrow(g)
        gx = g[!, gx_col]
        pa = g[!, pa_col]

        # Tracking loss
        valid_n = count(!isnan, gx)
        loss_pct = round((n - valid_n) / n * 100.0; digits = 1)

        # Fixation stats (column vectors instead of eachrow)
        n_fix = 0
        fix_durs = Float64[]
        sizehint!(fix_durs, 32)
        if hasproperty(g, :fix_gavx)
            col_in_fix = g.in_fix
            col_fx = g.fix_gavx
            col_fd = g.fix_dur
            for i in eachindex(col_fx)
                is_onset = col_in_fix[i] && (i == 1 || !col_in_fix[i-1])
                if is_onset && !isnan(col_fx[i])
                    n_fix += 1
                    push!(fix_durs, Float64(col_fd[i]))
                end
            end
        end

        # Saccade stats (column vectors instead of eachrow)
        n_sacc = 0
        sacc_ampls = Float64[]
        sacc_pvels = Float64[]
        sizehint!(sacc_ampls, 16)
        sizehint!(sacc_pvels, 16)
        if hasproperty(g, :sacc_pvel)
            col_in_sacc = g.in_sacc
            col_spvel = g.sacc_pvel
            col_sampl = g.sacc_ampl
            for i in eachindex(col_spvel)
                is_onset = col_in_sacc[i] && (i == 1 || !col_in_sacc[i-1])
                if is_onset && !isnan(col_spvel[i])
                    n_sacc += 1
                    isnan(col_sampl[i]) || push!(sacc_ampls, col_sampl[i])
                    push!(sacc_pvels, col_spvel[i])
                end
            end
        end

        # Blink count
        n_blinks = if hasproperty(g, :in_blink)
            counts(g.in_blink)
        else
            0
        end

        # Pupil (inline accumulator)
        pa_sum, pa_n = 0.0, 0
        for v in pa
            if !isnan(v)
                pa_sum += v
                pa_n += 1
            end
        end
        mean_pa = pa_n > 0 ? round(pa_sum / pa_n; digits = 1) : NaN

        row = merge(
            label,
            (
                n_fixations = n_fix,
                mean_fix_dur = isempty(fix_durs) ? NaN : round(mean(fix_durs); digits = 1),
                median_fix_dur = isempty(fix_durs) ? NaN :
                                 round(median(fix_durs); digits = 1),
                n_saccades = n_sacc,
                mean_sacc_ampl = isempty(sacc_ampls) ? NaN :
                                 round(mean(sacc_ampls); digits = 2),
                mean_sacc_pvel = isempty(sacc_pvels) ? NaN :
                                 round(mean(sacc_pvels); digits = 1),
                n_blinks = n_blinks,
                mean_pupil = mean_pa,
                tracking_loss_pct = loss_pct,
            ),
        )
        push!(rows, row)
    end

    return DataFrame(rows)
end
