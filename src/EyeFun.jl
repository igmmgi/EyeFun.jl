module EyeFun

"""
    EyeFun

Pure-Julia eye-tracking data import, preprocessing, event detection, spatial/AOI/pupil
analysis, and interactive Makie visualisation across EyeLink, SMI, and Tobii formats.
"""
EyeFun

using DataFrames
using Dates
using LinearAlgebra
using Makie
using PrecompileTools: @setup_workload, @compile_workload
using Printf
using Random
using Statistics

# Types
export EyeFile, EDFFile, SMIFile, TobiiFile
export EyeData
export AOI, RectAOI, CircleAOI, EllipseAOI, PolygonAOI, DynamicAOI
export in_aoi

# I/O
export read_et_data
export read_eyelink, read_smi, read_tobii
export read_et_delimited, write_et_delimited
export create_eyefun_data
export calibration_summary
export write_et_ascii
export read_stimuli

# Event accessors
export saccades
export fixations
export blinks
export microsaccades
export messages
export variables
export counts

# Analysis
export average_eyes!
export set_time_zero!
export data_quality
export spatial_precision
export aoi_metrics
export group_summary
export pupil_filter!
export correct_pupil_foreshortening!
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
export savitzky_golay_filter!

# Statistics
export prepare_analysis_data
export growth_curve_data
export empirical_logit
export cluster_permutation_test

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
export plot_time_course
export plot_databrowser
export plot_stimuli
export play_wav
export load_image
export image_size

# Media types
export AbstractEyeFunMedia
export ImageMedia
export AudioMedia
export TextMedia

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
include("io/delimited.jl")
include("io/read.jl")
include("io/write.jl")
include("io/read_gif.jl")
include("io/read_bmp.jl")
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
include("plots/plot_time_course.jl")
include("plots/databrowser_draw.jl")
include("plots/plot_databrowser.jl")
include("plots/plot_stimuli.jl")

@setup_workload begin
    n_pre = 180
    gx_pre = vcat(fill(450.0f0, 70), [450.0f0 + 25.0f0 * k for k = 1:10], fill(700.0f0, 60), fill(NaN32, 40))
    gy_pre = vcat(fill(400.0f0, 140), fill(NaN32, 40))
    pa_pre = vcat(fill(1100.0f0, 140), fill(NaN32, 40))
    df_pre = DataFrame(
        participant = fill("P1", n_pre),
        trial = fill(1, n_pre),
        time = collect(1.0:n_pre),
        gxL = gx_pre,
        gyL = gy_pre,
        paL = pa_pre,
        message = fill("", n_pre),
    )
    aois_pre = AOI[
        RectAOI("A", 450.0, 400.0, 120.0, 120.0),
        CircleAOI("B", 700.0, 400.0, 80.0),
    ]
    asc_bytes_pre = Vector{UInt8}(
        codeunits(
            "** PRECOMPILE\nMSG\t1000 DISPLAY_COORDS 0 0 1919 1079\nMSG\t1000 TRIALID 1\nSTART\t1000 \tLEFT\tSAMPLES\tEVENTS\nSAMPLES\tGAZE\tLEFT\tRATE\t1000.00\n1000\t  500.0\t  400.0\t 1200.0\t...\n1001\t  501.0\t  400.0\t 1201.0\t...\nEFIX L   1000\t1001\t2\t  500.5\t  400.0\t   1200\nEND\t1002 \tSAMPLES\tEVENTS\tRES\t  35.00\t  35.00\n",
        ),
    )

    @compile_workload begin
        ed_pre = EyeData(df_pre; sample_rate = 1000.0)
        detect_events!(ed_pre; method = :ivt, detect_blinks = true, min_blink_ms = 30)
        interpolate_blinks!(ed_pre)
        smooth_pupil!(ed_pre)
        fixations(ed_pre)
        saccades(ed_pre)
        blinks(ed_pre)
        data_quality(ed_pre)
        aoi_metrics(ed_pre, aois_pre)
        fixation_metrics(ed_pre, aois_pre)
        saccade_metrics(ed_pre)
        time_bin(ed_pre; bin_ms = 50)
        proportion_of_looks(ed_pre, aois_pre; bin_ms = 50)

        edf_pre = EDFFile("")
        _parse_asc_bytes!(edf_pre, asc_bytes_pre, true, "TRIALID", "TRIAL_RESULT", false)
        create_eyefun_data(edf_pre)
    end
end

end
