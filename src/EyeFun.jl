"""
EyeFun.jl — Eye-tracking data analysis and visualisation in Julia.
"""

module EyeFun

using DataFrames
using Makie
using Statistics

# ── Public API ─────────────────────────────────────────────────────────────── #

# Types
export EyeData

# I/O
export read_eyelink_edf
export read_eyelink_edf_binary
export read_eyelink_edf_asc
export write_eyelink_edf_to_asc
export create_eyelink_edf_dataframe
export read_eyelink_edf_dataframe
export batch_read_eyelink_edf_dataframe

# Event accessors
export saccades
export fixations
export blinks
export messages
export aois
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

# Event detection
export detect_events!
export detect_microsaccades!

# Plotting
export plot_gaze
export plot_scanpath
export plot_heatmap
export plot_fixations
export plot_pupil
export plot_velocity
export plot_dwell
export plot_databrowser

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

# Analysis
include("analysis/analysis.jl")
include("analysis/aoi.jl")
include("analysis/batch.jl")
include("analysis/detect_events.jl")
include("analysis/drift.jl")
include("analysis/microsaccades.jl")
include("analysis/pupil.jl")

# Plotting
include("plots/common/common.jl")
include("plots/plot_gaze.jl")
include("plots/plot_scanpath.jl")
include("plots/plot_heatmap.jl")
include("plots/plot_fixations.jl")
include("plots/plot_pupil.jl")
include("plots/plot_velocity.jl")
include("plots/plot_dwell.jl")
include("plots/plot_databrowser.jl")
include("eyelink_edf/plotting_edf.jl")

end
