# Data Browser

```julia
using EyeFun
using CairoMakie

dat = read_et_data("experiment.edf")
fig = plot_databrowser(dat; split_by=:trial)
```
