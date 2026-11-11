# Event Detection (I-VT / I-DT)

```julia
using EyeFun

dat = read_et_data("data.edf")

# Velocity-threshold detection (fixed or Nyström & Holmqvist adaptive threshold)
detect_events!(dat; method = :ivt, velocity_threshold = :adaptive)

# Dispersion-threshold detection into non-destructive `:idt_*` columns
detect_events!(dat; method = :idt, dispersion_threshold = 1.0, prefix = :idt)
```
