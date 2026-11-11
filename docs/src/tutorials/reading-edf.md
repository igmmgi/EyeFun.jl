# Reading EDF Files

EyeFun.jl reads binary EyeLink `.edf` recordings and exported `.asc` files directly in Julia without external C SDKs.

## High-Level Import (`read_et_data`)

`read_et_data` parses the file and returns an `EyeData` container with aligned sample, event, and trial columns:

```julia
using EyeFun

dat = read_et_data(
    "subject.edf";
    trial_time_zero = "STIM_ON",
    eye = :auto,
    include_variables = true,
)
```

Common options:

- `trial_time_zero`: message pattern (string or `Regex`) that anchors `time_rel = 0.0` within each trial.
- `eye`: `:auto`, `:left`, `:right`, or `:both`.
- `include_variables`: attaches `!V TRIAL_VAR` entries as per-trial columns on `dat.df`.

## Two-Step Import (`read_eyelink` + `create_eyefun_data`)

Use `read_eyelink` when you want to inspect raw EyeLink tables or calibration blocks before constructing `EyeData`:

```julia
edf = read_eyelink("subject.edf")   # also accepts "subject.asc"

cal = calibration_summary(edf)      # validation accuracy per calibration block
dat = create_eyefun_data(edf; trial_time_zero = "STIM_ON")
```

## Inspecting Messages and Trial Variables

```julia
# Unique message strings and counts across the recording
msg_summary = messages(dat; summary = true)

# Wide table of per-trial experimental variables (!V TRIAL_VAR)
vars = variables(dat)
```

## Exporting to EyeLink ASCII

`write_et_ascii` converts binary `.edf` files into `edf2asc`-compatible `.asc` text files:

```julia
write_et_ascii("subject.edf"; out_path = "subject.asc")
```
