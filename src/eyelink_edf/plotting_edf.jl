# ── EDFFile plotting methods ───────────────────────────────────────────────── #
# Thin wrappers that build an EyeData from the EDFFile and delegate to the

"""
    plot_gaze(edf::EDFFile; kwargs...)

Plot gaze from an EDFFile.
"""
plot_gaze(edf::EDFFile; kwargs...) = plot_gaze(create_eyelink_edf_dataframe(edf); kwargs...)

"""
    plot_scanpath(edf::EDFFile; kwargs...)

Plot scanpath from an EDFFile.
"""
plot_scanpath(edf::EDFFile; kwargs...) =
    plot_scanpath(create_eyelink_edf_dataframe(edf); kwargs...)

"""
    plot_heatmap(edf::EDFFile; kwargs...)

Plot heatmap from an EDFFile.
"""
plot_heatmap(edf::EDFFile; kwargs...) =
    plot_heatmap(create_eyelink_edf_dataframe(edf); kwargs...)
