# EyeTracking Data Structures

Understanding `EyeFun.jl`'s core data structures and how they leverage Julia's type system.

## Julia Types & Multiple Dispatch

If you're coming from Python or MATLAB, Julia's type system works a little differently. The full details are in the [Julia documentation](https://docs.julialang.org/en/v1/manual/types/), but the key idea for everyday `EyeFun.jl` use is **multiple dispatch**.

This means a function can have the same name but do different things depending on the *type* of data passed to it:

```julia
# Same function, different file formats → different internal parsing behaviour
read_et_data(EDFFile, "data.edf")
read_et_data(SMIFile, "data.idf")
```

If you are ever unsure what type a variable is, use `typeof()`:

```julia
typeof(dat)   # e.g. EyeFun.EyeData
```

### Abstract vs Concrete Types

Julia distinguishes between **concrete** and **abstract** types:

- **Concrete types** are the actual data structures you create and work with — for example `EyeData`, `EDFFile`, or `RectAOI`. These hold real data.
- **Abstract types** are categories or groupings — you can never create one directly, but they let functions accept a *family* of related types. For example, `EyeFile` is abstract; it simply stands for "any supported eye-tracking file format".

---

## Type Hierarchy

```
Any
├── EyeFile (abstract) - Representation of raw files
│   ├── EDFFile
│   ├── SMIFile
│   └── TobiiFile
├── EyeData - Processed and unified continuous data
└── AOI (abstract) - Spatial Areas of Interest
    ├── RectAOI
    ├── CircleAOI
    ├── EllipseAOI
    └── PolygonAOI
```

See the [Types Reference](../reference/types.md) for full field-by-field documentation of each type.

## `EyeFile` (Format Specs)

The `EyeFile` types (`EDFFile`, `SMIFile`, `TobiiFile`) are structural types used during parsing. `read_et_data` automatically dispatches on the file extension to read the raw proprietary components utilizing these types before automatically packaging everything into the singular `EyeData` object.

## `EyeData`

The central data structure you will work with. `EyeData` wraps a wide `DataFrame` with one row per sample, interpolating parsed discrete events across the continuous time series.

| Field | Type | Description |
|-------|------|-------------|
| `df` | `DataFrame` | The continuous data (time × variables) |
| `source` | `String` | Source filename |
| `sample_rate` | `Float64` | Sampling frequency in Hz |
| `screen_res` | `Tuple{Float64, Float64}` | Display resolution (width, height) |
| `screen_width_cm` | `Float64` | Physical monitor width |
| `viewing_distance_cm` | `Float64` | Distance from participant to screen |

### Continuous DataFrame (`df`) columns

The underlying `df` contains continuous gaze coordinates (`gx`, `gy`), pupil sizes (`pa`), and binary state masks annotating whether the sample occurred during a specific event category (`in_fix`, `in_sacc`, `in_blink`). It also contains dynamic string annotations like `message` when system triggers appear on the timeline.

## `AOI`

Areas of Interest define spatial boundaries on the stimulus screen to extract semantic gaze metrics.

| Concrete Type | Primitive Fields | 
|---------------|------------------|
| `RectAOI` | `x`, `y`, `width`, `height` |
| `CircleAOI` | `x`, `y`, `radius` |
| `EllipseAOI` | `x`, `y`, `radius_x`, `radius_y` |
| `PolygonAOI` | `points::Vector{Tuple{Float64, Float64}}` |

## Data Flow

```
Raw Eye-Tracking File (.edf, .idf, .tsv)
    ↓ read_et_data()
EyeData
    ↓ (pupil processing, drift correction, event detection...)
EyeData (cleaned)
    ↓ fixation_metrics() / aoi_metrics() / group_summary()
DataFrame (Aggregated Statistics)
```
