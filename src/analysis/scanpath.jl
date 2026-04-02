"""
    scanpath_similarity(df::EyeData, aois::Vector{<:AOI};
                        selection1, selection2, eye=:auto, method=:levenshtein)

Compare scanpaths between two selections using string-edit distance on AOI sequences.

Returns a `NamedTuple` with:
- `distance` — raw edit distance (Levenshtein) or normalized distance
- `similarity` — 1 - normalized distance (0 = completely different, 1 = identical)
- `seq1` — AOI sequence for selection 1
- `seq2` — AOI sequence for selection 2

# Methods
- `:levenshtein` — string edit distance on AOI letter sequences

# Example
```julia
aois = [RectAOI("Face", 400, 200, 800, 600), RectAOI("Text", 0, 700, 1280, 960)]
result = scanpath_similarity(df, aois; selection1=(trial=1,), selection2=(trial=2,))
println("Similarity: ", result.similarity)
```
"""
function scanpath_similarity(
    df::EyeData,
    aois::Vector{<:AOI};
    selection1,
    selection2,
    time_window::Union{Nothing,Tuple}=nothing,
)

    seq1 = _aoi_sequence(df, aois, selection1, time_window)
    seq2 = _aoi_sequence(df, aois, selection2, time_window)

    dist = _levenshtein(seq1, seq2)
    max_len = max(length(seq1), length(seq2))
    norm_dist = max_len > 0 ? dist / max_len : 0.0
    similarity = 1.0 - norm_dist

    return (
        distance=dist,
        similarity=round(similarity; digits=4),
        seq1=seq1,
        seq2=seq2,
    )
end

"""
    transition_matrix(df::EyeData, aois::Vector{<:AOI};
                      selection=nothing, normalize=true, time_window=nothing)

Compute an AOI-to-AOI transition matrix from fixation sequences.

Returns a `NamedTuple` with:
- `matrix` — `n×n` matrix of transition counts (or probabilities if `normalize=true`)
- `labels` — AOI name labels in row/column order

# Example
```julia
aois = [RectAOI("Face", 400, 200, 800, 600), RectAOI("Text", 0, 700, 1280, 960)]
tm = transition_matrix(df, aois; selection=(trial=1:10,))
tm.matrix   # 2×2 transition probability matrix
tm.labels   # ["Face", "Text"]
```
"""
function transition_matrix(
    df::EyeData,
    aois::Vector{<:AOI};
    selection = nothing,
    normalize::Bool = true,
    time_window::Union{Nothing,Tuple}=nothing,
)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && error("No samples found for the given selection.")

    n_aois = length(aois)
    labels = [a.name for a in aois]
    mat = zeros(Float64, n_aois, n_aois)

    # Build fixation sequence with AOI labels
    hasproperty(samples, :fix_gavx) ||
        error("No fixation columns. Run event detection first.")

    in_fix = samples.in_fix
    fix_gx = samples.fix_gavx
    fix_gy = samples.fix_gavy

    # Apply time window prior to sequence extraction
    if !isnothing(time_window)
        t_start, t_end = _resolve_time_window(samples, time_window)
        t0 = Float64(samples.time[1])
        t_relative = Float64.(samples.time) .- t0
        
        valid_idx = findall(t_start .<= t_relative .<= t_end)
        samples = samples[valid_idx, :]
        in_fix = in_fix[valid_idx]
        fix_gx = fix_gx[valid_idx]
        fix_gy = fix_gy[valid_idx]
    end

    # Extract unique fixations
    fix_sequence = Int[]  # AOI index for each fixation (0 = outside all AOIs)
    prev_fx = NaN
    for i = 1:nrow(samples)
        in_fix[i] || continue
        fx = Float64(fix_gx[i])
        isnan(fx) && continue
        fx == prev_fx && continue  # same fixation
        prev_fx = fx

        fy = Float64(fix_gy[i])
        # Find which AOI this fixation falls in
        aoi_idx = 0
        for (ai, aoi) in enumerate(aois)
            if in_aoi(aoi, fx, fy)
                aoi_idx = ai
                break
            end
        end
        push!(fix_sequence, aoi_idx)
    end

    # Count transitions (skip fixations outside all AOIs)
    for i = 2:length(fix_sequence)
        from = fix_sequence[i-1]
        to = fix_sequence[i]
        from == 0 && continue
        to == 0 && continue
        mat[from, to] += 1.0
    end

    # Normalize rows to probabilities
    if normalize
        for r = 1:n_aois
            row_sum = sum(mat[r, :])
            if row_sum > 0
                mat[r, :] ./= row_sum
            end
        end
    end

    return (matrix = mat, labels = labels)
