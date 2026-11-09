# Plot Dwell

```julia
using EyeFun
using CairoMakie

dat = read_et_data("experiment.edf")
aois = [RectAOI("Left", 320, 480, 300, 300), RectAOI("Right", 960, 480, 300, 300)]
fig = plot_dwell(dat, aois)
```
