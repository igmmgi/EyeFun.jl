# Event Analysis

```julia
using EyeFun

dat = read_et_data("experiment.edf")

fix = fixations(dat)
sac = saccades(dat)
sac_stats = saccade_metrics(dat)
```
