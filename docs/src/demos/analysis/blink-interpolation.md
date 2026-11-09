# Blink Interpolation

```julia
using EyeFun

dat = read_et_data("experiment.edf")

interpolate_blinks!(dat; margin_ms=50)
```
