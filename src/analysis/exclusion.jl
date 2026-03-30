# ── Trial Exclusion ────────────────────────────────────────────────────────── #

"""
    exclude_trials!(ed::EyeData; max_tracking_loss=50.0, max_blink_count=nothing,
                     min_duration_ms=nothing, group_by=:trial, verbose=true)

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
- `verbose`: print summary to stdout (default: `true`)

# Example
```julia
result = exclude_trials!(ed; max_tracking_loss=40, max_blink_count=5)
# Trial exclusion: 3/48 trials removed (45 remaining)

result = exclude_trials!(ed; max_tracking_loss=30, group_by=[:block, :trial])
```
"""
function exclude_trials!(
    ed::EyeData;
    max_tracking_loss::Real = 50.0,
    max_blink_count::Union{Nothing,Int} = nothing,
    min_duration_ms::Union{Nothing,Real} = nothing,
    group_by = :trial,
    verbose::Bool = true,
)
    dq = data_quality(ed; group_by = group_by)
    group_cols = _resolve_group_cols(ed, group_by)

    # Identify bad trials
    bad = falses(nrow(dq))
    bad .|= dq.tracking_loss_pct .> max_tracking_loss

    if max_blink_count !== nothing
        bad .|= dq.blink_count .> max_blink_count
    end
    if min_duration_ms !== nothing
        bad .|= dq.duration_ms .< min_duration_ms
    end

    excluded_rows = dq[bad, :]
    n_before = nrow(dq)
    n_excluded = nrow(excluded_rows)

    # Build exclusion filter
    if n_excluded > 0
        # Build a single combined mask over all excluded trials, then delete once
        combined_mask = falses(nrow(ed.df))
        for row in eachrow(excluded_rows)
            for i in 1:nrow(ed.df)
                combined_mask[i] && continue  # already marked
                match = true
                for col in group_cols
                    if ismissing(ed.df[i, col]) || ed.df[i, col] != row[col]
                        match = false
                        break
                    end
                end
                match && (combined_mask[i] = true)
            end
        end
        deleteat!(ed.df, findall(combined_mask))
    end

    result = (
        n_before = n_before,
        n_excluded = n_excluded,
        n_after = n_before - n_excluded,
        excluded = [
            NamedTuple{Tuple(group_cols)}(Tuple(row[c] for c in group_cols)) for
            row in eachrow(excluded_rows)
        ],
    )

    if verbose
        @info "Trial exclusion: $(n_excluded)/$(n_before) trials removed ($(result.n_after) remaining)"
    end

    return result
end
