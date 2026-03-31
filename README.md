# EyeFun.jl

A Julia package for Eye Tracking analysis and visualization.

## Features

- Parses data files directly using pure Julia
- Built-in support for **EyeLink** (`.edf`, `.asc`), **SMI** (`.idf`, `.txt`), and **Tobii** (`.tsv`)
- Parses fixations, saccades, blinks, messages, input events, and recording metadata
- Extracts continuous gaze/pupil samples at full recording resolution
- Outputs tidy `DataFrame`s ready for analysis
- `create_eyefun_data` — wide per-timestamp DataFrame combining continuous samples with event annotations
- Trial-based data organisation (start/end message markers)
- Monocular and binocular recordings

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/igmmgi/EyeFun.jl")
```

## Quick Start

```julia
using EyeFun

# Read data from your eye tracker 
et = read_eyelink("path/to/file.edf") # EyeLink (.edf or .asc)
# et = read_smi("path/to/file.idf")   # SMI (.idf or .txt)
# et = read_tobii("path/to/file.tsv") # Tobii Pro Lab (.tsv)

# Parsed event tables
fixations(et)   # DataFrame: sttime, entime, duration, gavx, gavy, ava, …
saccades(et)    # DataFrame: sttime, entime, duration, gstx, gsty, genx, geny, …
blinks(et)      # DataFrame: sttime, entime, duration
messages(et)    # DataFrame: time, message

# Continuous sample data
et.samples      # DataFrame: time, gxR, gyR, paR, gxL, gyL, paL, trial, time_rel, …

# Recording blocks (depending on hardware)
et.recordings   # DataFrame: time, sample_rate, eye, state, …
```

## create_eyefun_data

Combines sample data and event annotations into a single wide DataFrame — one row per millisecond:

```julia
df = create_eyefun_data(et)
# Columns include:
#  time, trial, participant, message
#  gxL, gyL, paL, gxR, gyR, paR                  (calibrated gaze & pupil)
#  pupxL, pupyL, pupxR, pupyR                    (raw camera pupil position)
#  in_fix, fix_gavx, fix_gavy, fix_dur...        (fixation annotations)
#  in_sacc, sacc_gstx, sacc_gsty, sacc_pvel...   (saccade annotations)
#  in_blink, blink_dur                           (blink annotations)
```

## Data Reference

### Fixations (`fixations(et)`)

| Column | Description |
|--------|-------------|
| `sttime` / `entime` | Start/end timestamp (ms) |
| `duration` | Duration in ms |
| `gavx` / `gavy` | Average gaze x/y |
| `ava` | Average pupil area |
| `eye` | 0=Left, 1=Right (EyeLink) |

### Saccades (`saccades(et)`)

| Column | Description |
|--------|-------------|
| `sttime` / `entime` | Start/end timestamp (ms) |
| `duration` | Duration in ms |
| `gstx` / `gsty` | Start gaze coordinates |
| `genx` / `geny` | End gaze coordinates |
| `pvel` | Peak velocity (°/s) |
| `eye` | 0=Left, 1=Right (EyeLink) |

### Samples (`et.samples`)

| Column | Description |
|--------|-------------|
| `time` | Timestamp (ms) |
| `gxR` / `gyR` | Right-eye gaze x/y (NaN if missing) |
| `paR` | Right pupil area |
| `gxL` / `gyL` | Left-eye gaze x/y (NaN if missing) |
| `paL` | Left pupil area/diameter |
| `trial` | Trial number |

## EyeLink ASC export

If you specifically use EyeLink, you can manually convert an EDF file to ASC format (equivalent to the `edf2asc` tool):

```julia
export_ascii("recording.edf")  # → recording.asc
```

## License

MIT.

## References

- [SR Research EyeLink](https://www.sr-research.com/)
- [EyeLink Developers Kit](https://www.sr-research.com/support/developer/)
