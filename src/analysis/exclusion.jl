"""
    exclude_trials!(ed::EyeData; max_tracking_loss=50.0, max_blink_count=nothing,
                    min_duration_ms=nothing, group_by=:auto, eye=:auto,
                    prefix=nothing, verbose=false)

Remove trials (or groups) that fail data quality criteria. Modifies the EyeData in-place.

Returns a `NamedTuple` summary: `(n_before, n_excluded, n_after, excluded)`.

# Keyword Arguments (combined with OR: failing any criterion excludes the group)
- `max_tracking_loss`: maximum tracking loss percentage (default: 50%)
- `max_blink_count`: maximum number of blinks per trial (`nothing` = no limit)
- `min_duration_ms`: minimum trial duration in ms (`nothing` = no limit)
- `group_by`: grouping column(s) defining trials (default: `:auto`, resolving to
  `[:participant, :trial]` for multi-participant data or `[:trial]` otherwise)
- `eye`: eye to inspect (`:auto`, `:left`, `:right`, `:both`)
- `prefix`: optional event column prefix (e.g. `:ivt`) for blink counts
- `verbose`: log exclusion summary via `@info` (default: `false`)
"""
function exclude_trials!(
    ed::EyeData;
    max_tracking_loss::Real = 50.0,
    max_blink_count::Union{Nothing,Int} = nothing,
    min_duration_ms::Union{Nothing,Real} = nothing,
    group_by = :auto,
    eye::Symbol = :auto,
    prefix::Union{Nothing,Symbol} = nothing,
    verbose::Bool = false,
)
    dq = data_quality(ed; eye = eye, group_by = group_by, prefix = prefix)
    group_cols = _resolve_group_cols(ed, group_by)

    bad = dq.tracking_loss_pct .> max_tracking_loss

    if !isnothing(max_blink_count)
        bad .|= dq.blink_count .> max_blink_count
    end
    if !isnothing(min_duration_ms)
        bad .|= dq.duration_ms .< min_duration_ms
    end

    excluded_rows = dq[bad, :]
    n_before = nrow(dq)
    n_excluded = nrow(excluded_rows)

    # Keep rows whose group keys are NOT in excluded_rows (preserving inter-trial `missing` rows)
    if n_excluded > 0
        keep = antijoin(
            ed.df,
            excluded_rows[!, group_cols];
            on = group_cols,
            matchmissing = :notequal,
        )
        empty!(ed.df)
        append!(ed.df, keep)
    end

    result = (
        n_before = n_before,
        n_excluded = n_excluded,
        n_after = n_before - n_excluded,
        excluded = [NamedTuple(row) for row in eachrow(excluded_rows[!, group_cols])],
    )

    verbose &&
        @info "Trial exclusion: $(n_excluded)/$(n_before) trials removed ($(result.n_after) remaining)"

    return result
end
