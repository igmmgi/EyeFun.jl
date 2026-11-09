function _extract_sacc_vel_stems(
    sub::AbstractDataFrame,
    in_sacc::AbstractVector{Bool},
    sacc_pvel::AbstractVector{<:Real},
    times::AbstractVector{<:Real},
    time_rel::Union{Nothing,AbstractVector},
)
    t_mid = Float64[]
    pvel = Float64[]
    tr_col = hasproperty(sub, :trial) ? sub[!, :trial] : nothing
    p_col = _has_multiple_participants(sub) ? sub[!, :participant] : nothing
    part_t0 = isempty(times) ? 0.0 : Float64(times[1])

    prev = false
    @inbounds for i in eachindex(in_sacc)
        if _is_new_plot_trial(tr_col, p_col, times, i)
            prev = false
            if i == 1 || (!isnothing(p_col) && !isequal(p_col[i], p_col[i-1])) || Float64(times[i]) < Float64(times[i-1])
                part_t0 = Float64(times[i])
            end
        end
        cur = in_sacc[i]
        if cur & !prev
            pv = Float64(sacc_pvel[i])
            if !isnan(pv)
                t_val = if !isnothing(time_rel)
                    rv = time_rel[i]
                    ismissing(rv) ? NaN : Float64(rv)
                else
                    Float64(times[i]) - part_t0
                end
                if !isnan(t_val)
                    push!(t_mid, t_val)
                    push!(pvel, pv)
                end
            end
        end
        prev = cur
    end
    return t_mid, pvel
end

"""
    plot_velocity(df::EyeData; selection=nothing, split_by=nothing, prefix=nothing)

Plot saccade peak velocity over time as stem markers.
"""
function plot_velocity(
    df::EyeData;
    selection = nothing,
    split_by = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)
    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    c_insacc = _prefixed_sym(prefix, :in_sacc)
    c_spvel = _prefixed_sym(prefix, :sacc_pvel)
    hasproperty(samples, c_spvel) || error(
        "No saccade columns ($c_spvel). Run detect_events!(df) first.",
    )

    groups, split_vals, n_panels = _prepare_split_panels(samples, split_by; max_panels = 4)
    title = _format_title("Saccade Velocity", selection)
    fig = _create_split_figure(split_by, n_panels; panel_w = 450, fig_h = 400)

    for (idx, fval) in enumerate(split_vals)
        sub_split = _panel_view(groups, split_by, fval)
        use_rel = _has_active_time_rel(sub_split)

        t_mid, pvel = _extract_sacc_vel_stems(
            sub_split,
            sub_split[!, c_insacc],
            sub_split[!, c_spvel],
            sub_split[!, :time],
            use_rel ? sub_split[!, :time_rel] : nothing,
        )

        ax = Axis(
            fig[1, idx];
            xlabel = "Time (ms)",
            ylabel = idx == 1 ? "Peak velocity (°/s)" : "",
            title = isnothing(fval) ? title : "$fval",
        )

        if !isempty(t_mid)
            slx = Vector{Float64}(undef, 3 * length(t_mid))
            sly = Vector{Float64}(undef, 3 * length(t_mid))
            @inbounds for i in eachindex(t_mid)
                base = 3 * (i - 1)
                ti = t_mid[i]
                slx[base+1] = ti
                slx[base+2] = ti
                slx[base+3] = NaN
                sly[base+1] = 0.0
                sly[base+2] = pvel[i]
                sly[base+3] = NaN
            end
            lines!(ax, slx, sly; color = :black, linewidth = 1.5)
            scatter!(
                ax,
                t_mid,
                pvel;
                color = :black,
                markersize = 10,
                strokewidth = 1,
                strokecolor = :black,
            )
        end
    end

    return fig
end
