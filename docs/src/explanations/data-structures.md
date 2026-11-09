# EyeTracking Data Structures

Overview of `EyeFun.jl`'s core types and how multiple dispatch connects raw file readers, continuous sample tables, and analysis functions.

## Julia Types & Multiple Dispatch

For details on Julia's type system, see the [Julia documentation](https://docs.julialang.org/en/v1/manual/types/). In `EyeFun.jl`, functions use **multiple dispatch** so a single function name dispatches to specialized methods based on argument types:

```julia
# Same function name, specialized methods for each file type
edf = read_eyelink("data.edf")
smi = read_smi("data.idf")
ed1 = create_eyefun_data(edf)
ed2 = create_eyefun_data(smi)
```

Use `typeof()` to inspect the concrete type of any value:

```julia
typeof(dat)   # e.g. EyeFun.EyeData
```

### Abstract vs Concrete Types

Julia distinguishes between **concrete** and **abstract** types:

- **Concrete types** hold data in memory (for example `EyeData`, `EDFFile`, or `RectAOI`).
- **Abstract types** group related concrete types for method dispatch without storing fields directly (for example `EyeFile`, the supertype of all format-specific file structs, and `AOI`, the supertype of spatial regions).

---

## Type Hierarchy

```
Any
├── EyeFile (abstract) - Raw file representations
│   ├── EDFFile
│   ├── SMIFile
│   └── TobiiFile
├── EyeData - Continuous sample table and recording metadata
└── AOI (abstract) - Spatial and spatiotemporal Areas of Interest
    ├── RectAOI
    ├── CircleAOI
    ├── EllipseAOI
    ├── PolygonAOI
    └── DynamicAOI
```

See the [Types Reference](../reference/types.md) for full field-by-field documentation of each type.

## `EyeFile` (Format Containers)

The `EyeFile` subtypes (`EDFFile`, `SMIFile`, `TobiiFile`) store format-specific tables and metadata parsed from raw files. `read_et_data` selects the appropriate reader from the file extension and converts the result into an `EyeData` container via `create_eyefun_data`.

## `EyeData`

`EyeData` wraps a wide `DataFrame` with one row per sample, aligning parsed discrete events and trial metadata with the continuous gaze and pupil time series.

| Field | Type | Description |
|-------|------|-------------|
| `df` | `DataFrame` | Continuous sample table (time × variables) |
| `source` | `Symbol` | Tracker source (`:eyelink`, `:smi`, `:tobii`, `:generic`) |
| `sample_rate` | `Float64` | Sampling frequency in Hz |
| `screen_res` | `Tuple{Int, Int}` | Display resolution `(width, height)` in pixels |
| `screen_width_cm` | `Float64` | Physical monitor width in cm |
| `viewing_distance_cm` | `Float64` | Distance from participant to screen in cm |

### Continuous DataFrame (`df`) columns

`df` stores gaze coordinates (`gxL`/`gyL`, `gxR`/`gyR`, and cyclopean `gx`/`gy` via `average_eyes!`), pupil sizes (`paL`/`paR`/`pa`), boolean event masks (`in_fix`, `in_sacc`, `in_blink`), and per-sample `message` strings at trigger timestamps.

## `AOI`

Areas of Interest define static or time-varying spatial regions on the display for gaze classification and dwell-time metrics.

| Concrete Type | Fields |
|---------------|--------|
| `RectAOI` | `name`, `cx`, `cy`, `width`, `height`, `color` |
| `CircleAOI` | `name`, `cx`, `cy`, `radius`, `color` |
| `EllipseAOI` | `name`, `cx`, `cy`, `rx`, `ry`, `color` |
| `PolygonAOI` | `name`, `vertices::Vector{Tuple{Float64, Float64}}`, `color` |
| `DynamicAOI` | `name`, `windows::Vector{Tuple{Float64, Float64, AOI}}`, `color` |

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
