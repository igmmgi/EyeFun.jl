function _aggregate_series_ribbon(
    df::AbstractDataFrame,
    time_col::Symbol,
    val_col::Symbol,
    subj_col::Union{Nothing,Symbol},
    error_mode::Symbol,
)
    t_raw = df[!, time_col]
    v_raw = df[!, val_col]
    has_subj = !isnothing(subj_col) && hasproperty(df, subj_col)

    # Check if >1 distinct non-missing subjects exist; if so, aggregate within (subject, time_bin) first
    use_subj = false
    if has_subj
        scol = df[!, subj_col]
        first_s = nothing
        for s in scol
            ismissing(s) && continue
            if isnothing(first_s)
                first_s = s
            elseif !isequal(s, first_s)
                use_subj = true
                break
            end
        end
    end

    time_vals = sort(Float64[Float64(t) for t in unique(skipmissing(t_raw)) if !isnan(Float64(t))])
    nb = length(time_vals)
    t_map = Dict{Float64,Int}(time_vals[i] => i for i = 1:nb)

    means = fill(NaN, nb)
    errs = zeros(Float64, nb)

    if use_subj
        scol = df[!, subj_col]
        subjs = collect(Set(skipmissing(scol)))
        ns = length(subjs)
        s_map = Dict{Any,Int}(subjs[i] => i for i = 1:ns)
        cell_sum = zeros(Float64, ns, nb)
        cell_cnt = zeros(Int, ns, nb)

        @inbounds for r = 1:nrow(df)
            sv = scol[r]
            tv = t_raw[r]
            vv = v_raw[r]
            (ismissing(sv) || ismissing(tv) || ismissing(vv)) && continue
            tf = Float64(tv)
            vf = Float64(vv)
            (isnan(tf) || isnan(vf)) && continue
            si = get(s_map, sv, 0)
            bi = get(t_map, tf, 0)
            (si == 0 || bi == 0) && continue
            cell_sum[si, bi] += vf
            cell_cnt[si, bi] += 1
        end

        @inbounds for b = 1:nb
            cnt = 0
            s = 0.0
            for i = 1:ns
                if cell_cnt[i, b] > 0
                    s += cell_sum[i, b] / cell_cnt[i, b]
                    cnt += 1
                end
            end
            cnt == 0 && continue
            mu = s / cnt
            means[b] = mu
            if cnt >= 2 && error_mode !== :none
                ss = 0.0
                for i = 1:ns
                    if cell_cnt[i, b] > 0
                        d = (cell_sum[i, b] / cell_cnt[i, b]) - mu
                        ss += d * d
                    end
                end
                sd = sqrt(ss / (cnt - 1))
                sem = sd / sqrt(Float64(cnt))
                errs[b] =
                    error_mode === :sd ? sd :
                    error_mode === :ci95 ? _student_t_crit_two_tailed(0.05, Float64(cnt - 1)) * sem :
                    sem
            end
        end
    else
        bsum = zeros(Float64, nb)
        bcnt = zeros(Int, nb)
        @inbounds for r = 1:nrow(df)
            tv = t_raw[r]
            vv = v_raw[r]
            (ismissing(tv) || ismissing(vv)) && continue
            tf = Float64(tv)
            vf = Float64(vv)
            (isnan(tf) || isnan(vf)) && continue
            bi = get(t_map, tf, 0)
            bi == 0 && continue
            bsum[bi] += vf
            bcnt[bi] += 1
        end
        @inbounds for b = 1:nb
            bcnt[b] == 0 && continue
            means[b] = bsum[b] / bcnt[b]
        end
        if error_mode !== :none
            bss = zeros(Float64, nb)
            @inbounds for r = 1:nrow(df)
                tv = t_raw[r]
                vv = v_raw[r]
                (ismissing(tv) || ismissing(vv)) && continue
                tf = Float64(tv)
                vf = Float64(vv)
                (isnan(tf) || isnan(vf)) && continue
                bi = get(t_map, tf, 0)
                bi == 0 && continue
                d = vf - means[bi]
                bss[bi] += d * d
            end
            @inbounds for b = 1:nb
                cnt = bcnt[b]
                cnt < 2 && continue
                sd = sqrt(bss[b] / (cnt - 1))
                sem = sd / sqrt(Float64(cnt))
                errs[b] =
                    error_mode === :sd ? sd :
                    error_mode === :ci95 ? _student_t_crit_two_tailed(0.05, Float64(cnt - 1)) * sem :
                    sem
            end
        end
    end

    valid = Bool[!isnan(means[b]) for b = 1:nb]
    return time_vals[valid], means[valid], errs[valid]
end

