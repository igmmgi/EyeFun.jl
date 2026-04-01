"""
    exclude_trials!(df::EyeData; max_tracking_loss=50.0, max_blink_count=nothing,
                     min_duration_ms=nothing, group_by=:trial)

Remove trials that fail quality criteria. Modifies the DataFrame in-place.

Returns a `NamedTuple` with:
- `n_before` — number of trials before exclusion
- `n_excluded` — number of trials removed
- `n_after` — number of trials remaining
- `excluded` — list of excluded trial identifiers

# Parameters
- `max_tracking_loss`: maximum tracking loss percentage (default: 50%)
- `max_blink_count`: maximum number of blinks per trial (default: no limit)
- `min_duration_ms`: minimum trial duration in ms (default: no limit)
- `group_by`: grouping column(s) (default: `:trial`)

# Example
```julia
result = exclude_trials!(df; max_tracking_loss=40, max_blink_count=5)
result = exclude_trials!(df; max_tracking_loss=30, group_by=[:block, :trial])
```
"""
function exclude_trials!(
    ed::EyeData;
    max_tracking_loss::Real=50.0,
    max_blink_count::Union{Nothing,Int}=nothing,
    min_duration_ms::Union{Nothing,Real}=nothing,
    group_by=:trial
)
    dq = data_quality(ed; group_by=group_by)
    group_cols = _resolve_group_cols(ed, group_by)

    # Identify bad trials
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

    # Build exclusion filter: keep only rows whose group keys are NOT in excluded_rows
    if n_excluded > 0
        keep = antijoin(ed.df, excluded_rows[!, group_cols]; on=group_cols)
        empty!(ed.df)
        append!(ed.df, keep)
    end

    result = (
        n_before=n_before,
        n_excluded=n_excluded,
        n_after=n_before - n_excluded,
        excluded=[NamedTuple(row) for row in eachrow(excluded_rows[!, group_cols])],
    )

    @info "Trial exclusion: $(n_excluded)/$(n_before) trials removed ($(result.n_after) remaining)"

    return result
end
