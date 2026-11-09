# Fixation Analysis

```julia
using EyeFun

dat = read_et_data("experiment.edf")

aois = [RectAOI("Target", 640, 480, 300, 300)]
fix_stats = fixation_metrics(dat, aois)
```
