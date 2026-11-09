# Microsaccades

```julia
using EyeFun

dat = read_et_data("experiment.edf")

detect_microsaccades!(dat; lambda=6.0, min_duration_ms=6)
```
