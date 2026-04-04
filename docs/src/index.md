````@raw html
---
layout: home
hero:
  name: EyeFun.jl
  text: Eye-tracking analysis in Julia
  image:
    src: /EyeFunLogo.png
  actions:
    - theme: alt
      text: Get Started
      link: /tutorials/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/igmmgi/EyeFun.jl

features:
  - icon: 
      src: /icon_eye.png
    title: Data Readers
    details: Read EyeLink (EDF, ASC), SMI, and Tobii eye-tracking data formats
  - icon: 
      src: /icon_df.png
    title: Tidy DataFrames
    details: Fixations, saccades, blinks, messages, and continuous samples as DataFrames
  - icon: 
      src: /icon_analysis.png
    title: Analysis Tools
    details: Data quality, AOI metrics, pupil processing, drift correction, event detection
  - icon: 
      src: /icon_visualisation.png
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

# Read an eye-tracking data file (format auto-detected)
dat = read_et_data("path/to/file.edf")

# Interactive databrowser
plot_databrowser(dat)
plot_databrowser(dat; split_by=:trial)

# Plot types
plot_gaze(dat; selection=(trial=1,))
plot_scanpath(dat; selection=(trial=1,))
plot_heatmap(dat; selection=(trial=1,))
plot_fixations(dat; selection=(trial=1,))
plot_pupil(dat; split_by=:trial)
plot_velocity(dat; selection=(trial=1,))

plot_dwell(dat)
plot_sequence(dat)
plot_transitions(dat)

# Access event tables directly from the processed dataset
fix = fixation_metrics(dat)
sac = saccade_metrics(dat)

# Data quality analysis
dq = data_quality(dat)

# Export to ASC format
write_et_ascii("recording.edf")  # → recording.asc
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
