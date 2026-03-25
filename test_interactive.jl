# Interactive test script for EyeFun.jl
# Run line-by-line in the REPL or with `julia --project=. test_interactive.jl`

using EyeFun
using DataFrames
using GLMakie
using BenchmarkTools

# ── Read the EDF file ─────────────────────────────────────────────────────── #
# edf = read_eyelink("/home/ian/Documents/Julia/oA_1.edf")
edf = read_eyelink("/home/ian/Desktop/EyeTracking/data_2016/edf/201.edf")

# # ── Inspect the data (just type the variable — show methods do the work) ──── #
# edf                       # summary: samples, trials, events
# first(fixations(edf), 5)  # peek at fixation events
# first(saccades(edf), 5)   # peek at saccade events
# first(blinks(edf), 5)     # peek at blink events
# variables(edf)            # trial conditions (wide pivot)

# ── Build the wide DataFrame ──────────────────────────────────────────────── #
df = create_eyelink_edf_dataframe(edf)

plot_heatmap(df)
plot_heatmap(df, facet=:itemtype)
plot_databrowser(df)
plot_databrowser(df; split_by=nothing)


# Some plots
plot_gaze(df)
plot_gaze(df, facet=:itemtype)
plot_gaze(df, selection=(trial=100,))
plot_gaze(df, selection=(trial=1:10,))

plot_scanpath(df)
plot_scanpath(df, facet=:itemtype)
plot_scanpath(df, selection=(trial=1,))
plot_scanpath(df, selection=(trial=1:10,))

plot_heatmap(df)
plot_heatmap(df, facet=:itemtype)
plot_heatmap(df, selection=(trial=1,))
plot_heatmap(df, selection=(trial=2,))
plot_heatmap(df, selection=(trial=3,))
plot_heatmap(df, selection=(trial=4,))
plot_heatmap(df, selection=(trial=1:10,))

plot_heatmap(df; selection=(trial=1:10,), metric=:samples)     # raw sample counts
plot_heatmap(df; selection=(trial=1:10,), metric=:dwell)       # dwell time in ms
plot_heatmap(df; selection=(trial=1:10,), metric=:count)       # fixation count
plot_heatmap(df; selection=(trial=1:10,), metric=:proportion)  # normalized to 1.0

# Smoothing control
plot_heatmap(df; metric=:dwell, sigma=1.0)   # more smoothing
plot_heatmap(df; metric=:dwell, sigma=0)     # no smoothing

# ── Fixation plots ────────────────────────────────────────────────────────── #
plot_fixations(df)
plot_fixations(df; selection=(trial=1,))                  # single trial, numbered
plot_fixations(df; selection=(trial=1,), numbered=false)  # without numbers
plot_fixations(df; selection=(trial=1:5,))                # multiple trials

# ── Pupil size ────────────────────────────────────────────────────────────── #
plot_pupil(df)
plot_pupil(df; facet=:itemtype)
plot_pupil(df; selection=(trial=1,))          # single trial
plot_pupil(df; selection=(trial=1:3,))        # multiple trials, blink shading

# ── Saccade velocity ──────────────────────────────────────────────────────── #
plot_velocity(df)
plot_velocity(df; facet=:itemtype)
plot_velocity(df; selection=(trial=1,))       # single trial
plot_velocity(df; selection=(trial=1:10,))    # across trials

# ── Interactive eye data viewer ───────────────────────────────────────────── #
plot_databrowser(df)
plot_databrowser(df; split_by=[:trial])
plot_databrowser(df; split_by=nothing)
# plot_databrowser(df; split_by=nothing)




# ── AOI analysis ──────────────────────────────────────────────────────────── #
aoi_regions = [
    RectAOI("Center", 440, 280, 840, 680),
    RectAOI("Top-Left", 0, 0, 320, 240),
    CircleAOI("Fixation", 640, 480, 50),
]

plot_scanpath(df; selection=(trial=1,), aois=aoi_regions)
plot_fixations(df; selection=(trial=1,), aois=aoi_regions)
plot_heatmap(df; selection=(trial=1:10,), aois=aoi_regions)
plot_dwell(df, aoi_regions; selection=(trial=1,))
plot_dwell(df, aoi_regions; selection=(trial=1:10,))

# ── Faceted heatmap (by condition) ────────────────────────────────────────── #
plot_heatmap(df; facet=:type, metric=:dwell)

# ── New plot types ────────────────────────────────────────────────────────── #
plot_sequence(df; selection=(trial=1:10,))                    # event sequence chart
plot_transitions(df, aoi_regions; selection=(trial=1:10,))    # AOI transition heatmap
plot_comparison(df; compare_by=:type)                         # side-by-side heatmaps

# ── Coordinate utilities ──────────────────────────────────────────────────── #
ppd = pixels_per_degree(df)
println("Pixels per degree: ", ppd)
x_deg, y_deg = px_to_deg(df, 640, 480)
println("Center in degrees: ", (x_deg, y_deg))

