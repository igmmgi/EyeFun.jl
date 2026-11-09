function _extract_trial_fixations_rows!(
    fixs::Vector{NamedTuple{(:fx, :fy, :dur_ms, :onset_ms),Tuple{Float64,Float64,Float64,Float64}}},
    in_fix::AbstractVector{Bool},
    fix_gavx::AbstractVector{<:Real},
    fix_gavy::AbstractVector{<:Real},
    fix_dur::AbstractVector{<:Real},
    t_buf::Vector{Float64},
    rows::AbstractVector{Int},
    m::Int,
    has_tw::Bool,
    t_start::Float64,
    t_end::Float64,
)
    empty!(fixs)
    prev = false

    @inbounds for k = 1:m
        r = rows[k]
        cur = in_fix[r]
        if cur & !prev
            fx = Float64(fix_gavx[r])
            if !isnan(fx)
                fy = Float64(fix_gavy[r])
                if !isnan(fy)
                    dur_ms = Float64(fix_dur[r])
                    onset_ms = t_buf[k]
                    if !isnan(onset_ms)
                        keep = true
                        if has_tw
                            fix_end = onset_ms + dur_ms
                            if fix_end <= t_start || onset_ms >= t_end
                                keep = false
                            else
                                if onset_ms < t_start
                                    dur_ms -= (t_start - onset_ms)
                                    onset_ms = t_start
                                end
                                if onset_ms + dur_ms > t_end
                                    dur_ms -= (onset_ms + dur_ms - t_end)
                                end
                                dur_ms <= 0 && (keep = false)
                            end
                        end
                        if keep
                            push!(
                                fixs,
                                (fx = fx, fy = fy, dur_ms = dur_ms, onset_ms = onset_ms),
                            )
                        end
                    end
                end
            end
        end
        prev = cur
    end

    return nothing
end

function _fixation_metrics_flat!(
    row_first_idx::Vector{Int},
    col_aoi::Vector{String},
    col_ffd::Vector{Float64},
    col_ffo::Vector{Float64},
    col_gaze::Vector{Float64},
    col_total::Vector{Float64},
    col_count::Vector{Int},
    col_revisits::Vector{Int},
    col_skipped::Vector{Bool},
    parent_df::DataFrame,
    grouped::GroupedDataFrame,
    aois::Vector{<:AOI},
    in_fix::AbstractVector{Bool},
    fix_gavx::AbstractVector{<:Real},
    fix_gavy::AbstractVector{<:Real},
    fix_dur::AbstractVector{<:Real},
    has_trel::Bool,
    trel_col,
    time_col::AbstractVector{<:Real},
    time_window,
)
    n_groups = length(grouped)
    n_aois = length(aois)
    has_tw = !isnothing(time_window)

    t_buf = Float64[]
    fixs = NamedTuple{(:fx, :fy, :dur_ms, :onset_ms),Tuple{Float64,Float64,Float64,Float64}}[]

    out_pos = 0
    @inbounds for g_idx = 1:n_groups
        rows = parentindices(grouped[g_idx])[1]
        m = length(rows)
        first_r = rows[1]
        _fill_group_rel_time!(t_buf, has_trel, trel_col, time_col, rows)
        t_start, t_end =
            has_tw ? _resolve_time_window_rows(parent_df, first_r, time_window) : (0.0, 0.0)

        _extract_trial_fixations_rows!(
            fixs,
            in_fix,
            fix_gavx,
            fix_gavy,
            fix_dur,
            t_buf,
            rows,
            m,
            has_tw,
            t_start,
            t_end,
        )

        for ai = 1:n_aois
            aoi = aois[ai]
            fcount = 0
            ffd = NaN
            ff_onset = NaN
            gaze_dur = 0.0
            in_first_pass = false
            done_first_pass = false
            total = 0.0
            visits = 0
            was_inside = false

            for k in eachindex(fixs)
                fix = fixs[k]
                if _in_aoi_interval_fast(
                    aoi,
                    fix.fx,
                    fix.fy,
                    fix.onset_ms,
                    fix.onset_ms + fix.dur_ms,
                )
                    if fcount == 0
                        ffd = fix.dur_ms
                        ff_onset = fix.onset_ms
                        in_first_pass = true
                    end
                    if in_first_pass && !done_first_pass
                        gaze_dur += fix.dur_ms
                    end
                    total += fix.dur_ms
                    fcount += 1
                    if !was_inside
                        visits += 1
                    end
                    was_inside = true
                else
                    if in_first_pass
                        done_first_pass = true
                    end
                    was_inside = false
                end
            end

            out_pos += 1
            row_first_idx[out_pos] = first_r
            col_aoi[out_pos] = aoi.name
            if fcount == 0
                col_ffd[out_pos] = NaN
                col_ffo[out_pos] = NaN
                col_gaze[out_pos] = NaN
                col_total[out_pos] = 0.0
                col_count[out_pos] = 0
                col_revisits[out_pos] = 0
                col_skipped[out_pos] = true
            else
                col_ffd[out_pos] = ffd
                col_ffo[out_pos] = ff_onset
                col_gaze[out_pos] = gaze_dur
                col_total[out_pos] = total
                col_count[out_pos] = fcount
                col_revisits[out_pos] = max(0, visits - 1)
                col_skipped[out_pos] = false
            end
        end
    end
    return nothing
