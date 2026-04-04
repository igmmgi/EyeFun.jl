# Plot Gaze

```julia
using EyeFun
using CairoMakie

dat = read_et_data("experiment.edf")
fig = plot_gaze(dat; split_by=:trial)
```
