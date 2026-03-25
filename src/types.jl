# ── EyeData type ───────────────────────────────────────────────────────────── #

"""
    EyeData

Eye-tracking data container that pairs sample-level data in a `DataFrame`
with recording metadata (sample rate, screen geometry, etc.).

# Fields
- `df::DataFrame` — sample-level data (gaze, pupil, events, etc.)
- `source::Symbol` — data source (`:eyelink`, `:tobii`, `:pupil_labs`, `:generic`)
- `sample_rate::Float64` — sampling frequency in Hz
- `screen_res::Tuple{Int,Int}` — screen resolution `(width, height)` in pixels
- `screen_width_cm::Float64` — physical screen width in cm
- `viewing_distance_cm::Float64` — distance from screen to eyes in cm

# Example
```julia
edf = read_eyelink("data.edf")
ed = create_eyelink_edf_dataframe(edf)  # returns EyeData

ed.df.gxR      # access columns via .dataframe
nrow(ed.df)    # DataFrame functions on .df
plot_gaze(ed)  # all plot/analysis functions accept EyeData
ed.screen_res  # metadata fields directly
```
"""
mutable struct EyeData
    df::DataFrame
    source::Symbol
    sample_rate::Float64
    screen_res::Tuple{Int,Int}
    screen_width_cm::Float64
    viewing_distance_cm::Float64
end

"""
    EyeData(df::DataFrame; source=:generic, sample_rate=1000.0,
            screen_res=(1920,1080), screen_width_cm=53.0, viewing_distance_cm=60.0)

Construct an `EyeData` wrapper from a plain DataFrame.
"""
function EyeData(
    df::DataFrame;
    source::Symbol = :generic,
    sample_rate::Real = 1000.0,
    screen_res::Tuple{Int,Int} = (1920, 1080),
    screen_width_cm::Real = 53.0,
    viewing_distance_cm::Real = 60.0,
)
    EyeData(
        df,
        source,
        Float64(sample_rate),
        screen_res,
        Float64(screen_width_cm),
        Float64(viewing_distance_cm),
    )
end

# ── Show ───────────────────────────────────────────────────────────────────── #

function Base.show(io::IO, ed::EyeData)
    sr = Int(ed.sample_rate)
    w, h = ed.screen_res
    print(io, "EyeData($(ed.source), $(sr) Hz, $(w)×$(h))")
end

function Base.show(io::IO, ::MIME"text/plain", ed::EyeData)
    df = ed.df
    sr = Int(ed.sample_rate)
    w, h = ed.screen_res
    println(io, "EyeData ($(ed.source), $(sr) Hz, $(w)×$(h))")

    # Samples
    ns = nrow(df)
    dur_s = ns / ed.sample_rate
    dur_min = dur_s / 60.0
    if dur_min >= 1.0
        println(io, "  $(ns) samples ($(round(dur_min; digits=1)) min)")
    else
        println(io, "  $(ns) samples ($(round(dur_s; digits=1)) s)")
    end

    # Trials
    # TODO: better way of giving user way of defining "trials"
    if hasproperty(df, :trial)
        nt = length(unique(skipmissing(df.trial)))
        nt > 0 && println(io, "  $(nt) trials")
    end

    # Event counts
    _count_onsets(v) = count(i -> v[i] && (i == 1 || !v[i-1]), eachindex(v))
    parts = String[]
    hasproperty(df, :in_fix) && push!(parts, "$(_count_onsets(df.in_fix)) fixations")
    hasproperty(df, :in_sacc) && push!(parts, "$(_count_onsets(df.in_sacc)) saccades")
    hasproperty(df, :in_blink) && push!(parts, "$(_count_onsets(df.in_blink)) blinks")
    !isempty(parts) && println(io, "  ", join(parts, ", "))

    # Columns
    print(io, "  $(ncol(df)) columns: ", join(names(df), ", "))
end

# ── AOI Type System ────────────────────────────────────────────────────────── #

"""
    AOI

Abstract supertype for all Area of Interest definitions.

Subtypes must implement:
- `contains(aoi, x, y) -> Bool` — point-in-AOI test

Future subtypes (e.g. `DynamicAOI`, `GroupAOI`) can extend this hierarchy.
"""
abstract type AOI end

# ── RectAOI ────────────────────────────────────────────────────────────────── #

"""
    RectAOI(name, x1, y1, x2, y2)

Rectangular Area of Interest defined by (x1, y1) bottom-left and (x2, y2) top-right corners.

```julia
aoi = RectAOI("Button", 100, 200, 300, 400)
contains(aoi, 150, 300)  # true
```
"""
struct RectAOI <: AOI
    name::String
    x1::Float64
    y1::Float64
    x2::Float64
    y2::Float64
end

contains(aoi::RectAOI, x::Real, y::Real) =
    aoi.x1 <= x <= aoi.x2 && aoi.y1 <= y <= aoi.y2

# ── CircleAOI ──────────────────────────────────────────────────────────────── #

