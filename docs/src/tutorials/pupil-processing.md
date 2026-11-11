# Pupil Processing

Pupillometry preprocessing typically proceeds within trial segments: artifact rejection, blink interpolation, optional geometric foreshortening correction, temporal smoothing, and baseline normalization.

## Epoch Alignment

Anchor `time_rel` to the trial event of interest at import time or afterward with `set_time_zero!`:

```julia
using EyeFun

dat = read_et_data("experiment.edf"; trial_time_zero = "STIM_ON")

# Re-anchor later if needed (accepts a message string, Regex, or column Symbol)
set_time_zero!(dat, "STIM_ON")
```

## Artifact Filtering, Blink Interpolation, and Smoothing

All mutating pupil functions operate within `(participant, trial)` boundaries so samples never bleed across trial seams:

```julia
# Reject dilation-speed outliers and pad blink/dropout edges (Kret & Sjak-Shie, 2019)
pupil_filter!(dat; mad_multiplier = 16.0, margin_ms = 50)

# Interpolate across marked blinks (:linear or :cubic Hermite)
interpolate_blinks!(dat; margin_ms = 50, method = :cubic)

# Optional geometric pupil foreshortening correction when physical geometry is known
correct_pupil_foreshortening!(dat; measure = :auto)

# Smooth valid segments (:moving_average or :savgol)
smooth_pupil!(dat; window_ms = 50, method = :moving_average)
```

## Baseline Correction and Summary Metrics

Subtract or normalize against a pre-stimulus baseline window (`:subtractive`, `:percent`, or `:zscore`), then extract peak metrics or binned time courses:

```julia
baseline_correct_pupil!(dat; window = (-200.0, 0.0), method = :subtractive)

# Peak dilation and latency between 200 and 1500 ms post-stimulus
peaks = pupil_peak_metrics(dat; time_window = (200.0, 1500.0))

# Mean pupil response in 50 ms bins from -200 to 1500 ms
binned = time_bin(dat; bin_ms = 50, measure = :pupil, time_window = (-200.0, 1500.0))
```
