# Data Quality

```julia
using EyeFun

dat = read_et_data("experiment.edf")

dq = data_quality(dat)
exclude_trials!(dat; max_tracking_loss=15.0)
```