"""
    CircleAOI(name, cx, cy, radius)

Circular Area of Interest defined by center and radius.

```julia
aoi = CircleAOI("Fixation Cross", 640, 480, 50)
contains(aoi, 650, 485)  # true
```
"""
struct CircleAOI <: AOI
    name::String
    cx::Float64
    cy::Float64
    radius::Float64
end

contains(aoi::CircleAOI, x::Real, y::Real) =
    (x - aoi.cx)^2 + (y - aoi.cy)^2 <= aoi.radius^2

# ── EllipseAOI ─────────────────────────────────────────────────────────────── #

"""
    EllipseAOI(name, cx, cy, rx, ry)

Elliptical Area of Interest defined by center and semi-axes.

```julia
aoi = EllipseAOI("Face", 640, 400, 100, 150)
contains(aoi, 640, 400)  # true
```
"""
struct EllipseAOI <: AOI
    name::String
    cx::Float64
    cy::Float64
    rx::Float64
    ry::Float64
end

contains(aoi::EllipseAOI, x::Real, y::Real) =
    ((x - aoi.cx) / aoi.rx)^2 + ((y - aoi.cy) / aoi.ry)^2 <= 1.0

# ── PolygonAOI ─────────────────────────────────────────────────────────────── #

"""
    PolygonAOI(name, vertices)

Polygonal Area of Interest defined by a list of `(x, y)` vertices.
The polygon is automatically closed (first vertex connected to last).

```julia
aoi = PolygonAOI("Region", [(100,100), (200,50), (300,100), (250,200), (150,200)])
contains(aoi, 200, 150)  # true
```
"""
struct PolygonAOI <: AOI
    name::String
    vertices::Vector{Tuple{Float64,Float64}}
end

"""Point-in-polygon using the ray casting algorithm."""
function contains(aoi::PolygonAOI, x::Real, y::Real)
    verts = aoi.vertices
    n = length(verts)
    n < 3 && return false
    inside = false
    j = n
    for i in 1:n
        xi, yi = verts[i]
        xj, yj = verts[j]
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

# ── AOI Show methods ──────────────────────────────────────────────────────── #

Base.show(io::IO, a::RectAOI) = print(io, "RectAOI(\"$(a.name)\", $(a.x1), $(a.y1), $(a.x2), $(a.y2))")
Base.show(io::IO, a::CircleAOI) = print(io, "CircleAOI(\"$(a.name)\", $(a.cx), $(a.cy), r=$(a.radius))")
Base.show(io::IO, a::EllipseAOI) = print(io, "EllipseAOI(\"$(a.name)\", $(a.cx), $(a.cy), $(a.rx)×$(a.ry))")
Base.show(io::IO, a::PolygonAOI) = print(io, "PolygonAOI(\"$(a.name)\", $(length(a.vertices)) vertices)")


# ── Event Extraction from EyeData ──────────────────────────────────────────── #

"""
    fixations(ed::EyeData; prefix=nothing) -> DataFrame

Reconstruct a fixations DataFrame by extracting contiguous blocks from the `in_fix` column
(or `[prefix]_in_fix` if specified).
"""
function fixations(ed::EyeData; prefix::Union{Nothing,Symbol}=nothing)
    col(name) = prefix === nothing ? name : Symbol(string(prefix) * "_" * string(name))
    df = ed.df
    mask_col = col(:in_fix)
    !hasproperty(df, mask_col) && return DataFrame()
    
    mask = df[!, mask_col]
    n = length(mask)
    sttime, entime = UInt32[], UInt32[]
    gavx, gavy, ava = Float64[], Float64[], Float64[]
    dur = Int32[]
    
    has_gavx = hasproperty(df, col(:fix_gavx))
    has_gavy = hasproperty(df, col(:fix_gavy))
    has_ava = hasproperty(df, col(:fix_ava))
    has_dur = hasproperty(df, col(:fix_dur))
    times = df.time
    
    i = 1
    while i <= n
        if mask[i]
            j = i
            while j <= n && mask[j]
                j += 1
            end
            push!(sttime, times[i])
            push!(entime, times[j-1])
            push!(dur, has_dur ? df[i, col(:fix_dur)] : Int32(times[j-1] - times[i] + 1))
            push!(gavx, has_gavx ? df[i, col(:fix_gavx)] : NaN)
            push!(gavy, has_gavy ? df[i, col(:fix_gavy)] : NaN)
            push!(ava, has_ava ? df[i, col(:fix_ava)] : NaN)
            i = j
        else
            i += 1
        end
    end
    
    result = DataFrame(sttime=sttime, entime=entime, duration=dur)
    has_gavx && (result.gavx = gavx)
    has_gavy && (result.gavy = gavy)
    has_ava && (result.ava = ava)
    return result
end

