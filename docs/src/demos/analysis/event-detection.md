# Event Detection

```julia
using EyeFun

dat = read_et_data("data.edf")

detect_events!(dat; velocity_threshold=30.0)
```