"""
    plot_time_course(df::DataFrame; time_col=:time_bin, value_col=:auto,
                     group_col=nothing, subject_col=:participant, error=:sem,
                     clusters=nothing, alpha=0.05, vline=0.0, hline=nothing,
                     title="Time Course", xlabel="Time (ms)", ylabel=nothing) -> Figure

Plot condition- or AOI-grouped time-course curves with shaded uncertainty ribbons (`:sem`,
`:ci95`, `:sd`, or `:none`) and optional significant cluster intervals from
[`cluster_permutation_test`](@ref).

Works directly with outputs of [`time_bin`](@ref), [`proportion_of_looks`](@ref), and
[`empirical_logit`](@ref). When multiple participants are present in `subject_col`, means are
first aggregated within participant so uncertainty ribbons reflect between-participant variance.
"""
function plot_time_course(
    df::DataFrame;
    time_col::Symbol = :time_bin,
    value_col::Union{Symbol,AbstractVector{Symbol}} = :auto,
    group_col::Union{Nothing,Symbol} = nothing,
    subject_col::Union{Nothing,Symbol} = :participant,
    error::Symbol = :sem,
    clusters::Union{Nothing,DataFrame} = nothing,
    alpha::Real = 0.05,
    vline::Union{Nothing,Real} = 0.0,
    hline::Union{Nothing,Real} = nothing,
    title::AbstractString = "Time Course",
    xlabel::AbstractString = "Time (ms)",
    ylabel::Union{Nothing,AbstractString} = nothing,
)
    nrow(df) > 0 || Base.error("Cannot plot_time_course on an empty DataFrame.")
    hasproperty(df, time_col) ||
        throw(ArgumentError("Time column :$time_col not found in DataFrame."))
    error in (:sem, :ci95, :sd, :none) ||
        throw(ArgumentError("Invalid error=:$error. Choose :sem, :ci95, :sd, or :none."))

    # Resolve target value column(s)
    val_cols = if value_col isa AbstractVector
        Symbol[Symbol(c) for c in value_col]
    elseif value_col !== :auto
        Symbol[value_col]
    elseif hasproperty(df, :value)
        Symbol[:value]
    elseif hasproperty(df, :mean)
        Symbol[:mean]
    elseif hasproperty(df, :proportion)
        Symbol[:proportion]
    else
        skip_set = Set{Symbol}([:participant, :trial, time_col, :outside, :n, :sample])
        !isnothing(group_col) && push!(skip_set, group_col)
        !isnothing(subject_col) && push!(skip_set, subject_col)
        Symbol[
            c for c in propertynames(df) if
            !(c in skip_set) && eltype(df[!, c]) <: Union{Missing,Real} && !startswith(String(c), "ot")
        ]
    end
    isempty(val_cols) &&
        throw(ArgumentError("Could not auto-detect numeric value column(s); pass value_col= explicitly."))
    for vc in val_cols
        hasproperty(df, vc) || throw(ArgumentError("Value column :$vc not found in DataFrame."))
    end
    if !isnothing(group_col)
        hasproperty(df, group_col) ||
            throw(ArgumentError("Group column :$group_col not found in DataFrame."))
    end

    auto_ylabel = !isnothing(ylabel) ? String(ylabel) :
                  (length(val_cols) == 1 ? String(val_cols[1]) : "Proportion / Value")

    fig = Figure(size = (850, 450))
    ax = Axis(
        fig[1, 1];
        xlabel = String(xlabel),
        ylabel = auto_ylabel,
        title = String(title),
    )

    # Shade significant temporal clusters if supplied
    if !isnothing(clusters) && nrow(clusters) > 0 &&
       hasproperty(clusters, :t_start) && hasproperty(clusters, :t_end)
        clo = Float64[]
        chi = Float64[]
        has_p = hasproperty(clusters, :p_value)
        for r = 1:nrow(clusters)
            (!has_p || Float64(clusters.p_value[r]) <= Float64(alpha)) || continue
            lo = Float64(clusters.t_start[r])
            hi = Float64(clusters.t_end[r])
            push!(clo, lo)
            push!(chi, max(lo + 1.0, hi))
        end
        !isempty(clo) && Makie.vspan!(ax, clo, chi; color = (:gold, 0.25))
    end

    !isnothing(vline) && Makie.vlines!(ax, [Float64(vline)]; color = :gray60, linestyle = :dash, linewidth = 1)
    !isnothing(hline) && Makie.hlines!(ax, [Float64(hline)]; color = :gray60, linestyle = :dot, linewidth = 1)

    colors = Makie.wong_colors()
    color_idx = 0
    has_legend_entries = false

    if !isnothing(group_col)
        g_levels = sort(collect(Set(skipmissing(df[!, group_col]))))
        for gl in g_levels
            mask = trues(nrow(df))
            _mark_equal!(mask, df[!, group_col], gl)
            sub = @view df[mask, :]
            for vc in val_cols
                color_idx += 1
                col = colors[mod1(color_idx, length(colors))]
                ts, ms, es = _aggregate_series_ribbon(sub, time_col, vc, subject_col, error)
                isempty(ts) && continue
                lbl = length(val_cols) == 1 ? string(gl) : "$(gl) ($(vc))"
                if error !== :none
                    Makie.band!(ax, ts, ms .- es, ms .+ es; color = (col, 0.22))
                end
                Makie.lines!(ax, ts, ms; color = col, linewidth = 2.2, label = lbl)
                has_legend_entries = true
            end
        end
    else
        for vc in val_cols
            color_idx += 1
            col = colors[mod1(color_idx, length(colors))]
            ts, ms, es = _aggregate_series_ribbon(df, time_col, vc, subject_col, error)
            isempty(ts) && continue
            lbl = length(val_cols) > 1 ? string(vc) : nothing
            if error !== :none
                Makie.band!(ax, ts, ms .- es, ms .+ es; color = (col, 0.22))
            end
            Makie.lines!(ax, ts, ms; color = col, linewidth = 2.2, label = lbl)
            !isnothing(lbl) && (has_legend_entries = true)
        end
    end

    has_legend_entries && axislegend(ax; position = :rt)
    return fig
end

