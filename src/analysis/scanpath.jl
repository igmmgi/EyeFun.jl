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
    eye::Symbol=:auto,
)

    seq1 = _aoi_sequence(df, aois, selection1, eye)
    seq2 = _aoi_sequence(df, aois, selection2, eye)

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

"""Extract AOI fixation sequence as a string of single characters."""
function _aoi_sequence(df::EyeData, aois::Vector{<:AOI}, selection, eye::Symbol)
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
