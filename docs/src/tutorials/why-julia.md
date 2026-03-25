# Why Julia for Eye-Tracking?

Julia offers unique advantages for eye-tracking research:

## Speed Without Sacrifice

Julia's just-in-time (JIT) compilation means EyeFun.jl's pure-Julia EDF binary reader is fast enough to replace C-based tools like `edf2asc`, while remaining easy to read, modify, and extend.

## Reproducibility

Julia's package manager ensures exact reproducibility of analysis environments. Every dependency version is locked in `Manifest.toml`.

## DataFrames Integration

EyeFun.jl outputs standard `DataFrames.jl` tables, which integrate naturally with the entire Julia data science ecosystem — filtering, grouping, joining, and statistical analysis all use the same tools.

## Publication-Quality Plots

`Makie.jl` provides interactive, customisable, publication-quality figures including gaze plots, heatmaps, scanpaths, and topographic maps.
