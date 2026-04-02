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

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/igmmgi/EyeFun.jl")
```

## Quick Start

```julia
using EyeFun

# Read data from your eye tracker 
dat = read_et_data("path/to/yout/eye_tracking_file/file.edf") # EyeLink (.edf or .asc)

# interactive databrowser
plot_databrowser(dat) # whole dataset
plot_databrowser(dat) # split by some unique identifier within dataset, here trial

https://github.com/user-attachments/assets/ea4537e4-b5e4-418b-b689-6ffc854998db


