# Pupil Preprocessing

```julia
using EyeFun

dat = read_et_data("experiment.edf")

interpolate_blinks!(dat; padding_ms=50.0)
smooth_pupil!(dat; window_len=11)
baseline_correct_pupil!(dat; baseline_interval=(-200.0, 0.0), method=:subtractive)
```
