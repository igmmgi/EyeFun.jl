"""
EyeFun.jl — Eye-tracking data analysis and visualisation in Julia.
"""

module EyeFun

using DataFrames
using LinearAlgebra
using Makie
using Printf
using Statistics

# no external dependencies beyond Makie now

# ── Public API ─────────────────────────────────────────────────────────────── #

# Types
export EyeData
export AOI, RectAOI, CircleAOI, EllipseAOI, PolygonAOI
export in_aoi

# I/O
export read_et_data
export write_et_ascii
export read_stimuli

# Event accessors
export saccades
export fixations
export blinks
export messages
export variables
export counts

# Analysis
export data_quality
export aoi_metrics
export group_summary
export interpolate_blinks!
export baseline_correct_pupil!
export smooth_pupil!
export drift_correct!
export exclude_trials!
export pupil_peak_metrics

# Coordinates
export pixels_per_degree
export px_to_deg
export deg_to_px
export to_center_coords!

# Transitions & scanpath
export transition_matrix
export transition_entropy
export scanpath_similarity

# Fixation metrics
export fixation_metrics
export saccade_metrics

# Time course
export time_bin
export proportion_of_looks

# Filtering
export velocity_filter!
export outlier_filter!
export interpolate_gaps!

# Statistics
export prepare_analysis_data
export growth_curve_data

# Event detection
export detect_events!
export detect_microsaccades!

# Plots
export plot_gaze
export plot_scanpath
export plot_heatmap
export plot_fixations
export plot_pupil
export plot_velocity
export plot_dwell
export plot_sequence
export plot_transitions
export plot_databrowser
export plot_stimuli
export play_wav

# ── Source files ──────────────────────────────────────────────────────────── #

# Core types
include("types.jl")

# EyeLink EDF support
include("eyelink_edf/types.jl")
include("eyelink_edf/constants.jl")
include("eyelink_edf/binary_reader.jl")
include("eyelink_edf/ascii_reader.jl")
include("eyelink_edf/parsers.jl")
include("eyelink_edf/ascii_exporter.jl")
include("eyelink_edf/eyelink.jl")

# SMI support
include("smi/types.jl")
include("smi/smi_reader.jl")
include("smi/smi_exporter.jl")

# Tobii support
include("tobii/types.jl")
include("tobii/tobii_reader.jl")

# Data I/O
include("io/read.jl")
include("io/write.jl")
include("io/read_gif.jl")
include("io/image_loader.jl")
include("io/stimulus_dict.jl")

# Analysis
include("analysis/analysis.jl")
include("analysis/aoi.jl")
include("analysis/coordinates.jl")
include("analysis/detect_events.jl")
include("analysis/drift.jl")
include("analysis/exclusion.jl")
include("analysis/filtering.jl")
include("analysis/fixation_metrics.jl")
include("analysis/microsaccades.jl")
include("analysis/pupil.jl")
include("analysis/saccade_metrics.jl")
include("analysis/scanpath.jl")
include("analysis/statistics.jl")
include("analysis/time_course.jl")

# Audio
include("audio/playback.jl")

# Plotting
include("plots/common/common.jl")
include("plots/plot_gaze.jl")
include("plots/plot_scanpath.jl")
include("plots/plot_heatmap.jl")
include("plots/plot_fixations.jl")
include("plots/plot_pupil.jl")
include("plots/plot_velocity.jl")
include("plots/plot_dwell.jl")
include("plots/plot_sequence.jl")
include("plots/plot_transitions.jl")
include("plots/plot_databrowser.jl")
include("plots/plot_stimuli.jl")

end
