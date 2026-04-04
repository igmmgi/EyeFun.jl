# Plot Scanpath

```julia
using EyeFun
using CairoMakie

dat = read_et_data("experiment.edf")
fig = plot_scanpath(dat; selection=(trial=3,))
```
