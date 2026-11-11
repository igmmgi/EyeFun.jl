# AOI Analysis

Areas of Interest (`AOI`) classify gaze samples and fixations into spatial or spatiotemporal screen regions. Coordinates match the coordinate system of `dat` (`dat.coords`, typically screen pixels `:px`).

## Defining Static and Dynamic AOIs

```julia
using EyeFun

dat = read_et_data("data.edf"; trial_time_zero = "STIM_ON")

# Rectangular and circular AOIs (centered at cx, cy)
face_aoi   = RectAOI("Face", 400, 384, 220, 260)
button_aoi = CircleAOI("Button", 820, 620, 60)

# Arbitrary polygon from (x, y) vertices
frame_aoi  = PolygonAOI("Panel", [(100, 100), (300, 100), (300, 500), (100, 500)])

# Time-varying AOI defined by (t_start_ms, t_end_ms, aoi) windows in trial-relative time
moving_target = DynamicAOI("Target", [
    (0.0, 500.0, RectAOI("early", 300, 384, 140, 140)),
    (500.0, 1000.0, RectAOI("late", 724, 384, 140, 140)),
])
```

Test individual coordinates directly with `in_aoi(face_aoi, x, y)` or `in_aoi(moving_target, x, y, t_ms)`.

## Dwell Metrics, Time Courses, and Transitions

```julia
aois = AOI[face_aoi, button_aoi]

# Dwell time, fixation count, time to first fixation, and revisit count per group and AOI
metrics = aoi_metrics(dat, aois; time_window = (0.0, 2000.0))

# Binned fixation/gaze proportions over time (visual-world time course)
looks = proportion_of_looks(dat, aois; bin_ms = 50, time_window = (-200.0, 1500.0))

# AOI-to-AOI transition counts or row-normalized probabilities
trans = transition_matrix(dat, aois; normalize = true)
```
