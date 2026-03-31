# ── Native Event Detection ─────────────────────────────────────────────────── #
#
# Tracker-agnostic fixation/saccade detection using I-VT (velocity threshold)
# and I-DT (dispersion threshold) algorithms. Writes to the same column schema
# as the EyeLink parser so all downstream plots and analysis work automatically.

# ── Velocity computation ───────────────────────────────────────────────────── #

"""
    _compute_velocity_deg(gx, gy, ppd, sample_rate) -> Vector{Float64}

Compute gaze velocity in °/s using 5-point central difference.
Returns NaN for invalid samples and boundary samples.
"""
function _compute_velocity_deg(
    gx::Vector{Float64},
    gy::Vector{Float64},
    ppd::Float64,
    sample_rate::Float64,
)
    n = length(gx)
    vel = fill(NaN, n)
    n < 5 && return vel
    dt = 1.0 / sample_rate  # time between samples in seconds

    for i = 3:(n-2)
        # Skip if any of the 5 samples are NaN
        any(isnan, (gx[i-2], gx[i-1], gx[i+1], gx[i+2])) && continue
        any(isnan, (gy[i-2], gy[i-1], gy[i+1], gy[i+2])) && continue

        # 5-point central difference (Engbert & Kliegl, 2003)
        dx = (gx[i+2] + gx[i+1] - gx[i-1] - gx[i-2]) / 6.0
        dy = (gy[i+2] + gy[i+1] - gy[i-1] - gy[i-2]) / 6.0

        # Convert from px/sample to °/s
        vel[i] = sqrt(dx^2 + dy^2) / ppd / dt
    end
    return vel
end

# ── I-VT Algorithm ─────────────────────────────────────────────────────────── #

"""
Classify samples using I-VT (velocity threshold identification).
Returns a per-sample label vector: :fixation, :saccade, or :noise.
"""
function _ivt_classify(
    vel::Vector{Float64},
    threshold::Float64,
    min_fix_samples::Int,
    min_sacc_samples::Int,
)
    n = length(vel)
    labels = fill(:noise, n)

    # initial classification based on velocity
    for i = 1:n
        if isnan(vel[i])
            labels[i] = :noise
        elseif vel[i] < threshold
            labels[i] = :fixation
        else
            labels[i] = :saccade
        end
    end

    # merge short saccade gaps within fixation runs
    # If a short saccade burst (< min_sacc_samples) is sandwiched between
    # fixations, reclassify it as fixation
    i = 1
    while i <= n
        if labels[i] == :saccade
            j = i
            while j <= n && labels[j] == :saccade
                j += 1
            end
            run_len = j - i
            if run_len < min_sacc_samples
                # Check if surrounded by fixations
                before_fix = i > 1 && labels[i-1] == :fixation
                after_fix = j <= n && labels[j] == :fixation
                if before_fix && after_fix
                    labels[i:(j-1)] .= :fixation
                end
            end
            i = j
        else
            i += 1
        end
    end

    # discard fixations shorter than minimum
    i = 1
    while i <= n
        if labels[i] == :fixation
            j = i
            while j <= n && labels[j] == :fixation
                j += 1
            end
            if (j - i) < min_fix_samples
                labels[i:(j-1)] .= :noise
            end
            i = j
        else
            i += 1
        end
    end

    return labels
end

# ── I-DT Algorithm ─────────────────────────────────────────────────────────── #

