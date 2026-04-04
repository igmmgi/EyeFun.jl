# Saccade Analysis

```julia
using EyeFun

dat = read_et_data("experiment.edf")

sac_stats = saccade_metrics(dat)
```
