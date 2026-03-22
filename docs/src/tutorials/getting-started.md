# Getting Started

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/igmmgi/EyeFun.jl")
```

## Reading Your First EDF File

```julia
using EyeFun

# Read an EDF file — no external library needed
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
df = create_eyelink_edf_dataframe(edf; trial_time_zero="Stimulus On")
```

This creates an `EyeData` object with columns like `time`, `trial`, `time_rel`, `gxL`, `gyL`, `paL`, `in_fix`, `fix_gavx`, `in_sacc`, `sacc_ampl`, `in_blink`, `message`, etc.

## Plotting

```julia
# Gaze trace
plot_gaze(df; selection=(trial=1,))

# Scanpath with fixation circles
plot_scanpath(df; selection=(trial=1,))

# Fixation heatmap
plot_heatmap(df; selection=(trial=1,))

# Pupil trace
plot_pupil(df; selection=(trial=1,))
```

## Exporting to ASC

```julia
# Convert EDF to ASC format (equivalent to edf2asc)
write_eyelink_edf_to_asc("recording.edf", "recording.asc")
```

## Next Steps

- [Data Structures](../explanations/data-structures.md) — understand `EDFFile` and `EyeData`
- [Reading EDF Files](reading-edf.md) — detailed reader options
- [Event Analysis](event-analysis.md) — working with fixations, saccades, and blinks
- [API Reference](../reference/index.md) — complete function documentation