"""
Classify samples using I-DT (dispersion threshold identification).
Dispersion = (max_x - min_x) + (max_y - min_y) in degrees.
"""
function _idt_classify(
    gx::Vector{Float64},
    gy::Vector{Float64},
    ppd::Float64,
    disp_threshold::Float64,
    min_fix_samples::Int,
)
    n = length(gx)
    labels = fill(:saccade, n)

    i = 1
    while i <= n - min_fix_samples + 1
        # Skip NaN samples
        if isnan(gx[i]) || isnan(gy[i])
            i += 1
            continue
        end

        # Find min_fix_samples valid points starting from i
        valid_count = 0
        k = i
        while k <= n && valid_count < min_fix_samples
            if !isnan(gx[k]) && !isnan(gy[k])
                valid_count += 1
            end
            k += 1
        end
        if valid_count < min_fix_samples
            break
        end
        j = k - 1

        # Compute dispersion of initial window
        x_min, x_max = Inf, -Inf
        y_min, y_max = Inf, -Inf
        for k = i:j
            if !isnan(gx[k]) && !isnan(gy[k])
                x_min = min(x_min, gx[k])
                x_max = max(x_max, gx[k])
                y_min = min(y_min, gy[k])
                y_max = max(y_max, gy[k])
            end
        end
        dispersion = ((x_max - x_min) + (y_max - y_min)) / ppd

        if dispersion <= disp_threshold
            # Fixation detected — expand window until dispersion exceeds threshold
            while j < n
                j += 1
                if isnan(gx[j]) || isnan(gy[j])
                    break  # NaN breaks the fixation
                end
                new_x_min = min(x_min, gx[j])
                new_x_max = max(x_max, gx[j])
                new_y_min = min(y_min, gy[j])
                new_y_max = max(y_max, gy[j])
                new_disp = ((new_x_max - new_x_min) + (new_y_max - new_y_min)) / ppd
                if new_disp > disp_threshold
                    j -= 1  # this sample exceeds threshold, back up
                    break
                end
                x_min, x_max = new_x_min, new_x_max
                y_min, y_max = new_y_min, new_y_max
            end
            labels[i:j] .= :fixation
            i = j + 1
        else
            i += 1
        end
    end

    return labels
end

# ── Column writing ─────────────────────────────────────────────────────────── #

"""Write detected events into DataFrame columns using the standard schema."""
function _write_event_columns!(
    df::EyeData,
    labels::Vector{Symbol},
    gx::AbstractVector{<:AbstractFloat},
    gy::AbstractVector{<:AbstractFloat},
    pa::AbstractVector{<:AbstractFloat},
    vel::Vector{Float64},
    ppd::Float64,
    sample_rate::Float64,
    prefix::Union{Nothing,Symbol},
)
    n = length(labels)

    # Build column name helper
    col(name) = isnothing(prefix) ? name : Symbol(string(prefix) * "_" * string(name))

    # ── Fixation columns ──
    in_fix = falses(n)
    fix_gavx = fill(NaN, n)
    fix_gavy = fill(NaN, n)
    fix_ava = fill(NaN, n)
    fix_dur = fill(Int32(0), n)

    # ── Saccade columns ──
    in_sacc = falses(n)
    sacc_gstx = fill(NaN, n)
    sacc_gsty = fill(NaN, n)
    sacc_genx = fill(NaN, n)
    sacc_geny = fill(NaN, n)
    sacc_dur = fill(Int32(0), n)
    sacc_ampl = fill(NaN, n)
    sacc_pvel = fill(NaN, n)

    # ── Process fixation runs ──
    i = 1
    while i <= n
        if labels[i] == :fixation
            j = i
            while j <= n && labels[j] == :fixation
                j += 1
            end
            # Fixation from i to j-1
            run = i:(j-1)
            in_fix[run] .= true

            # Compute centroid (mean gaze, ignoring NaN)
            sum_x, sum_y, sum_pa, cnt = 0.0, 0.0, 0.0, 0
            for k in run
                if !isnan(gx[k]) && !isnan(gy[k])
                    sum_x += gx[k]
                    sum_y += gy[k]
                    if !isnan(pa[k])
                        sum_pa += pa[k]
                    end
                    cnt += 1
                end
            end
            if cnt > 0
                cx = sum_x / cnt
                cy = sum_y / cnt
                ca = sum_pa / cnt
                dur_ms = round(Int32, length(run) / sample_rate * 1000.0)
                fix_gavx[run] .= cx
                fix_gavy[run] .= cy
                fix_ava[run] .= ca
                fix_dur[run] .= dur_ms
            end
            i = j
        else
            i += 1
        end
    end

    # ── Process saccade runs ──
    i = 1
    while i <= n
        if labels[i] == :saccade
            j = i
            while j <= n && labels[j] == :saccade
                j += 1
            end
            # Saccade from i to j-1
            run = i:(j-1)
            in_sacc[run] .= true
            dur_ms = round(Int32, length(run) / sample_rate * 1000.0)

            # Find first and last valid gaze sample in the saccade
            first_valid = 0
            last_valid = 0
            peak_v = 0.0
            for k in run
                if !isnan(gx[k]) && !isnan(gy[k])
                    first_valid == 0 && (first_valid = k)
                    last_valid = k
                end
                if !isnan(vel[k]) && vel[k] > peak_v
                    peak_v = vel[k]
                end
            end

            if first_valid > 0 && last_valid > 0
                stx, sty = gx[first_valid], gy[first_valid]
                enx, eny = gx[last_valid], gy[last_valid]
                dx = enx - stx
                dy = eny - sty
                amp = sqrt(dx^2 + dy^2) / ppd

                sacc_gstx[run] .= stx
                sacc_gsty[run] .= sty
                sacc_genx[run] .= enx
                sacc_geny[run] .= eny
                sacc_ampl[run] .= amp
                sacc_pvel[run] .= peak_v
            end
            sacc_dur[run] .= dur_ms
            i = j
        else
            i += 1
        end
    end

    # ── Write to DataFrame ──
    df.df[!, col(:in_fix)] = in_fix
    df.df[!, col(:fix_gavx)] = fix_gavx
    df.df[!, col(:fix_gavy)] = fix_gavy
    df.df[!, col(:fix_ava)] = fix_ava
    df.df[!, col(:fix_dur)] = fix_dur
    df.df[!, col(:in_sacc)] = in_sacc
    df.df[!, col(:sacc_gstx)] = sacc_gstx
    df.df[!, col(:sacc_gsty)] = sacc_gsty
    df.df[!, col(:sacc_genx)] = sacc_genx
    df.df[!, col(:sacc_geny)] = sacc_geny
    df.df[!, col(:sacc_dur)] = sacc_dur
    df.df[!, col(:sacc_ampl)] = sacc_ampl
    df.df[!, col(:sacc_pvel)] = sacc_pvel
