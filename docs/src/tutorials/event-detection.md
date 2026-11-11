# Event Detection

Tracker exports from Tobii, SMI, or generic CSV/TSV files may lack online event annotations, or you may want uniform event criteria across devices. `detect_events!` runs velocity-threshold (`:ivt`) or dispersion-threshold (`:idt`) classification using physical display geometry (`screen_res`, `screen_width_cm`, `viewing_distance_cm`).

## Velocity-Threshold Detection (I-VT)

`method = :ivt` classifies samples from 5-point central-difference angular velocity (°/s). Pass a fixed threshold (default `30.0` °/s) or `:adaptive` for iterative noise-adaptive thresholding (Nyström & Holmqvist, 2010):

```julia
using EyeFun

dat = read_et_data("data.edf")

# Fixed 30 °/s velocity threshold
detect_events!(dat; method = :ivt, velocity_threshold = 30.0)

# Adaptive threshold with saccade onset/offset refinement and post-saccadic oscillation (PSO) tagging
detect_events!(
    dat;
    method = :ivt,
    velocity_threshold = :adaptive,
    refine_saccades = true,
    detect_pso = true,
)
```

## Dispersion-Threshold Detection (I-DT) and Non-Destructive Prefixes

Pass `prefix` to store detected columns alongside existing hardware events instead of overwriting `in_fix` and `in_sacc`:

```julia
detect_events!(
    dat;
    method = :idt,
    dispersion_threshold = 1.0,
    min_fixation_ms = 100,
    prefix = :idt,
)

hw_fix  = fixations(dat)                 # hardware events (in_fix, fix_dur, ...)
idt_fix = fixations(dat; prefix = :idt)  # I-DT events (idt_in_fix, idt_fix_dur, ...)
```

## Microsaccade Detection

`detect_microsaccades!` implements the Engbert & Kliegl (2003) 2D velocity-ellipse detector and populates `in_msacc`, `msacc_dx`, `msacc_dy`, `msacc_ampl`, and `msacc_pvel`:

```julia
detect_microsaccades!(dat; lambda = 6.0, min_duration_ms = 6, max_amplitude = 1.5)
ms = microsaccades(dat; include_groups = true)
```