# ── Trial exclusion ──────────────────────────────────────────────────────── #
# df_clean = copy(df)
# result = exclude_trials!(df_clean; max_tracking_loss=40, max_blink_count=5)

# ── Heatmap with background image (uncomment with real path) ──────────────── #
# plot_heatmap(df; selection=(trial=1,), background="/home/ian/Documents/Julia/oA_1.edf")

# ── Data quality ──────────────────────────────────────────────────────────── #
dq = data_quality(df)
println(first(dq, 10))
# Find trials with > 50% tracking loss
bad_trials = filter(r -> r.tracking_loss_pct > 50, dq)
println("Bad trials: ", nrow(bad_trials))

# ── Pupil preprocessing ──────────────────────────────────────────────────── #
df2 = copy(df)                        # work on a copy
interpolate_blinks!(df2)              # fill blink gaps
smooth_pupil!(df2; window_ms=50)      # moving-average smooth
baseline_correct_pupil!(df2)          # subtract baseline (-200 to 0 ms)
plot_pupil(df2; selection=(trial=1,)) # compare with raw

# ── Drift correction ─────────────────────────────────────────────────────── #
df3 = copy(df)
drift_correct!(df3; target=(640, 480))
plot_scanpath(df3; selection=(trial=1,))

# ── AOI metrics ───────────────────────────────────────────────────────────── #
am = aoi_metrics(df, aoi_regions; selection=(trial=1:10,))
println(first(am, 10))

# ── Group summary ─────────────────────────────────────────────────────────── #
gs = group_summary(df)
println(first(gs, 10))
gs_by_type = group_summary(df; by=:type)
println(first(gs_by_type, 10))

# ── Microsaccade detection ────────────────────────────────────────────────── #
df4 = copy(df)
detect_microsaccades!(df4)
n_msacc = count(df4.in_msacc)
println("Microsaccades detected: $n_msacc")

# ── Native event detection (I-VT / I-DT) ─────────────────────────────────── #

# Prefix mode: keep EyeLink events, add custom detection alongside
df_cmp = copy(df)
detect_events!(df_cmp; method=:ivt, velocity_threshold=30.0, prefix=:ivt)

# Compare EyeLink vs I-VT fixation counts
eyelink_n = counts(df_cmp.in_fix)
ivt_n = counts(df_cmp.ivt_in_fix)
println("EyeLink fixations: $eyelink_n, I-VT fixations: $ivt_n")

# Overwrite mode: replace EyeLink events with I-VT detection
# (all downstream plots now use the custom events)
df_ivt = copy(df)
detect_events!(df_ivt; method=:ivt, velocity_threshold=30.0)
plot_fixations(df_ivt; selection=(trial=1,))
plot_scanpath(df_ivt; selection=(trial=1,))
plot_databrowser(df_ivt; split_by=:trial)

# I-DT detection (dispersion-based — good for noisy/low-rate data)
df_idt = copy(df)
detect_events!(df_idt; method=:idt, dispersion_threshold=1.5)
plot_fixations(df_idt; selection=(trial=1,))

# Custom viewing geometry
df_custom = copy(df)
detect_events!(df_custom; method=:ivt,
    velocity_threshold=30.0,
    screen_res=(1920, 1080),
    viewing_distance_cm=60.0,
    screen_width_cm=53.0)

# ── Batch processing (uncomment with real paths) ──────────────────────────── #
# files = ["sub01.edf", "sub02.edf"]
# df_all = batch_read_eyelink(files; trial_time_zero="Stimulus On")
# gs_group = group_summary(df_all; by=[:participant, :type])

# ── Baseline correction methods ───────────────────────────────────────────── #
df5 = copy(df)
baseline_correct_pupil!(df5; method=:subtractive)   # default
plot_pupil(df5; selection=(trial=1,))

df6 = copy(df)
baseline_correct_pupil!(df6; method=:percent)        # % change from baseline
plot_pupil(df6; selection=(trial=1,))

df7 = copy(df)
baseline_correct_pupil!(df7; method=:zscore)         # z-scored
plot_pupil(df7; selection=(trial=1,))

# ── Cubic blink interpolation ─────────────────────────────────────────────── #
df8 = copy(df)
interpolate_blinks!(df8; method=:linear)             # default
plot_pupil(df8; selection=(trial=1,))

df9 = copy(df)
interpolate_blinks!(df9; method=:cubic)              # cubic Hermite spline
plot_pupil(df9; selection=(trial=1,))

# ── group_by support ──────────────────────────────────────────────────────── #
dq2 = data_quality(df; group_by=:trial)              # default
println(first(dq2, 5))
# dq3 = data_quality(df; group_by=[:block, :trial])  # multi-block (if :block exists)

# ── Interactive eye data viewer ───────────────────────────────────────────── #
plot_databrowser(df)
plot_databrowser(df; split_by=[:trial])
plot_databrowser(df; split_by=nothing)
# plot_databrowser(df; split_by=nothing)
