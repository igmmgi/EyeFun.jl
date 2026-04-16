# ── plot_heatmap ───────────────────────────────────────────────────────────── #

"""
    _build_heatmap_data(samples, eye, xlims, ylims, bins, metric, sample_rate)

Build the heatmap matrix for a given metric. Returns (x_centers, y_centers, values, label).

Metrics:
- `:samples` — raw sample counts per bin
- `:dwell` — dwell time in ms (samples / sample_rate × 1000)
- `:count` — fixation count (uses `fix_gavx`/`fix_gavy` centers)
- `:proportion` — proportion of total samples per bin (sums to 1.0)
"""
function _build_heatmap_data(
    samples::DataFrame,
    eye::Symbol,
    xlims,
    ylims,
    bins,
    metric::Symbol,
    sample_rate::Float64,
)
    gx, gy, eye_label = _select_eye(samples, eye)

    if metric == :count
        # Use fixation centers instead of raw samples
        # Find unique fixations by detecting transitions in fix_gavx/fix_gavy
        if hasproperty(samples, :fix_gavx) && hasproperty(samples, :fix_gavy)
            in_fix = samples.in_fix
            fix_gx = samples.fix_gavx
            fix_gy = samples.fix_gavy

            ux, uy = Float64[], Float64[]
            for i = 1:nrow(samples)
                in_fix[i] || continue
                # Detect fixation onset: first sample of a new fixation run
                i > 1 && in_fix[i-1] && continue
                fx_val, fy_val = Float64(fix_gx[i]), Float64(fix_gy[i])
                isnan(fx_val) && continue
                isnan(fy_val) && continue

                push!(ux, fx_val)
                push!(uy, fy_val)
            end

            if !isempty(ux)
                x_c, y_c, vals = _bin_samples(ux, uy, xlims, ylims, bins)
                return x_c, y_c, vals, eye_label, "Fixation count"
            end
        end
        # Fallback to sample count if no fixation data
        metric = :samples
    end

    # Filter valid gaze samples
    valid = .!isnan.(gx) .& .!isnan.(gy)
    px = Float64.(gx[valid])
    py = Float64.(gy[valid])
    x_c, y_c, counts = _bin_samples(px, py, xlims, ylims, bins)

    if metric == :dwell
        # Convert samples to milliseconds
        vals = counts ./ sample_rate .* 1000.0
        return x_c, y_c, vals, eye_label, "Dwell time (ms)"
    elseif metric == :proportion
        total = sum(counts)
        vals = total > 0 ? counts ./ total : counts
        return x_c, y_c, vals, eye_label, "Proportion"
    else  # :samples
        return x_c, y_c, counts, eye_label, "Sample count"
    end
end



"""
    plot_heatmap(df::EyeData; selection=nothing, eye=:auto,
                 xlims=(0,df.screen_res[1]), ylims=(0,df.screen_res[2]), ydir=:down,
                 bins=(50,50), colormap=:inferno, metric=:samples, sigma=2.0,
                 background=nothing, split_by=nothing)

Plot a 2D gaze density heatmap from a wide DataFrame.

# Metrics
- `:samples` — raw sample count per bin
- `:dwell` — dwell time in ms
- `:count` — fixation count (uses fixation centers)
- `:proportion` — proportion of total (sums to 1.0)

# Parameters
- `background`: path to stimulus image to overlay
- `split_by`: column name (Symbol) for multi-panel comparison, e.g. `split_by=:type`
- `sigma=0` to disable Gaussian smoothing
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
    background = nothing,
    split_by = nothing,
    aois = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    # ── Faceted multi-panel heatmap ──
    if !isnothing(split_by)
        groups, split_vals, n_panels =
            _prepare_split_panels(samples, split_by; max_panels = 4)

        # Compute all panels first to get shared color range
        sr = df.sample_rate
        panel_data = []
        for lev in split_vals
            sub = filter(r -> r[split_by] == lev, groups)
            x_c, y_c, vals, _, cb_label =
                _build_heatmap_data(sub, eye, xlims, ylims, bins, metric, sr)
            vals = _gaussian_smooth(vals, sigma)
            push!(
                panel_data,
                (
                    x_c = x_c,
                    y_c = y_c,
                    vals = vals,
                    label = string(lev),
                    cb_label = cb_label,
                ),
            )
        end

        # Find global min/max for shared colorbar
        all_vals = reduce(vcat, [vec(pd.vals) for pd in panel_data])
        vmin, vmax = minimum(all_vals), maximum(all_vals)
        vmax == vmin && (vmax = vmin + 1.0)  # avoid degenerate range

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
            ax.yreversed = (ydir == :down)
            Makie.xlims!(ax, xlims...)
            Makie.ylims!(ax, ylims...)

            if !isnothing(background)
                img = load_image(background)
                Makie.image!(ax, xlims[1]..xlims[2], ylims[1]..ylims[2], Makie.rotr90(img))
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

    # ── Single panel ──
    sr = df.sample_rate
    x_c, y_c, vals, eye_label, cb_label =
        _build_heatmap_data(samples, eye, xlims, ylims, bins, metric, sr)
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
    ax.yreversed = (ydir == :down)
    Makie.xlims!(ax, xlims...)
    Makie.ylims!(ax, ylims...)

    if !isnothing(background)
        img = load_image(background)
        Makie.image!(ax, xlims[1]..xlims[2], ylims[1]..ylims[2], Makie.rotr90(img))
    end

    hm = Makie.heatmap!(ax, x_c, y_c, vals; colormap = colormap, interpolate = true)
    !isnothing(aois) && _draw_aois!(ax, aois)
    Colorbar(fig[1, 2], hm; label = cb_label)

    return fig
end
