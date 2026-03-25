````@raw html
---
layout: home
hero:
  name: EyeFun.jl
  text: Eye-tracking analysis in Julia
  actions:
    - theme: alt
      text: Get Started
      link: /tutorials/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/igmmgi/EyeFun.jl

features:
  - icon: 👁️
    title: Pure Julia EDF Reader
    details: Read EyeLink EDF files directly — no SR Research SDK needed
  - icon: 📊
    title: Tidy DataFrames
    details: Fixations, saccades, blinks, messages, and continuous samples as DataFrames
  - icon: 🔬
    title: Analysis Tools
    details: Data quality, AOI metrics, pupil processing, drift correction, event detection
  - icon: 📈
    title: Visualisation
    details: Gaze plots, scanpaths, heatmaps, fixation maps, and pupil traces with Makie.jl
---
````

## Quick Start

Install EyeFun.jl from the Julia REPL:

```julia
using Pkg
Pkg.add(url="https://github.com/igmmgi/EyeFun.jl")
```

Read and analyse eye-tracking data:

```julia
using EyeFun

# Read an EDF file (no external library needed)
edf = read_eyelink_edf("path/to/file.edf")

# Access event tables
fix = fixations(edf)   # DataFrame: sttime, entime, gavx, gavy, ava, …
sac = saccades(edf)    # DataFrame: sttime, entime, gstx, gsty, genx, geny, …
blk = blinks(edf)      # DataFrame: sttime, entime, duration

# Create a wide per-sample DataFrame with event annotations
df = create_eyelink_edf_dataframe(edf)

# Plot gaze data
plot_gaze(df; selection=(trial=1,))
plot_scanpath(df; selection=(trial=1,))
plot_heatmap(df; selection=(trial=1,))

# Data quality analysis
dq = data_quality(df)

# Export to ASC format
write_eyelink_edf_to_ascii("recording.edf")  # → recording.asc
```

## Documentation

:::tip Learn EyeFun.jl
[Getting Started Tutorial](tutorials/getting-started.md)
:::

| Section | Description |
|---------|-------------|
| [Tutorials](tutorials/getting-started.md) | Step-by-step guides |
| [How-to Guides](demos/io/read-edf-binary.md) | Code examples and demonstrations |
| [API Reference](reference/index.md) | Complete function and type documentation |

## Getting Help

- Report bugs on [GitHub Issues](https://github.com/igmmgi/EyeFun.jl/issues)
