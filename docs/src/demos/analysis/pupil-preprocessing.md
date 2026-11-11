# Pupil Preprocessing

```julia
using EyeFun

dat = read_et_data("experiment.edf"; trial_time_zero = "STIM_ON")

interpolate_blinks!(dat; margin_ms = 50)
smooth_pupil!(dat; window_ms = 50)
baseline_correct_pupil!(dat; window = (-200.0, 0.0), method = :subtractive)
```
