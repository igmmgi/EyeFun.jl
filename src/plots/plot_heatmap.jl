function _extract_unique_fix_xy(
    samples::AbstractDataFrame,
    in_fix::AbstractVector{Bool},
    fix_gx::AbstractVector{<:Real},
    fix_gy::AbstractVector{<:Real},
)
    ux = Float64[]
    uy = Float64[]
    tr_col = hasproperty(samples, :trial) ? samples[!, :trial] : nothing
    p_col = _has_multiple_participants(samples) ? samples[!, :participant] : nothing
    times = hasproperty(samples, :time) ? samples[!, :time] : nothing
    prev = false
    @inbounds for i in eachindex(in_fix)
        if _is_new_plot_trial(tr_col, p_col, times, i)
            prev = false
        end
        cur = in_fix[i]
        if cur & !prev
            x = Float64(fix_gx[i])
            y = Float64(fix_gy[i])
            if !isnan(x) && !isnan(y)
                push!(ux, x)
                push!(uy, y)
            end
        end
        prev = cur
    end
    return ux, uy
end

function _extract_valid_xy(gx::AbstractVector{<:Real}, gy::AbstractVector{<:Real})
    px = Float64[]
    py = Float64[]
    @inbounds for i in eachindex(gx, gy)
        x = Float64(gx[i])
        y = Float64(gy[i])
        if !isnan(x) && !isnan(y)
            push!(px, x)
            push!(py, y)
        end
    end
    return px, py
end

"""
    _build_heatmap_data(samples, eye, xlims, ylims, bins, metric, sample_rate)

Build the heatmap matrix for a given metric. Returns `(x_centers, y_centers, values, eye_label, cb_label)`.
"""
function _build_heatmap_data(
    samples::AbstractDataFrame,
    eye::Symbol,
    xlims,
    ylims,
    bins,
    metric::Symbol,
    sample_rate::Float64,
    prefix::Union{Nothing,Symbol} = nothing,
)
    gx, gy, eye_label = _select_eye(samples, eye)

    if metric == :count
        c_infix = _prefixed_sym(prefix, :in_fix)
        c_fgx = _prefixed_sym(prefix, :fix_gavx)
        c_fgy = _prefixed_sym(prefix, :fix_gavy)
        if hasproperty(samples, c_fgx) && hasproperty(samples, c_fgy) && hasproperty(samples, c_infix)
            ux, uy = _extract_unique_fix_xy(samples, samples[!, c_infix], samples[!, c_fgx], samples[!, c_fgy])
            if !isempty(ux)
                x_c, y_c, vals = _bin_samples(ux, uy, xlims, ylims, bins)
                return x_c, y_c, vals, eye_label, "Fixation count"
            end
        end
        metric = :samples
    end

    px, py = _extract_valid_xy(gx, gy)
    x_c, y_c, counts = _bin_samples(px, py, xlims, ylims, bins)

    if metric == :dwell
        vals = counts ./ sample_rate .* 1000.0
        return x_c, y_c, vals, eye_label, "Dwell time (ms)"
    elseif metric == :proportion
        total = sum(counts)
        vals = total > 0 ? counts ./ total : counts
        return x_c, y_c, vals, eye_label, "Proportion"
    else
        return x_c, y_c, counts, eye_label, "Sample count"
    end
end

"""
    plot_heatmap(df::EyeData; selection=nothing, eye=:auto,
                 xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                 bins=(50,50), colormap=:inferno, metric=:samples, sigma=2.0,
                 background=nothing, split_by=nothing, aois=nothing, prefix=nothing)

Plot a 2D gaze density heatmap from a wide DataFrame.
"""
function plot_heatmap(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    xlims = (0, df.screen_res[1]),
    ylims = (0, df.screen_res[2]),
    ydir::Symbol = :down,
    bins = (50, 50),
    colormap = :inferno,
    metric::Symbol = :samples,
    sigma::Real = 2.0,
    background::Union{String,Nothing} = nothing,
    split_by::Union{Symbol,Nothing} = nothing,
    aois = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)
    metric in (:samples, :dwell, :count, :proportion) ||
        error("Invalid metric :$metric. Choose :samples, :dwell, :count, or :proportion")

    samples = _apply_selection_view(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    bg_img_oriented = if !isnothing(background)
        img = load_image(background)
        ydir == :down ? permutedims(img, (2, 1)) : Makie.rotr90(img)
    else
        nothing
    end

    if !isnothing(split_by)
        groups, split_vals, n_panels =
            _prepare_split_panels(samples, split_by; max_panels = 4)

        sr = df.sample_rate
        panel_data = map(split_vals) do fval
            sub = _panel_view(groups, split_by, fval)
            x_c, y_c, vals, _, cb_label =
                _build_heatmap_data(sub, eye, xlims, ylims, bins, metric, sr, prefix)
            vals = _gaussian_smooth(vals, sigma)
            (x_c = x_c, y_c = y_c, vals = vals, cb_label = cb_label, label = string(fval))
        end

        vmin = minimum(minimum(pd.vals) for pd in panel_data)
        vmax = maximum(maximum(pd.vals) for pd in panel_data)
        vmin == vmax && (vmax = vmin + 1.0)

        aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
        fig = _create_split_figure(
            split_by,
            n_panels;
            panel_w = 400,
            aspect_ratio = aspect_ratio,
        )

        local hm_ref
        for (idx, pd) in enumerate(panel_data)
            ax = Axis(
                fig[1, idx];
                xlabel = "X (px)",
                ylabel = idx == 1 ? "Y (px)" : "",
                title = pd.label,
                aspect = DataAspect(),
            )
            Makie.xlims!(ax, xlims...)
            Makie.ylims!(ax, ylims...)
            ax.yreversed = (ydir == :down)

            if !isnothing(bg_img_oriented)
                Makie.image!(ax, xlims[1]..xlims[2], ylims[1]..ylims[2], bg_img_oriented)
            end

            hm_ref = Makie.heatmap!(
                ax,
                pd.x_c,
                pd.y_c,
                pd.vals;
                colormap = colormap,
                interpolate = true,
                colorrange = (vmin, vmax),
            )

            !isnothing(aois) && _draw_aois!(ax, aois)
        end
        Colorbar(fig[1, n_panels+1], hm_ref; label = panel_data[1].cb_label)
        return fig
    end

    sr = df.sample_rate
    x_c, y_c, vals, _, cb_label =
        _build_heatmap_data(samples, eye, xlims, ylims, bins, metric, sr, prefix)
    vals = _gaussian_smooth(vals, sigma)

    title = _format_title("Heatmap", selection)

    aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
    fig_h = 650
    fig_w = round(Int, fig_h * aspect_ratio + 100)
    fig = Figure(size = (fig_w, fig_h))
    ax = Axis(
        fig[1, 1];
        xlabel = "X (px)",
        ylabel = "Y (px)",
        title = title,
        aspect = DataAspect(),
    )
    Makie.xlims!(ax, xlims...)
    Makie.ylims!(ax, ylims...)
    ax.yreversed = (ydir == :down)

    if !isnothing(bg_img_oriented)
        Makie.image!(ax, xlims[1]..xlims[2], ylims[1]..ylims[2], bg_img_oriented)
    end

    hm = Makie.heatmap!(ax, x_c, y_c, vals; colormap = colormap, interpolate = true)
    !isnothing(aois) && _draw_aois!(ax, aois)
    Colorbar(fig[1, 2], hm; label = cb_label)

    return fig
end
