# ── EDFFile plotting methods ───────────────────────────────────────────────── #
# Thin wrappers that build an EyeData from the EDFFile and delegate to the

"""
    plot_gaze(edf::EDFFile; kwargs...)

Plot gaze from an EDFFile.
"""
plot_gaze(edf::EDFFile; kwargs...) = plot_gaze(EyeData(edf); kwargs...)

"""
    plot_scanpath(edf::EDFFile; kwargs...)

Plot scanpath from an EDFFile.
"""
plot_scanpath(edf::EDFFile; kwargs...) = plot_scanpath(EyeData(edf); kwargs...)

"""
    plot_heatmap(edf::EDFFile; kwargs...)

Plot heatmap from an EDFFile.
"""
plot_heatmap(edf::EDFFile; kwargs...) = plot_heatmap(EyeData(edf); kwargs...)

"""
    plot_fixations(edf::EDFFile; kwargs...)

Plot fixations from an EDFFile.
"""
plot_fixations(edf::EDFFile; kwargs...) = plot_fixations(EyeData(edf); kwargs...)

"""
    plot_pupil(edf::EDFFile; kwargs...)

Plot pupil trace from an EDFFile.
"""
plot_pupil(edf::EDFFile; kwargs...) = plot_pupil(EyeData(edf); kwargs...)

"""
    plot_velocity(edf::EDFFile; kwargs...)

Plot saccade velocity from an EDFFile.
"""
plot_velocity(edf::EDFFile; kwargs...) = plot_velocity(EyeData(edf); kwargs...)