end

# ── Main entry point ───────────────────────────────────────────────────────── #

"""
    detect_events!(df::EyeData; method=:ivt, eye=:auto, ...)

Detect fixations and saccades using velocity-based (I-VT) or dispersion-based
(I-DT) algorithms. Writes event columns directly into the DataFrame using the
standard EyeFun column schema (`in_fix`, `fix_gavx`, `in_sacc`, `sacc_gstx`, etc.).

By default, **overwrites** existing event columns. Use `prefix=:ivt` to write
to prefixed columns instead (e.g. `ivt_in_fix`), preserving originals for comparison.

# Arguments
- `method=:ivt`: Detection algorithm — `:ivt` (velocity threshold) or `:idt` (dispersion threshold)
- `eye=:auto`: Which eye to use — `:auto`, `:left`, or `:right`
- `velocity_threshold=30.0`: Velocity threshold in °/s (I-VT only)
- `dispersion_threshold=1.0`: Spatial dispersion threshold in ° (I-DT only)
- `min_fixation_ms=60`: Minimum fixation duration in ms
- `min_saccade_ms=10`: Minimum saccade duration in ms
- `min_blink_ms=80`: Minimum NaN-run duration to classify as a blink (SMI/NaN-encoded data only)
- `pixels_per_degree=nothing`: Override automatic ppd calculation
- `prefix=nothing`: `nothing` → overwrite columns; `:ivt`/`:idt` → prefix columns

# Example
```julia
# Basic usage — overwrites EyeLink events
detect_events!(df; velocity_threshold=30.0)

# Keep EyeLink events, write custom detection to prefixed columns
detect_events!(df; method=:ivt, prefix=:ivt)

# Compare: EyeLink fixations vs I-VT fixations
count(df.in_fix)        # EyeLink
count(df.ivt_in_fix)    # custom I-VT

# I-DT for lower sample rate data
detect_events!(df; method=:idt, dispersion_threshold=1.5)
```
"""
function detect_events!(
    df::EyeData;
    eye::Symbol = :auto,
    method::Symbol = :ivt,
    velocity_threshold::Real = 30.0,
    dispersion_threshold::Real = 1.0,
    min_fixation_ms::Int = 60,
    min_saccade_ms::Int = 10,
    min_blink_ms::Int = 80,
    pixels_per_degree_override::Union{Nothing,Real} = nothing,
    prefix::Union{Nothing,Symbol} = nothing,
)

    method ∈ (:ivt, :idt) || error("Invalid method=:$method. Use :ivt or :idt.")

    # Resolve eye and column names
    eye = _resolve_eye(df, eye)
    ecols = _eye_columns(eye)
    gx_col, gy_col, pa_col = ecols.gx, ecols.gy, ecols.pa

    # Compute pixels per degree
    ppd = if !isnothing(pixels_per_degree_override)
        Float64(pixels_per_degree_override)
    else
        pixels_per_degree(df)
    end

    sample_rate = df.sample_rate

    # Convert ms thresholds to samples
    samples_per_ms = sample_rate / 1000.0
    min_fix_samples = max(1, round(Int, min_fixation_ms * samples_per_ms))
    min_sacc_samples = max(1, round(Int, min_saccade_ms * samples_per_ms))

    # Process whole continuous recording
    gx = Vector{Float64}(df.df[!, gx_col])
    gy = Vector{Float64}(df.df[!, gy_col])
    pa = Vector{Float64}(df.df[!, pa_col])

    all_vel = _compute_velocity_deg(gx, gy, ppd, sample_rate)
    if method == :ivt
        all_labels =
            _ivt_classify(all_vel, velocity_threshold, min_fix_samples, min_sacc_samples)
    else
        all_labels = _idt_classify(gx, gy, ppd, dispersion_threshold, min_fix_samples)
    end

    # Write columns
    _write_event_columns!(df, all_labels, gx, gy, pa, all_vel, ppd, sample_rate, prefix)

    # For NaN-encoded sources (SMI, Tobii), auto-detect blinks from contiguous NaN runs
    if df.source in (:smi, :tobii)
        _detect_nan_blinks!(df, min_blink_ms, eye)
    end

    return df
