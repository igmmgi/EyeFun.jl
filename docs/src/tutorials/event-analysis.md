# Event Analysis

`EyeData` stores continuous sample-level boolean masks (`in_fix`, `in_sacc`, `in_blink`) alongside event properties (`fix_gavx`, `sacc_ampl`, `sacc_pvel`). Event accessors reconstruct discrete one-row-per-event tables from these columns.

## Extracting Discrete Event Tables

```julia
using EyeFun

dat = read_et_data("experiment.edf"; trial_time_zero = "STIM_ON")

fix = fixations(dat)   # sttime, entime, duration, gavx, gavy, ava
sac = saccades(dat)    # sttime, entime, duration, gstx, gsty, genx, geny, ampl, pvel
blk = blinks(dat)      # sttime, entime, duration
```

Pass `include_groups = true` to retain grouping columns (such as `trial`, `participant`, or experimental condition) on each event row, or filter first with `selection`:

```julia
fix_by_trial = fixations(dat; include_groups = true)
fix_trial_1  = fixations(dat; selection = (trial = 1,))
```

## Trial and Condition Summaries

`fixation_metrics`, `saccade_metrics`, and `group_summary` aggregate event statistics per trial (default `group_by = :auto`) or across custom grouping columns:

```julia
# Per-trial fixation and saccade summaries
fix_stats = fixation_metrics(dat)
sac_stats = saccade_metrics(dat)

# Combined overview (fixations, saccades, blinks, mean pupil, tracking loss)
overview = group_summary(dat)

# Aggregate by experimental condition within a post-stimulus window (0 to 1000 ms)
cond_fix = fixation_metrics(
    dat;
    group_by = [:trial, :condition],
    time_window = (0.0, 1000.0),
)
```
