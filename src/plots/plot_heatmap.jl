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
            fix_rows = filter(r -> r.in_fix == true, samples)
            if nrow(fix_rows) > 0
                fx = Float64.(fix_rows.fix_gavx)
                fy = Float64.(fix_rows.fix_gavy)
                # Deduplicate: consecutive identical fixation centers = same fixation
                ux, uy = Float64[], Float64[]
                for i in eachindex(fx)
                    if isnan(fx[i]) || isnan(fy[i])
                        continue
                    end
                    if isempty(ux) || fx[i] != ux[end] || fy[i] != uy[end]
                        push!(ux, fx[i])
                        push!(uy, fy[i])
                    end
                end
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
                 xlims=(0,1280), ylims=(0,960), ydir=:down,
                 bins=(50,50), colormap=:inferno, metric=:samples, sigma=2.0,
                 background=nothing, facet=nothing)

Plot a 2D gaze density heatmap from a wide DataFrame.

# Metrics
- `:samples` — raw sample count per bin
- `:dwell` — dwell time in ms
- `:count` — fixation count (uses fixation centers)
- `:proportion` — proportion of total (sums to 1.0)

# Extra
- `background`: path to stimulus image to overlay
- `facet`: column name (Symbol) for multi-panel comparison, e.g. `facet=:type`
- `sigma=0` to disable Gaussian smoothing
"""
function plot_heatmap(
    df::EyeData;
    selection = nothing,
    eye::Symbol = :auto,
    xlims = (0, 1280),
    ylims = (0, 960),
    ydir::Symbol = :down,
    bins = (50, 50),
    colormap = :inferno,
    metric::Symbol = :samples,
    sigma::Real = 2.0,
    background = nothing,
    facet = nothing,
    aois = nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    # ── Faceted multi-panel heatmap ──
    if facet !== nothing
        hasproperty(samples, facet) || error("Column :$facet not found for faceting.")
        groups = filter(r -> !ismissing(r[facet]), samples)
        facet_vals = sort(unique(groups[!, facet]))
        n_panels = length(facet_vals)
        n_panels == 0 && error("No non-missing values in :$facet for faceting.")

        aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
        panel_w = 400
        panel_h = round(Int, panel_w / aspect_ratio)
        fig = Figure(size = (panel_w * n_panels + 100, panel_h + 80))

        local hm_ref
        local cb_label_facet = ""
        for (idx, fval) in enumerate(facet_vals)
            sub = filter(r -> r[facet] == fval, groups)
            sr = 1000.0
            x_c, y_c, vals, _, cb_label_facet =
                _build_heatmap_data(sub, eye, xlims, ylims, bins, metric, sr)
            vals = _gaussian_smooth(vals, sigma)

            ax = Axis(
                fig[1, idx];
                xlabel = "X (px)",
                ylabel = idx == 1 ? "Y (px)" : "",
                title = "$fval",
            )
            ax.yreversed = (ydir == :down)

            if background !== nothing
                img = Makie.FileIO.load(background)
                Makie.image!(ax, xlims[1]..xlims[2], ylims[1]..ylims[2], Makie.rotr90(img))
            end

            hm_ref =
                Makie.heatmap!(ax, x_c, y_c, vals; colormap = colormap, interpolate = true)
        end
        Colorbar(fig[1, n_panels+1], hm_ref; label = cb_label_facet)
        return fig
    end

    # ── Single panel ──
    sr = 1000.0
    x_c, y_c, vals, eye_label, cb_label =
        _build_heatmap_data(samples, eye, xlims, ylims, bins, metric, sr)
    vals = _gaussian_smooth(vals, sigma)

    title_sel = selection !== nothing ? " ($selection)" : ""
    title = "Heatmap$title_sel ($eye_label)"

    aspect_ratio = (xlims[2] - xlims[1]) / (ylims[2] - ylims[1])
    fig_h = 650
    fig_w = round(Int, fig_h * aspect_ratio + 100)
    fig = Figure(size = (fig_w, fig_h))
    ax = Axis(fig[1, 1]; xlabel = "X (px)", ylabel = "Y (px)", title = title)
    ax.yreversed = (ydir == :down)

    if background !== nothing
        img = Makie.FileIO.load(background)
        Makie.image!(ax, xlims[1]..xlims[2], ylims[1]..ylims[2], Makie.rotr90(img))
    end

    hm = Makie.heatmap!(ax, x_c, y_c, vals; colormap = colormap, interpolate = true)
    aois !== nothing && _draw_aois!(ax, aois)
    Colorbar(fig[1, 2], hm; label = cb_label)

    return fig
end
