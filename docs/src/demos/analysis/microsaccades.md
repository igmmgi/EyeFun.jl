# Microsaccades

```julia
using EyeFun

dat = read_et_data("experiment.edf")

detect_microsaccades!(dat; lambda=6.0, mindur_ms=6.0)
```
