# Plot Velocity

```julia
using EyeFun
using CairoMakie

dat = read_et_data("experiment.edf")
fig = plot_velocity(dat)
```
