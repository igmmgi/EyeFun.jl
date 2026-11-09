# Why Julia for Eye-Tracking?

## Performance

Julia's just-in-time (JIT) compilation allows pure-Julia binary readers (such as EyeFun.jl's `.edf` and `.idf` parsers) and sample-level signal processing loops to run at native speed without external C/C++ wrapper libraries.

## Reproducibility

Julia's built-in package manager records exact dependency versions in `Project.toml` and `Manifest.toml`, making analysis environments reproducible across machines.

## DataFrames Integration

EyeFun.jl stores continuous samples and extracted events as standard `DataFrames.jl` tables, so filtering, grouping, joining, and statistical modeling use standard Julia tabular workflows.

## Interactive and Static Plots

`Makie.jl` supports both interactive data exploration (such as `plot_databrowser`) and publication-ready static figures including gaze traces, scanpaths, fixation heatmaps, and pupil time courses.
