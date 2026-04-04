# Plot Heatmap

```julia
using EyeFun
using CairoMakie

dat = read_et_data("experiment.edf")
fig = plot_heatmap(dat; bins=100, blur_radius=5.0)
```