end

"""
    fixation_metrics(df::EyeData, aois::Vector{<:AOI};
                     selection=nothing, eye=:auto, group_by=:auto, time_window=nothing, prefix=nothing)

Compute per-AOI fixation-level metrics commonly used in reading and scene viewing research.

Returns a DataFrame with columns:
- Group columns (e.g. `:trial` or `[:participant, :trial]`)
- `aoi`: AOI name
- `first_fixation_duration`: duration of the first fixation landing in this AOI (ms)
- `first_fixation_onset`: time of first fixation onset relative to trial start (ms)
- `gaze_duration`: sum of all fixation durations from first entry until first exit (ms)
- `total_time`: total fixation time in this AOI across all visits (ms)
- `fixation_count`: number of fixations in this AOI
- `revisits`: number of re-entries after the first exit
- `skipped`: Bool, true if no fixation landed in this AOI
"""
function fixation_metrics(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
    group_by = :auto,
    time_window::Union{Nothing,Tuple} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)
    _resolve_eye(df, eye)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    c_infix = _prefixed_sym(prefix, :in_fix)
    c_fgx = _prefixed_sym(prefix, :fix_gavx)
    c_fgy = _prefixed_sym(prefix, :fix_gavy)
    c_fdur = _prefixed_sym(prefix, :fix_dur)
    (
        hasproperty(samples, c_infix) &&
        hasproperty(samples, c_fgx) &&
        hasproperty(samples, c_fgy) &&
        hasproperty(samples, c_fdur)
    ) || error("No fixation columns ($c_fgx). Run event detection first.")

    grouped, group_cols = _valid_groups(samples, group_by)
    d = df.df
    has_trel = _has_active_time_rel(d)

    n_out = length(grouped) * length(aois)
    row_first_idx = Vector{Int}(undef, n_out)
    col_aoi = Vector{String}(undef, n_out)
    col_ffd = Vector{Float64}(undef, n_out)
    col_ffo = Vector{Float64}(undef, n_out)
    col_gaze = Vector{Float64}(undef, n_out)
    col_total = Vector{Float64}(undef, n_out)
    col_count = Vector{Int}(undef, n_out)
    col_revisits = Vector{Int}(undef, n_out)
    col_skipped = Vector{Bool}(undef, n_out)

    if n_out > 0
        _fixation_metrics_flat!(
            row_first_idx,
            col_aoi,
            col_ffd,
            col_ffo,
            col_gaze,
            col_total,
            col_count,
            col_revisits,
            col_skipped,
            d,
            grouped,
            aois,
            d[!, c_infix],
            d[!, c_fgx],
            d[!, c_fgy],
            d[!, c_fdur],
            has_trel,
            has_trel ? d[!, :time_rel] : nothing,
            d[!, :time],
            time_window,
        )
    end

    pairs_out = Pair{Symbol,Any}[
        gc => _gather_group_col(d[!, gc], row_first_idx) for gc in group_cols
    ]
    push!(pairs_out, :aoi => col_aoi)
    push!(pairs_out, :first_fixation_duration => col_ffd)
    push!(pairs_out, :first_fixation_onset => col_ffo)
    push!(pairs_out, :gaze_duration => col_gaze)
    push!(pairs_out, :total_time => col_total)
    push!(pairs_out, :fixation_count => col_count)
    push!(pairs_out, :revisits => col_revisits)
    push!(pairs_out, :skipped => col_skipped)
    return DataFrame(pairs_out; copycols = false)
end
