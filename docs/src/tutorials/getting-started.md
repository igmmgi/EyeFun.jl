# Getting Started

## Installing Julia

EyeFun.jl requires [Julia](https://julialang.org/) 1.10 or later.

The recommended way to install and manage Julia versions is with **[juliaup](https://github.com/JuliaLang/juliaup)**.
Alternatively, download an installer directly from the [Julia Downloads page](https://julialang.org/downloads/).

## The Julia REPL

Julia is an interactive language built around a Read-Eval-Print Loop (REPL). The REPL provides different modes accessed by special keys:

| Key | Mode | Purpose |
| --- | --- | --- |
| (default) | Julia mode | Execute Julia code |
| `]` | Package mode | Install and manage packages |
| `?` | Help mode | Access inline documentation |
| `;` | Shell mode | Run shell commands |

Press `Backspace` to return to Julia mode from any other mode.

## IDE Workflows

Most users pair the REPL with an editor that adds syntax highlighting and lets you send code directly into the live Julia REPL session. Popular choices include VS Code (with the Julia extension), Positron, or JetBrains IDEs. See [**IDE Workflows**](ide-workflows.md) for detailed setup instructions.

## Installation

Installing EyeFun.jl is done through the standard Julia package manager. From the Julia REPL, enter Pkg mode by pressing `]` and run:

```julia
add https://github.com/igmmgi/EyeFun.jl
```

Or using `Pkg` in the code:

```julia
using Pkg
Pkg.add(url="https://github.com/igmmgi/EyeFun.jl")
```

## Reading Your First EDF File

```julia
using EyeFun

# Read directly into an EyeData object (auto-detects .edf, .asc, .idf, .txt, .tsv, .csv)
df = read_et_data("path/to/recording.edf"; trial_time_zero="Stimulus On")

# Or inspect the low-level EyeLink file container first:
edf = read_eyelink("path/to/recording.edf")
df = create_eyefun_data(edf; trial_time_zero="Stimulus On")
```

`read_eyelink` auto-detects `.edf` binary or `.asc` text files and returns an `EDFFile` containing:

- **`edf.samples`**: continuous gaze and pupil samples at full recording resolution
- **`edf.events`**: parsed events (fixations, saccades, blinks, messages)
- **`edf.recordings`**: recording block metadata (sample rate, tracked eye, filter mode)

> [!TIP]
> **`trial_time_zero`:** Aligns the `time_rel` column so that $t=0$ ms occurs when the given pattern (e.g., `"Stimulus On"`) appears in a trial's messages, such as stimulus onset in pupillometry or visual-world paradigms.

`read_et_data` / `create_eyefun_data` returns an `EyeData` object with columns like `time`, `trial`, `time_rel`, `gxL`, `gyL`, `paL`, `in_fix`, `fix_gavx`, `in_sacc`, `sacc_ampl`, `in_blink`, `message`, etc.

## Accessing Events

```julia
# Extract discrete event DataFrames from EyeData
fix = fixations(df)   # sttime, entime, duration, gavx, gavy, ava
sac = saccades(df)    # sttime, entime, duration, gstx, gsty, genx, geny, ampl, pvel
blk = blinks(df)      # sttime, entime, duration
msg = messages(df)    # time, message
```

## Plotting

Plotting functions operate on the full dataset by default. To plot a subset (such as a single trial or trial range), pass a `NamedTuple` to the `selection` keyword:

```julia
# Launch the interactive data viewer
plot_databrowser(df)                  # view as one continuous stream
plot_databrowser(df; split_by=:trial) # scrub trial-by-trial

# Gaze trace (all trials aggregate)
plot_gaze(df)

# Scanpath with fixation circles (single trial)
plot_scanpath(df; selection=(trial=1,))

# Fixation heatmap (all trials aggregate)
plot_heatmap(df)

# Pupil trace for trials 1 through 10
plot_pupil(df; selection=(trial=1:10,))
```

## Exporting to ASC

```julia
# Convert EDF to ASC format (equivalent to edf2asc)
write_et_ascii("recording.edf")  # → recording_exported.asc
```

## Next Steps and Resources

| Resource | Link |
| --- | --- |
| Julia Basics | [julia-basics.md](julia-basics.md) |
| Data Structures | [explanations/data-structures.md](../explanations/data-structures.md) |
| Reading EDF Files | [reading-edf.md](reading-edf.md) |
| Event Analysis | [event-analysis.md](event-analysis.md) |
| Complete API | [API Reference](../reference/index.md) |
| EyeFun.jl GitHub | [github.com/igmmgi/EyeFun.jl](https://github.com/igmmgi/EyeFun.jl) |
| Julia learning resources | [julialang.org/learning](https://julialang.org/learning/) |
| Julia cheat sheet | [cheatsheet.juliadocs.org](https://cheatsheet.juliadocs.org/) |
| Makie.jl (plotting) | [docs.makie.org](https://docs.makie.org/) |
| DataFrames.jl | [dataframes.juliadata.org](https://dataframes.juliadata.org/) |
