# Batch Processing

Passing a directory path to `read_et_data` imports all matching recordings in that folder, concatenates them into a single `EyeData` container, and populates a `participant` column from each file's stem.

## Importing a Dataset Directory

```julia
using EyeFun

dat = read_et_data(
    "dataset/";
    ext = ".edf",
    trial_time_zero = "STIM_ON",
)
```

When `dat.df` contains both `participant` and `trial`, analysis functions with `group_by = :auto` automatically group by `[:participant, :trial]` so trial numbers never collide across participants.

## Quality Control and Trial Exclusion

Inspect per-trial tracking loss, blink rate, and spatial precision with `data_quality`, then drop trials failing quality criteria with `exclude_trials!`:

```julia
dq = data_quality(dat)

summary = exclude_trials!(
    dat;
    max_tracking_loss = 30.0,
    max_blink_count = 5,
    min_duration_ms = 500,
)
# summary.n_before, summary.n_excluded, summary.n_after, summary.excluded
```

## Multi-Participant Aggregation

Preprocess and compute metrics across the full dataset in one pass:

```julia
interpolate_blinks!(dat; margin_ms = 50)
smooth_pupil!(dat; window_ms = 50)
baseline_correct_pupil!(dat; window = (-200.0, 0.0))

trial_peaks = pupil_peak_metrics(dat; time_window = (200.0, 1500.0))
subj_fix    = fixation_metrics(dat; group_by = [:participant, :condition])
```

To save the cleaned dataset for fast reload without re-parsing raw vendor files, use `write_et_delimited(dat, "cleaned_dataset.tsv")` and reload with `read_et_delimited("cleaned_dataset.tsv")`.
