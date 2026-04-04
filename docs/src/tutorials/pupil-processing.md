# Pupil Processing

```julia
using EyeFun

dat = read_et_data("data.edf")

interpolate_blinks!(dat)
smooth_pupil!(dat)
baseline_correct_pupil!(dat; baseline_interval=(-200.0, 0.0))
```
