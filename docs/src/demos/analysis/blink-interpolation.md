# Blink Interpolation

```julia
using EyeFun

dat = read_et_data("experiment.edf")

interpolate_blinks!(dat; padding_ms=50.0)
```
