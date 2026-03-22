# EyeFun.jl

A Julia package for Eye Tracking analysis and visualization. 

## Features

- **Pure Julia binary reader** — no SR Research EDF Access API needed
- Parses fixations, saccades, blinks, messages, input events, and recording metadata
- Extracts continuous gaze/pupil samples at full recording resolution
- Outputs tidy `DataFrame`s ready for analysis
- `create_eyelink_edf_dataframe` — wide per-timestamp DataFrame with event annotations
- Trial-based data organisation (start/end message markers)
- Monocular and binocular recordings
- Also reads `.asc` files produced by `edf2asc`

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/igmmgi/EyeFun.jl")
```

## Quick Start

```julia
using EyeFun

# Read an EDF file (no external library needed)
edf = read_eyelink_edf("path/to/file.edf")

# Or use the specific readers directly
edf = read_eyelink_edf_binary("path/to/file.edf")
edf = read_eyelink_edf_asc("path/to/file.asc")

# Parsed event tables
edf.fixations    # DataFrame: sttime, entime, duration, gavx, gavy, ava, …
edf.saccades     # DataFrame: sttime, entime, duration, gstx, gsty, genx, geny, …
edf.blinks       # DataFrame: sttime, entime, duration
edf.messages     # DataFrame: time, message

# Continuous sample data
edf.samples      # DataFrame: time, gxR, gyR, paR, gxL, gyL, paL, trial, time_rel, …

# Recording blocks
edf.recordings   # DataFrame: time, sample_rate, eye, state, …
```

## ASC export

Convert an EDF file to ASC format (equivalent to `edf2asc`):

```julia
write_eyelink_edf_to_asc("recording.edf", "recording.asc")
```

## create_eyelink_edf_dataframe

Combines sample data and event annotations into a single wide DataFrame — one row per millisecond:

```julia
df = create_eyelink_edf_dataframe(edf)
# Columns: time, trial, time_rel,
#          gxR, gyR, paR, gxL, gyL, paL,
#          in_fix, fix_gavx, fix_gavy, fix_ava, fix_dur,
#          in_sacc, sacc_gstx, sacc_gsty, sacc_genx, sacc_geny, sacc_dur,
#          in_blink
```

## Data Reference

### Fixations (`edf.fixations`)

| Column | Description |
|--------|-------------|
| `sttime` / `entime` | Start/end timestamp (ms) |
| `duration` | Duration in ms |
| `gavx` / `gavy` | Average gaze x/y |
| `ava` | Average pupil area |
| `eye` | 0=left, 1=right |
| `sttime_rel` / `entime_rel` | Trial-relative times |

### Saccades (`edf.saccades`)

| Column | Description |
|--------|-------------|
| `sttime` / `entime` | Start/end timestamp (ms) |
| `duration` | Duration in ms |
| `gstx` / `gsty` | Start gaze coordinates |
| `genx` / `geny` | End gaze coordinates |
| `pvel` | Peak velocity (°/s) |

### Samples (`edf.samples`)

| Column | Description |
|--------|-------------|
| `time` | Timestamp (ms) |
| `gxR` / `gyR` | Right-eye gaze x/y (NaN if missing) |
| `paR` | Right pupil area |
| `gxL` / `gyL` | Left-eye gaze x/y (NaN if missing) |
| `paL` | Left pupil area |
| `trial` | Trial number |
| `time_rel` | ms since trial start |

## Accuracy vs edf2asc

The binary reader has been validated (non exhaustively) against SR Research's `edf2asc` tool:

| | oA_1 binary | oA_1 asc | Δ |
|--|--|--|--|
| Fixations | 4357 | 4357 | **0** |
| Saccades | 3569 | 3567 | +2 |
| Blinks | 111 | 107 | +4 |
| Samples | 2,174,180 | ~2,174,198 | −18 |

values (gaze coordinates, pupil area, duration) seem to match edf2asc for all verified events.

## License

MIT.

## References

- [SR Research EyeLink](https://www.sr-research.com/)
- [EyeLink Developers Kit](https://www.sr-research.com/support/developer/)
