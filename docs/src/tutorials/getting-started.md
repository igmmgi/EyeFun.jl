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

# Read an EDF file 
edf = read_eyelink_edf("path/to/recording.edf")
```

The function auto-detects the file format (`.edf` binary or `.asc` text) and returns an `EDFFile` object containing:

- **`edf.samples`** — continuous gaze/pupil data at full recording resolution
- **`edf.events`** — all parsed events (fixations, saccades, blinks, messages)
- **`edf.recordings`** — recording block metadata (sample rate, eye, etc.)

## Accessing Events

```julia
# Parsed event DataFrames
fix = fixations(edf)   # sttime, entime, gavx, gavy, ava, …
sac = saccades(edf)    # sttime, entime, gstx, gsty, genx, geny, ampl, pvel, …
blk = blinks(edf)      # sttime, entime, duration
msg = messages(edf)    # sttime, message
```

## Creating an Analysis DataFrame

```julia
# Wide DataFrame with one row per sample, annotated with events
df = create_eyelink_edf_dataframe(edf)
# df = create_eyelink_edf_dataframe(edf; trial_time_zero="Stimulus On")
```

> [!TIP]
> **`trial_time_zero`:** Aligns the `time_rel` column so that $t=0$ ms occurs exactly when the given text (e.g., `"Stimulus On"`) appears in the trial's messages. This is crucial for stimulus-aligned analysis (like pupil responses or VWP).

This creates an `EyeData` object with columns like `time`, `trial`, `time_rel`, `gxL`, `gyL`, `paL`, `in_fix`, `fix_gavx`, `in_sacc`, `sacc_ampl`, `in_blink`, `message`, etc.

## Plotting

Plotting functions in EyeFun.jl operate on the whole dataset by default, allowing you to easily view aggregate behavior. To inspect specific subsets (like a single trial), pass a `NamedTuple` to the `selection` keyword:

```julia
# Launch the interactive data viewer for scrubbing through trials
plot_databrowser(df)                   # splits by trial as default
plot_databrowser(df; split_by=nothing) # Or view as one continuous stream

# Gaze trace (all trials aggregate)
plot_gaze(df)

# Scanpath with fixation circles (single trial)
plot_scanpath(df; selection=(trial=1,))

# Fixation heatmap (all trials aggregate)
plot_heatmap(df)

# Pupil trace (complex subset using an anonymous function)
plot_pupil(df; selection = r -> r.trial > 10 && r.message == "Stimulus On")
```

## Exporting to ASC

```julia
# Convert EDF to ASC format (equivalent to edf2asc)
write_eyelink_edf_to_ascii("recording.edf")  # → recording.asc
```

## EyeFun Philosophy

EyeFun.jl is designed with ease-of-use as a core principle, bringing high-performance EyeLink parsing directly to Julia without any external dependencies or painful C-library wrappers. It emphasizes a code-based workflow that is intended to be simple, fast, and intuitive.

While EyeFun provides interactive plotting components for data visualization and exploration, it remains fundamentally scriptable. The objective is to give you a single unified package capable of taking you from raw native binary `.edf` all the way to faceted statistical evaluation — all from the Julia REPL.

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
