# Plot Heatmap

```julia
using EyeFun
using CairoMakie

dat = read_et_data("experiment.edf")
fig = plot_heatmap(dat; bins=(100, 100), sigma=2.0)
```