end

"""
    transition_entropy(tm::NamedTuple) -> Float64
    transition_entropy(mat::Matrix{Float64}) -> Float64

Compute the Shannon entropy of an AOI transition matrix.
Outputs a scalar (in bits) representing the unpredictability/complexity of the visual scanning pattern.
A higher value indicates more chaotic scanning across AOIs.

# Example
```julia
tm = transition_matrix(df, aois; selection=(trial=1,), normalize=false)
ent = transition_entropy(tm)
```
"""
function transition_entropy(mat::Matrix{Float64})
    total_transitions = sum(mat)
    total_transitions == 0 && return 0.0
    
    # Normalize the entire matrix to sum to 1 to compute joint probabilities
    p_matrix = mat ./ total_transitions
    
    H = 0.0
    for p in p_matrix
        if p > 0.0
            H -= p * log2(p)
        end
    end
    return H
end

transition_entropy(tm::NamedTuple) = transition_entropy(tm.matrix)

"""Extract AOI fixation sequence as a string of single characters."""
function _aoi_sequence(df::EyeData, aois::Vector{<:AOI}, selection, time_window)
    samples = _apply_selection(df, selection)
    nrow(samples) == 0 && return ""

    hasproperty(samples, :fix_gavx) ||
        error("No fixation columns. Run event detection first.")

    # Map AOI indices to single characters (A, B, C, ...)
    letters = 'A':'Z'
    length(aois) > 26 && error("Maximum 26 AOIs supported for scanpath comparison.")

    seq = Char[]
    prev_fx = NaN

    in_fix = samples.in_fix
    fix_gx = samples.fix_gavx
    fix_gy = samples.fix_gavy

    # Apply time window prior to sequence extraction
    if !isnothing(time_window)
        t_start, t_end = _resolve_time_window(samples, time_window)
        t0 = Float64(samples.time[1])
        t_relative = Float64.(samples.time) .- t0
        
        valid_idx = findall(t_start .<= t_relative .<= t_end)
        samples = samples[valid_idx, :]
        in_fix = in_fix[valid_idx]
        fix_gx = fix_gx[valid_idx]
        fix_gy = fix_gy[valid_idx]
    end

    for i = 1:nrow(samples)
        in_fix[i] || continue
        fx = Float64(fix_gx[i])
        isnan(fx) && continue
        fx == prev_fx && continue
        prev_fx = fx

        fy = Float64(fix_gy[i])
        for (ai, aoi) in enumerate(aois)
            if in_aoi(aoi, fx, fy)
                push!(seq, letters[ai])
                break
            end
        end
    end

    return String(seq)
end

"""Levenshtein edit distance between two strings."""
function _levenshtein(s::AbstractString, t::AbstractString)
    m, n = length(s), length(t)
    m == 0 && return n
    n == 0 && return m

    # Use two-row optimization
    prev = collect(0:n)
    curr = similar(prev)

    for i = 1:m
        curr[1] = i
        for j = 1:n
            cost = s[i] == t[j] ? 0 : 1
            curr[j+1] = min(
                prev[j+1] + 1,     # deletion
                curr[j] + 1,       # insertion
                prev[j] + cost,    # substitution
            )
        end
        prev, curr = curr, prev
    end

    return prev[n+1]
end