"""
    saccades(ed::EyeData; prefix=nothing) -> DataFrame

Reconstruct a saccades DataFrame by extracting contiguous blocks from the `in_sacc` column
(or `[prefix]_in_sacc` if specified).
"""
function saccades(ed::EyeData; prefix::Union{Nothing,Symbol}=nothing)
    col(name) = prefix === nothing ? name : Symbol(string(prefix) * "_" * string(name))
    df = ed.df
    mask_col = col(:in_sacc)
    !hasproperty(df, mask_col) && return DataFrame()
    
    mask = df[!, mask_col]
    n = length(mask)
    sttime, entime = UInt32[], UInt32[]
    gstx, gsty, genx, geny = Float64[], Float64[], Float64[], Float64[]
    ampl, pvel = Float64[], Float64[]
    dur = Int32[]

    has_gstx = hasproperty(df, col(:sacc_gstx))
    has_gsty = hasproperty(df, col(:sacc_gsty))
    has_genx = hasproperty(df, col(:sacc_genx))
    has_geny = hasproperty(df, col(:sacc_geny))
    has_ampl = hasproperty(df, col(:sacc_ampl))
    has_pvel = hasproperty(df, col(:sacc_pvel))
    has_dur = hasproperty(df, col(:sacc_dur))
    times = df.time
    
    i = 1
    while i <= n
        if mask[i]
            j = i
            while j <= n && mask[j]
                j += 1
            end
            push!(sttime, times[i])
            push!(entime, times[j-1])
            push!(dur, has_dur ? df[i, col(:sacc_dur)] : Int32(times[j-1] - times[i] + 1))
            push!(gstx, has_gstx ? df[i, col(:sacc_gstx)] : NaN)
            push!(gsty, has_gsty ? df[i, col(:sacc_gsty)] : NaN)
            push!(genx, has_genx ? df[i, col(:sacc_genx)] : NaN)
            push!(geny, has_geny ? df[i, col(:sacc_geny)] : NaN)
            push!(ampl, has_ampl ? df[i, col(:sacc_ampl)] : NaN)
            push!(pvel, has_pvel ? df[i, col(:sacc_pvel)] : NaN)
            i = j
        else
            i += 1
        end
    end
    
    result = DataFrame(sttime=sttime, entime=entime, duration=dur)
    has_gstx && (result.gstx = gstx)
    has_gsty && (result.gsty = gsty)
    has_genx && (result.genx = genx)
    has_geny && (result.geny = geny)
    has_ampl && (result.ampl = ampl)
    has_pvel && (result.pvel = pvel)
    
    return result
end

"""
    blinks(ed::EyeData; prefix=nothing) -> DataFrame

Reconstruct a blinks DataFrame by extracting contiguous blocks from the `in_blink` column.
"""
function blinks(ed::EyeData; prefix::Union{Nothing,Symbol}=nothing)
    col(name) = prefix === nothing ? name : Symbol(string(prefix) * "_" * string(name))
    df = ed.df
    mask_col = col(:in_blink)
    !hasproperty(df, mask_col) && return DataFrame()
    
    mask = df[!, mask_col]
    n = length(mask)
    sttime, entime = UInt32[], UInt32[]
    dur = Int32[]

    has_dur = hasproperty(df, col(:blink_dur))
    times = df.time
    
    i = 1
    while i <= n
        if mask[i]
            j = i
            while j <= n && mask[j]
                j += 1
            end
            push!(sttime, times[i])
            push!(entime, times[j-1])
            push!(dur, has_dur ? df[i, col(:blink_dur)] : Int32(times[j-1] - times[i] + 1))
            i = j
        else
            i += 1
        end
    end
    
    return DataFrame(sttime=sttime, entime=entime, duration=dur)
end

"""
    variables(ed::EyeData) -> DataFrame

Extract the trial-level variables joined to the `EyeData.df`.
Returns a `DataFrame` with one row per valid trial.
"""
function variables(ed::EyeData)
    df = ed.df
    !hasproperty(df, :trial) && return DataFrame()
    
    res = combine(groupby(df, :trial; skipmissing=true), first)
    
    # Generic sample columns to drop
    sample_cols = Set([:time, :gxR, :gyR, :paR, :gxL, :gyL, :paL, 
                   :in_fix, :fix_gavx, :fix_gavy, :fix_ava, :fix_dur,
                   :in_sacc, :sacc_gstx, :sacc_gsty, :sacc_genx, :sacc_geny, :sacc_dur, :sacc_ampl, :sacc_pvel,
                   :in_blink, :blink_dur, :message, :time_rel,
                   :ivt_in_fix, :ivt_fix_gavx, :ivt_fix_gavy, :ivt_fix_ava, :ivt_fix_dur,
                   :ivt_in_sacc, :ivt_sacc_gstx, :ivt_sacc_gsty, :ivt_sacc_genx, :ivt_sacc_geny, 
                   :ivt_sacc_dur, :ivt_sacc_ampl, :ivt_sacc_pvel,
                   :idt_in_fix, :idt_fix_gavx, :idt_fix_gavy, :idt_fix_ava, :idt_fix_dur,
                   :idt_in_sacc, :idt_sacc_gstx, :idt_sacc_gsty, :idt_sacc_genx, :idt_sacc_geny, 
                   :idt_sacc_dur, :idt_sacc_ampl, :idt_sacc_pvel])
                   
    keep_cols = [c for c in propertynames(res) if c ∉ sample_cols]
    return select(res, keep_cols)
end

