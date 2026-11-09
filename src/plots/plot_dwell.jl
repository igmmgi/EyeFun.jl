function _count_aoi_samples(
    aoi::AOI,
    gx::AbstractVector{<:Real},
    gy::AbstractVector{<:Real},
    t_rel::Union{Nothing,Vector{Float64}} = nothing,
)
    cnt = 0
    if isnothing(t_rel)
        @inbounds for i in eachindex(gx, gy)
            xi = Float64(gx[i])
            yi = Float64(gy[i])
            if !isnan(xi) && !isnan(yi) && _in_aoi_fast(aoi, xi, yi)
                cnt += 1
            end
        end
    else
        @inbounds for i in eachindex(gx, gy, t_rel)
            xi = Float64(gx[i])
            yi = Float64(gy[i])
            if !isnan(xi) && !isnan(yi) && _in_aoi_fast(aoi, xi, yi, t_rel[i])
                cnt += 1
            end
        end
    end
    return cnt
end

function _samples_rel_time(samples::AbstractDataFrame)
    if hasproperty(samples, :time_rel)
        out, ok = _extract_rel_time_from_col(samples[!, :time_rel])
        ok && return out
    end
    n = nrow(samples)
    out = fill(NaN, n)
    times = samples[!, :time]
    if hasproperty(samples, :trial)
        tr = samples[!, :trial]
        p_col = _has_multiple_participants(samples) ? samples[!, :participant] : nothing
        i = 1
        @inbounds while i <= n
            if ismissing(tr[i])
                i += 1
                continue
            end
            tv = tr[i]
            pv = isnothing(p_col) ? nothing : p_col[i]
            t0 = Float64(times[i])
            out[i] = 0.0
            j = i + 1
            while j <= n &&
                      !ismissing(tr[j]) &&
                      tr[j] == tv &&
                      (isnothing(p_col) || isequal(p_col[j], pv)) &&
                      Float64(times[j]) >= Float64(times[j-1])
                out[j] = Float64(times[j]) - t0
                j += 1
            end
            i = j
        end
        return out
    end
    return _extract_rel_time_from_raw(times)
end

"""
    plot_dwell(df::EyeData, aois::Vector{<:AOI};
               selection=nothing, eye=:auto)

Bar chart of dwell time (ms) per Area of Interest.

# Example
```julia
aois = [RectAOI("Face", 600, 400, 400, 400), CircleAOI("Cross", 640, 480, 50)]
plot_dwell(df, aois; selection=(trial=1,))
```
"""
function plot_dwell(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    eye::Symbol = :auto,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    gx, gy, _ = _select_eye(samples, eye)

    aoi_names = [a.name for a in aois]
    dwell_ms = Vector{Float64}(undef, length(aois))
    colors = Makie.wong_colors()
    ms_per_sample = 1000.0 / df.sample_rate

    t_rel = any(a -> a isa DynamicAOI, aois) ? _samples_rel_time(samples) : nothing

    for (k, aoi) in enumerate(aois)
        dwell_ms[k] = _count_aoi_samples(aoi, gx, gy, t_rel) * ms_per_sample
    end

    fig = Figure(size = (500, 400))
    ax = Axis(
        fig[1, 1];
        xlabel = "AOI",
        ylabel = "Dwell time (ms)",
        title = _format_title("Dwell Time", selection),
        xticks = (1:length(aoi_names), aoi_names),
    )

    barcolors = [
        isnothing(aois[i].color) ? colors[mod1(i, length(colors))] : aois[i].color for
        i = 1:length(aois)
    ]
    barplot!(ax, 1:length(aoi_names), dwell_ms; color = barcolors)

    return fig
end