end

# ── Generic NaN Blink padding ──────────────────────────────────────────────── #

"""
    _detect_nan_blinks!(ed::EyeData, min_blink_ms::Int, eye::Symbol)

Detect blinks as contiguous NaN runs in the gaze signal for the selected `eye`.
Populates `in_blink` and `blink_dur` columns in `ed.df` using the same schema
as the EyeLink pipeline.
"""
function _detect_nan_blinks!(ed::EyeData, min_blink_ms::Int, eye::Symbol)
    df = ed.df
    n  = nrow(df)

    ecols = _eye_columns(eye)
    
    # Determine which eye column to use for NaN detection (preferred: gaze, fallback: pupil)
    detect_col = if hasproperty(df, ecols.gx) && any(!isnan, df[!, ecols.gx])
        ecols.gx
    elseif hasproperty(df, ecols.pa) && any(!isnan, df[!, ecols.pa])
        ecols.pa
    else
        nothing # 100% missing data
    end

    sr = ed.sample_rate
    min_blink_samples = max(1, round(Int, min_blink_ms * sr / 1000.0))

    in_blink = falses(n)
    blink_dur = fill(Int32(0), n)

    if !isnothing(detect_col)
        track = df[!, detect_col]
        i = 1
        while i <= n
            if isnan(track[i])
                j = i
                while j <= n && isnan(track[j])
                    j += 1
                end
                run_len = j - i
                if run_len >= min_blink_samples
                    run = i:(j-1)
                    in_blink[run] .= true
                    blink_dur[run] .= round(Int32, run_len / sr * 1000.0)
                end
                i = j
            else
                i += 1
            end
        end
    end

    df[!, :in_blink]  = in_blink
    df[!, :blink_dur] = blink_dur
    return
end
