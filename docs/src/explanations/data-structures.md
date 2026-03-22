# Data Structures

EyeFun.jl uses two main data structures:

## `EDFFile`

Returned by `read_eyelink_edf()`, holds all raw data from an EDF or ASC file:

| Field | Type | Description |
|-------|------|-------------|
| `preamble` | `String` | File header text |
| `events` | `DataFrame` | All parsed events (fixations, saccades, blinks, messages, input) |
| `samples` | `DataFrame` | Continuous gaze/pupil sample data |
| `recordings` | `DataFrame` | Recording block metadata (sample rate, eye, state) |

### Samples columns

| Column | Type | Description |
|--------|------|-------------|
| `time` | `UInt32` | Timestamp (ms) |
| `gxL` / `gxR` | `Float32` | Gaze X (left/right eye, NaN if missing) |
| `gyL` / `gyR` | `Float32` | Gaze Y |
| `paL` / `paR` | `Float32` | Pupil area |
| `trial` | `Int32` | Trial number |
| `time_rel` | `Int32` | ms since trial start |

## `EyeData`

Returned by `create_eyelink_edf_dataframe()`, wraps a wide DataFrame with one row per sample:

```julia
df = create_eyelink_edf_dataframe(edf; trial_time_zero="Stimulus On")
df.df  # access the underlying DataFrame
```

Includes all sample columns plus event annotations:

| Column | Description |
|--------|-------------|
| `in_fix` | `Bool` — currently in a fixation? |
| `fix_gavx` / `fix_gavy` | Average gaze during fixation |
| `fix_dur` | Fixation duration (ms) |
| `in_sacc` | `Bool` — currently in a saccade? |
| `sacc_ampl` / `sacc_pvel` | Saccade amplitude/peak velocity |
| `in_blink` | `Bool` — currently in a blink? |
| `message` | Message string at this timestamp |
