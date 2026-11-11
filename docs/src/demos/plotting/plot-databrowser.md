# Data Browser

```julia
using EyeFun
using GLMakie

dat = read_et_data("experiment.edf")
fig, state = plot_databrowser(dat; split_by=:trial)
```
