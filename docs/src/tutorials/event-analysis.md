# Event Analysis

```julia
using EyeFun

dat = read_et_data("experiment.edf")

fix_stats = fixation_metrics(dat)
sac_stats = saccade_metrics(dat)
```
