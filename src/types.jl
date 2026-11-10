"""
    EyeFile

Abstract supertype for raw eye-tracking file containers returned by format-specific
readers (`read_eyelink`, `read_smi`, `read_tobii`).

All subtypes expose:
- `.samples::DataFrame`: raw sample rows
- `.sample_rate::Float64`: recording frequency in Hz
- `.screen_res::Tuple{Int,Int}`: screen resolution `(width, height)` in pixels
- `.screen_width_cm::Float64`: physical screen width in cm
- `.viewing_distance_cm::Float64`: eye-to-screen distance in cm

Pass to `EyeData(raw)` or `create_eyefun_data(raw)` to construct an `EyeData` container.
"""
abstract type EyeFile end

"""
    EyeData

Eye-tracking data container that pairs sample-level data in a `DataFrame`
with recording metadata (sample rate, screen geometry, coordinate system).

# Fields
- `df::DataFrame`: sample-level data (gaze, pupil, events, trial metadata)
- `source::Symbol`: data source (`:eyelink`, `:smi`, `:tobii`, `:pupil_labs`, `:generic`)
- `sample_rate::Float64`: sampling frequency in Hz
- `screen_res::Tuple{Int,Int}`: screen resolution `(width, height)` in pixels
- `screen_width_cm::Float64`: physical screen width in cm
- `viewing_distance_cm::Float64`: distance from screen to eyes in cm
- `coords::Symbol`: gaze coordinate space (`:px` by default, `:center_px` or `:deg` after [`to_center_coords!`](@ref))

# Example
```julia
edf = read_eyelink("data.edf")
ed = EyeData(edf)              # EyeLink: uses tracker-native events

smi = read_smi("data.txt")
ed = EyeData(smi)              # SMI: format conversion only
detect_events!(ed)             # add fixations/saccades/blinks via I-VT

ed.df.gxR      # access columns via .df
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
    coords::Symbol

    function EyeData(
        df::DataFrame,
        source::Symbol,
        sample_rate::Real,
        screen_res::Tuple{Int,Int},
        screen_width_cm::Real,
        viewing_distance_cm::Real,
        coords::Symbol = :px,
    )
        sr = Float64(sample_rate)
        sw = Float64(screen_width_cm)
        vd = Float64(viewing_distance_cm)
        (isfinite(sr) && sr > 0.0) ||
            throw(ArgumentError("sample_rate must be positive (got $sample_rate)."))
        (screen_res[1] > 0 && screen_res[2] > 0) ||
            throw(ArgumentError("screen_res dimensions must be positive (got $screen_res)."))
        (isfinite(sw) && sw > 0.0) ||
            throw(ArgumentError("screen_width_cm must be positive (got $screen_width_cm)."))
        (isfinite(vd) && vd > 0.0) ||
            throw(ArgumentError("viewing_distance_cm must be positive (got $viewing_distance_cm)."))
        coords in (:px, :center_px, :deg) ||
            throw(ArgumentError("coords must be :px, :center_px, or :deg (got :$coords)."))
        new(df, source, sr, screen_res, sw, vd, coords)
    end
end

"""
    EyeData(df::DataFrame; source=:generic, sample_rate=1000.0,
            screen_res=(1920,1080), screen_width_cm=53.0, viewing_distance_cm=60.0, coords=:px)

Construct an `EyeData` wrapper from a plain DataFrame.
"""
function EyeData(
    df::DataFrame;
    source::Symbol = :generic,
    sample_rate::Real = 1000.0,
    screen_res::Tuple{Int,Int} = (1920, 1080),
    screen_width_cm::Real = 53.0,
    viewing_distance_cm::Real = 60.0,
    coords::Symbol = :px,
)
    return EyeData(
        df,
        source,
        sample_rate,
        screen_res,
        screen_width_cm,
        viewing_distance_cm,
        coords,
    )
end

"""
    EyeData(ed::EyeData, df::DataFrame) -> EyeData

Construct a new `EyeData` wrapping `df` while preserving all recording metadata
(`source`, `sample_rate`, `screen_res`, `screen_width_cm`, `viewing_distance_cm`, `coords`) from `ed`.
"""
function EyeData(ed::EyeData, df::DataFrame)
    return EyeData(
        df,
        ed.source,
        ed.sample_rate,
        ed.screen_res,
        ed.screen_width_cm,
        ed.viewing_distance_cm,
        ed.coords,
    )
end

"""
    EyeData(raw::EyeFile; kwargs...) -> EyeData

Construct an `EyeData` container from any format-specific `EyeFile`
(`EDFFile`, `SMIFile`, `TobiiFile`) by delegating to `create_eyefun_data`.
"""
EyeData(raw::EyeFile; kwargs...) = create_eyefun_data(raw; kwargs...)

Base.copy(ed::EyeData) = EyeData(ed, copy(ed.df))

function Base.filter(f, ed::EyeData; view::Bool = false)
    return view ? DataFrames.filter(f, ed.df; view = true) : EyeData(ed, filter(f, ed.df))
end

function Base.filter!(f, ed::EyeData)
    filter!(f, ed.df)
    return ed
end

function DataFrames.subset(ed::EyeData, args...; view::Bool = false, kwargs...)
    return view ? DataFrames.subset(ed.df, args...; view = true, kwargs...) :
           EyeData(ed, DataFrames.subset(ed.df, args...; view = false, kwargs...))
end

function DataFrames.subset!(ed::EyeData, args...; kwargs...)
    DataFrames.subset!(ed.df, args...; kwargs...)
    return ed
end

DataFrames.Tables.istable(::Type{EyeData}) = true
DataFrames.Tables.columnaccess(::Type{EyeData}) = true
DataFrames.Tables.columns(ed::EyeData) = DataFrames.Tables.columns(ed.df)
DataFrames.Tables.rowaccess(::Type{EyeData}) = true
DataFrames.Tables.rows(ed::EyeData) = DataFrames.Tables.rows(ed.df)
DataFrames.Tables.schema(ed::EyeData) = DataFrames.Tables.schema(ed.df)

DataFrames.nrow(ed::EyeData) = nrow(ed.df)
DataFrames.ncol(ed::EyeData) = ncol(ed.df)
DataFrames.names(ed::EyeData, args...; kwargs...) = names(ed.df, args...; kwargs...)
DataFrames.DataFrame(ed::EyeData; copycols::Bool = true) =
    DataFrame(ed.df; copycols = copycols)


function Base.show(io::IO, ed::EyeData)
    sr = round(ed.sample_rate; digits = 2)
    w, h = ed.screen_res
    print(io, "EyeData($(ed.source), $(sr) Hz, $(w)×$(h))")
end

function Base.show(io::IO, ::MIME"text/plain", ed::EyeData)
    df = ed.df
    sr = round(ed.sample_rate; digits = 2)
    w, h = ed.screen_res
    println(io, "EyeData ($(ed.source), $(sr) Hz, $(w)×$(h))")

    ns = nrow(df)
    if ed.sample_rate > 0.0
        dur_s = ns / ed.sample_rate
        dur_min = dur_s / 60.0
        if dur_min >= 1.0
            println(io, "  $(ns) samples ($(round(dur_min; digits=1)) min)")
        else
            println(io, "  $(ns) samples ($(round(dur_s; digits=1)) s)")
        end
    else
        println(io, "  $(ns) samples")
    end

    trial_str = ""
    if hasproperty(df, :trial)
        nt = length(unique(skipmissing(df.trial)))
        if nt > 0
            trial_str = "$(nt) trials, "
        end
    end

    parts = String[]
    hasproperty(df, :in_fix) && push!(parts, "$(counts(df.in_fix)) fixations")
    hasproperty(df, :in_sacc) && push!(parts, "$(counts(df.in_sacc)) saccades")
    hasproperty(df, :in_blink) && push!(parts, "$(counts(df.in_blink)) blinks")

    if isempty(parts)
        print(io, "  ", trial_str, "$(ncol(df)) columns")
    else
        println(io, "  ", trial_str, "$(ncol(df)) columns")
        print(io, "  ", join(parts, ", "))
    end
end

"""
    AOI

Abstract supertype for all Area of Interest definitions.

Subtypes must implement:
- `in_aoi(aoi, x, y) -> Bool`: spatial point-in-AOI test
- `in_aoi(aoi, x, y, t) -> Bool`: spatiotemporal point-in-AOI test (defaults to `in_aoi(aoi, x, y)` for static AOIs)
"""
abstract type AOI end

"""
    in_aoi(aoi::AOI, x::Real, y::Real) -> Bool
    in_aoi(aoi::AOI, x::Real, y::Real, t::Real) -> Bool

Test whether gaze coordinates `(x, y)` (and optional trial-relative timestamp `t` in ms
for [`DynamicAOI`](@ref)) fall inside `aoi`.
"""
in_aoi(aoi::AOI, x::Real, y::Real, t::Real) = in_aoi(aoi, x, y)

"""
    RectAOI(name, cx, cy, width, height)

Rectangular Area of Interest defined by its center `(cx, cy)` and dimensions `width` and `height`.

```julia
aoi = RectAOI("Button", 200, 300, 200, 200)
in_aoi(aoi, 150, 300)  # true
```
"""
struct RectAOI <: AOI
    name::String
    cx::Float64
    cy::Float64
    width::Float64
    height::Float64
    color::Any

    function RectAOI(
        name::AbstractString,
        cx::Real,
        cy::Real,
        width::Real,
        height::Real,
        color = nothing,
    )
        w = Float64(width)
        h = Float64(height)
        (isfinite(w) && w > 0.0 && isfinite(h) && h > 0.0) ||
            throw(ArgumentError("RectAOI width and height must be positive (got $(width)×$(height))."))
        new(String(name), Float64(cx), Float64(cy), w, h, color)
    end
end
RectAOI(name, cx, cy, width, height; color = nothing) =
    RectAOI(name, cx, cy, width, height, color)

in_aoi(aoi::RectAOI, x::Real, y::Real) =
    aoi.cx - aoi.width/2 <= x <= aoi.cx + aoi.width/2 &&
    aoi.cy - aoi.height/2 <= y <= aoi.cy + aoi.height/2

"""
    CircleAOI(name, cx, cy, radius)

Circular Area of Interest defined by center and radius.

```julia
aoi = CircleAOI("Fixation Cross", 640, 480, 50)
in_aoi(aoi, 650, 485)  # true
```
"""
struct CircleAOI <: AOI
    name::String
    cx::Float64
    cy::Float64
    radius::Float64
    color::Any

    function CircleAOI(
        name::AbstractString,
        cx::Real,
        cy::Real,
        radius::Real,
        color = nothing,
    )
        r = Float64(radius)
        (isfinite(r) && r > 0.0) ||
            throw(ArgumentError("CircleAOI radius must be positive (got $radius)."))
        new(String(name), Float64(cx), Float64(cy), r, color)
    end
end
CircleAOI(name, cx, cy, radius; color = nothing) = CircleAOI(name, cx, cy, radius, color)

in_aoi(aoi::CircleAOI, x::Real, y::Real) = (x - aoi.cx)^2 + (y - aoi.cy)^2 <= aoi.radius^2

"""
    EllipseAOI(name, cx, cy, rx, ry)

Elliptical Area of Interest defined by center and semi-axes.

```julia
aoi = EllipseAOI("Face", 640, 400, 100, 150)
in_aoi(aoi, 640, 400)  # true
```
"""
struct EllipseAOI <: AOI
    name::String
    cx::Float64
    cy::Float64
    rx::Float64
    ry::Float64
    color::Any

    function EllipseAOI(
        name::AbstractString,
        cx::Real,
        cy::Real,
        rx::Real,
        ry::Real,
        color = nothing,
    )
        rx_f = Float64(rx)
        ry_f = Float64(ry)
        (isfinite(rx_f) && rx_f > 0.0 && isfinite(ry_f) && ry_f > 0.0) ||
            throw(ArgumentError("EllipseAOI semi-axes rx and ry must be positive (got $(rx), $(ry))."))
        new(String(name), Float64(cx), Float64(cy), rx_f, ry_f, color)
    end
end
EllipseAOI(name, cx, cy, rx, ry; color = nothing) = EllipseAOI(name, cx, cy, rx, ry, color)

in_aoi(aoi::EllipseAOI, x::Real, y::Real) =
    ((x - aoi.cx) / aoi.rx)^2 + ((y - aoi.cy) / aoi.ry)^2 <= 1.0

"""
    PolygonAOI(name, vertices)

Polygonal Area of Interest defined by a list of `(x, y)` vertices.
The polygon is automatically closed (first vertex connected to last).

```julia
aoi = PolygonAOI("Region", [(100,100), (200,50), (300,100), (250,200), (150,200)])
in_aoi(aoi, 200, 150)  # true
```
"""
struct PolygonAOI <: AOI
    name::String
    vertices::Vector{Tuple{Float64,Float64}}
    color::Any

    function PolygonAOI(
        name::AbstractString,
        vertices::AbstractVector{<:Tuple{Real,Real}},
        color = nothing,
    )
        length(vertices) >= 3 ||
            throw(ArgumentError("PolygonAOI requires at least 3 vertices (got $(length(vertices)))."))
        verts = Tuple{Float64,Float64}[(Float64(x), Float64(y)) for (x, y) in vertices]
        new(String(name), verts, color)
    end
end
PolygonAOI(name, vertices; color = nothing) = PolygonAOI(name, vertices, color)

"""Point-in-polygon using the ray casting algorithm."""
function in_aoi(aoi::PolygonAOI, x::Real, y::Real)
    verts = aoi.vertices
    n = length(verts)
    n < 3 && return false
    inside = false
    j = n
    for i = 1:n
        xi, yi = verts[i]
        xj, yj = verts[j]
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

"""
    DynamicAOI(name, windows; color = nothing)

Time-varying Area of Interest defined by one or more `(t_start_ms, t_end_ms, aoi)`
windows in trial-relative milliseconds.

At timestamp `t`, `in_aoi(daoi, x, y, t)` returns `true` when `t_start_ms <= t <= t_end_ms`
and `in_aoi(aoi, x, y, t)` holds for at least one window. When evaluated without a
timestamp (`in_aoi(daoi, x, y)`), tests the spatial union across all windows.

```julia
moving = DynamicAOI("Target", [
    (0.0, 500.0, RectAOI("early", 300, 400, 120, 120)),
    (500.0, 1000.0, RectAOI("late", 700, 400, 120, 120)),
])
in_aoi(moving, 300, 400, 250.0)  # true
in_aoi(moving, 300, 400, 750.0)  # false
```
"""
struct DynamicAOI{A<:AOI} <: AOI
    name::String
    windows::Vector{Tuple{Float64,Float64,A}}
    color::Any

    function DynamicAOI{A}(
        name::AbstractString,
        windows::AbstractVector,
        color = nothing,
    ) where {A<:AOI}
        isempty(windows) &&
            throw(ArgumentError("DynamicAOI requires at least one (t_start, t_end, aoi) window."))
        wins = Vector{Tuple{Float64,Float64,A}}(undef, length(windows))
        for (idx, w) in enumerate(windows)
            (w isa Tuple && length(w) == 3 && w[1] isa Real && w[2] isa Real && w[3] isa A) ||
                throw(ArgumentError("Each DynamicAOI window must be a (t_start::Real, t_end::Real, aoi::AOI) tuple."))
            t0 = Float64(w[1])
            t1 = Float64(w[2])
            (isfinite(t0) && isfinite(t1) && t0 <= t1) ||
                throw(ArgumentError("DynamicAOI window bounds must be finite with t_start <= t_end (got ($t0, $t1))."))
            wins[idx] = (t0, t1, w[3])
        end
        new{A}(String(name), wins, color)
    end
end

function DynamicAOI(
    name::AbstractString,
    windows::AbstractVector,
    color = nothing,
)
    isempty(windows) &&
        throw(ArgumentError("DynamicAOI requires at least one (t_start, t_end, aoi) window."))
    first_w = first(windows)
    (first_w isa Tuple && length(first_w) == 3 && first_w[3] isa AOI) ||
        throw(ArgumentError("Each DynamicAOI window must be a (t_start::Real, t_end::Real, aoi::AOI) tuple."))
    T = typeof(first_w[3])
    for w in windows
        (w isa Tuple && length(w) == 3 && w[3] isa AOI) ||
            throw(ArgumentError("Each DynamicAOI window must be a (t_start::Real, t_end::Real, aoi::AOI) tuple."))
        T = typejoin(T, typeof(w[3]))
    end
    A = T <: AOI ? T : AOI
    return DynamicAOI{A}(name, windows, color)
end
DynamicAOI(name, windows; color = nothing) = DynamicAOI(name, windows, color)

function in_aoi(aoi::DynamicAOI, x::Real, y::Real, t::Real)
    isnan(t) && return false
    tf = Float64(t)
    @inbounds for w in aoi.windows
        if w[1] <= tf <= w[2] && in_aoi(w[3], x, y, tf)
            return true
        end
    end
    return false
end

function in_aoi(aoi::DynamicAOI, x::Real, y::Real)
    @inbounds for w in aoi.windows
        in_aoi(w[3], x, y) && return true
    end
    return false
end

function _in_dynamic_aoi_interval(
    aoi::DynamicAOI,
    x::Float64,
    y::Float64,
    t0::Float64,
    t1::Float64,
)::Bool
    isnan(t0) && return false
    hi = isnan(t1) ? t0 : max(t0, t1)
    @inbounds for w in aoi.windows
        if w[2] >= t0 && w[1] <= hi
            t_probe = clamp(t0, w[1], w[2])
            in_aoi(w[3], x, y, t_probe) && return true
        end
    end
    return false
end

Base.show(io::IO, a::RectAOI) =
    print(io, "RectAOI(\"$(a.name)\", $(a.cx), $(a.cy), $(a.width)x$(a.height))")
Base.show(io::IO, a::CircleAOI) =
    print(io, "CircleAOI(\"$(a.name)\", $(a.cx), $(a.cy), r=$(a.radius))")
Base.show(io::IO, a::EllipseAOI) =
    print(io, "EllipseAOI(\"$(a.name)\", $(a.cx), $(a.cy), $(a.rx)×$(a.ry))")
Base.show(io::IO, a::PolygonAOI) =
    print(io, "PolygonAOI(\"$(a.name)\", $(length(a.vertices)) vertices)")
Base.show(io::IO, a::DynamicAOI) =
    print(io, "DynamicAOI(\"$(a.name)\", $(length(a.windows)) windows)")


@inline function _same_event_run(
    times::AbstractVector{<:Real},
    part_col::Union{Nothing,AbstractVector},
    i::Int,
    j::Int,
)::Bool
    Float64(@inbounds times[j]) < Float64(@inbounds times[j-1]) && return false
    if !isnothing(part_col)
        pi = @inbounds part_col[i]
        pj = @inbounds part_col[j]
        (pj === pi || isequal(pj, pi)) || return false
    end
    return true
end

@inline function _is_clean_event_run(
    times::AbstractVector{<:Real},
    part_col::Union{Nothing,AbstractVector},
    i::Int,
    j_end::Int,
    sample_period_ms::Float64,
)::Bool
    if !isnothing(part_col)
        pi = @inbounds part_col[i]
        pe = @inbounds part_col[j_end]
        (pe === pi || isequal(pe, pi)) || return false
    end
    i == j_end && return true
    dt = Float64(@inbounds times[j_end]) - Float64(@inbounds times[i])
    exp_dt = (j_end - i) * sample_period_ms
    return dt >= 0.0 && abs(dt - exp_dt) <= 0.5 * sample_period_ms + 1e-6
end

@inline function _next_event_run_end(
    mask::AbstractVector{Bool},
    times::AbstractVector{<:Real},
    part_col::Union{Nothing,AbstractVector},
    sample_period_ms::Float64,
    i::Int,
    j_raw::Int,
)::Int
    j_end = j_raw - 1
    _is_clean_event_run(times, part_col, i, j_end, sample_period_ms) && return j_raw
    j = i + 1
    @inbounds while j < j_raw && _same_event_run(times, part_col, i, j)
        j += 1
    end
    return j
end

function _count_event_runs(
    mask::AbstractVector{Bool},
    times::AbstractVector{<:Real},
    part_col::Union{Nothing,AbstractVector},
    sample_period_ms::Float64,
)::Int
    n = length(mask)
    cnt = 0
    i = 1
    @inbounds while i <= n
        if mask[i]
            j_raw = i + 1
            while j_raw <= n && mask[j_raw]
                j_raw += 1
            end
            while i < j_raw
                i = _next_event_run_end(mask, times, part_col, sample_period_ms, i, j_raw)
                cnt += 1
            end
        else
            i += 1
        end
    end
    return cnt
end

@inline function _safe_event_dur(
    dur_col::Union{Nothing,AbstractVector{<:Real}},
    idx::Int,
    t_start::Float64,
    t_end::Float64,
    sample_period_ms::Float64,
)::Int32
    if !isnothing(dur_col)
        d = @inbounds dur_col[idx]
        if d > 0 && isfinite(d) && d <= Float64(typemax(Int32))
            return round(Int32, d)
        end
    end
    raw = (t_end - t_start) + sample_period_ms
    (!isfinite(raw) || raw < 0.0) && return Int32(0)
    return round(Int32, min(raw, Float64(typemax(Int32))))
end

function _extract_fixations_kernel(
    mask::AbstractVector{Bool},
    times::AbstractVector{<:Real},
    sample_period_ms::Float64,
    dur_col::Union{Nothing,AbstractVector{<:Real}},
    gavx_col::Union{Nothing,AbstractVector{<:Real}},
    gavy_col::Union{Nothing,AbstractVector{<:Real}},
    ava_col::Union{Nothing,AbstractVector{<:Real}},
    part_col::Union{Nothing,AbstractVector} = nothing,
    trial_col::Union{Nothing,AbstractVector} = nothing,
    include_groups::Bool = false,
)
    n = length(mask)
    m = _count_event_runs(mask, times, part_col, sample_period_ms)
    sttime = Vector{Float64}(undef, m)
    entime = Vector{Float64}(undef, m)
    dur = Vector{Int32}(undef, m)
    gavx = isnothing(gavx_col) ? nothing : Vector{Float64}(undef, m)
    gavy = isnothing(gavy_col) ? nothing : Vector{Float64}(undef, m)
    ava = isnothing(ava_col) ? nothing : Vector{Float64}(undef, m)
    p_out = (include_groups && !isnothing(part_col)) ? similar(part_col, m) : nothing
    tr_out = (include_groups && !isnothing(trial_col)) ? similar(trial_col, m) : nothing

    k = 0
    i = 1
    @inbounds while i <= n
        if mask[i]
            j_raw = i + 1
            while j_raw <= n && mask[j_raw]
                j_raw += 1
            end
            while i < j_raw
                j = _next_event_run_end(mask, times, part_col, sample_period_ms, i, j_raw)
                k += 1
                t_start = Float64(times[i])
                t_end = Float64(times[j-1])
                sttime[k] = t_start
                entime[k] = t_end
                dur[k] = _safe_event_dur(dur_col, i, t_start, t_end, sample_period_ms)
                !isnothing(gavx) && (gavx[k] = Float64(gavx_col[i]))
                !isnothing(gavy) && (gavy[k] = Float64(gavy_col[i]))
                !isnothing(ava) && (ava[k] = Float64(ava_col[i]))
                !isnothing(p_out) && (p_out[k] = part_col[i])
                !isnothing(tr_out) && (tr_out[k] = trial_col[i])
                i = j
            end
        else
            i += 1
        end
    end

    result = DataFrame(sttime = sttime, entime = entime, duration = dur; copycols = false)
    if include_groups
        !isnothing(tr_out) && insertcols!(result, 1, :trial => tr_out; copycols = false)
        !isnothing(p_out) && insertcols!(result, 1, :participant => p_out; copycols = false)
    end
    !isnothing(gavx) && (result[!, :gavx] = gavx)
    !isnothing(gavy) && (result[!, :gavy] = gavy)
    !isnothing(ava) && (result[!, :ava] = ava)
    return result
end

"""
    fixations(ed::EyeData; prefix=nothing, selection=nothing, include_groups=false) -> DataFrame

Reconstruct a fixations DataFrame by extracting contiguous blocks from the `in_fix` column
(or `[prefix]_in_fix` if specified). Breaks runs across participant boundaries and backward
timestamp jumps; set `include_groups=true` to prepend `:participant` and `:trial` columns.
"""
function fixations(
    ed::EyeData;
    prefix::Union{Nothing,Symbol} = nothing,
    selection = nothing,
    include_groups::Bool = false,
)
    col(name) = isnothing(prefix) ? name : Symbol(prefix, :_, name)
    df = isnothing(selection) ? ed.df : _apply_selection_view(ed, selection)
    mask_col = col(:in_fix)
    !hasproperty(df, mask_col) && return DataFrame()

    c_dur = col(:fix_dur)
    c_gx = col(:fix_gavx)
    c_gy = col(:fix_gavy)
    c_ava = col(:fix_ava)
    sample_period_ms = ed.sample_rate > 0 ? 1000.0 / ed.sample_rate : 1.0

    return _extract_fixations_kernel(
        df[!, mask_col],
        df[!, :time],
        sample_period_ms,
        hasproperty(df, c_dur) ? df[!, c_dur] : nothing,
        hasproperty(df, c_gx) ? df[!, c_gx] : nothing,
        hasproperty(df, c_gy) ? df[!, c_gy] : nothing,
        hasproperty(df, c_ava) ? df[!, c_ava] : nothing,
        hasproperty(df, :participant) ? df[!, :participant] : nothing,
        hasproperty(df, :trial) ? df[!, :trial] : nothing,
        include_groups,
    )
end

function _extract_saccades_kernel(
    mask::AbstractVector{Bool},
    times::AbstractVector{<:Real},
    sample_period_ms::Float64,
    dur_col::Union{Nothing,AbstractVector{<:Real}},
    gstx_col::Union{Nothing,AbstractVector{<:Real}},
    gsty_col::Union{Nothing,AbstractVector{<:Real}},
    genx_col::Union{Nothing,AbstractVector{<:Real}},
    geny_col::Union{Nothing,AbstractVector{<:Real}},
    ampl_col::Union{Nothing,AbstractVector{<:Real}},
    pvel_col::Union{Nothing,AbstractVector{<:Real}},
    part_col::Union{Nothing,AbstractVector} = nothing,
    trial_col::Union{Nothing,AbstractVector} = nothing,
    include_groups::Bool = false,
)
    n = length(mask)
    m = _count_event_runs(mask, times, part_col, sample_period_ms)
    sttime = Vector{Float64}(undef, m)
    entime = Vector{Float64}(undef, m)
    dur = Vector{Int32}(undef, m)
    gstx = isnothing(gstx_col) ? nothing : Vector{Float64}(undef, m)
    gsty = isnothing(gsty_col) ? nothing : Vector{Float64}(undef, m)
    genx = isnothing(genx_col) ? nothing : Vector{Float64}(undef, m)
    geny = isnothing(geny_col) ? nothing : Vector{Float64}(undef, m)
    ampl = isnothing(ampl_col) ? nothing : Vector{Float64}(undef, m)
    pvel = isnothing(pvel_col) ? nothing : Vector{Float64}(undef, m)
    p_out = (include_groups && !isnothing(part_col)) ? similar(part_col, m) : nothing
    tr_out = (include_groups && !isnothing(trial_col)) ? similar(trial_col, m) : nothing

    k = 0
    i = 1
    @inbounds while i <= n
        if mask[i]
            j_raw = i + 1
            while j_raw <= n && mask[j_raw]
                j_raw += 1
            end
            while i < j_raw
                j = _next_event_run_end(mask, times, part_col, sample_period_ms, i, j_raw)
                k += 1
                t_start = Float64(times[i])
                t_end = Float64(times[j-1])
                sttime[k] = t_start
                entime[k] = t_end
                dur[k] = _safe_event_dur(dur_col, i, t_start, t_end, sample_period_ms)
                !isnothing(gstx) && (gstx[k] = Float64(gstx_col[i]))
                !isnothing(gsty) && (gsty[k] = Float64(gsty_col[i]))
                !isnothing(genx) && (genx[k] = Float64(genx_col[i]))
                !isnothing(geny) && (geny[k] = Float64(geny_col[i]))
                !isnothing(ampl) && (ampl[k] = Float64(ampl_col[i]))
                !isnothing(pvel) && (pvel[k] = Float64(pvel_col[i]))
                !isnothing(p_out) && (p_out[k] = part_col[i])
                !isnothing(tr_out) && (tr_out[k] = trial_col[i])
                i = j
            end
        else
            i += 1
        end
    end

    result = DataFrame(sttime = sttime, entime = entime, duration = dur; copycols = false)
    if include_groups
        !isnothing(tr_out) && insertcols!(result, 1, :trial => tr_out; copycols = false)
        !isnothing(p_out) && insertcols!(result, 1, :participant => p_out; copycols = false)
    end
    !isnothing(gstx) && (result[!, :gstx] = gstx)
    !isnothing(gsty) && (result[!, :gsty] = gsty)
    !isnothing(genx) && (result[!, :genx] = genx)
    !isnothing(geny) && (result[!, :geny] = geny)
    !isnothing(ampl) && (result[!, :ampl] = ampl)
    !isnothing(pvel) && (result[!, :pvel] = pvel)
    return result
end

"""
    saccades(ed::EyeData; prefix=nothing, selection=nothing, include_groups=false) -> DataFrame

Reconstruct a saccades DataFrame by extracting contiguous blocks from the `in_sacc` column
(or `[prefix]_in_sacc` if specified).
"""
function saccades(
    ed::EyeData;
    prefix::Union{Nothing,Symbol} = nothing,
    selection = nothing,
    include_groups::Bool = false,
)
    col(name) = isnothing(prefix) ? name : Symbol(prefix, :_, name)
    df = isnothing(selection) ? ed.df : _apply_selection_view(ed, selection)
    mask_col = col(:in_sacc)
    !hasproperty(df, mask_col) && return DataFrame()

    c_dur = col(:sacc_dur)
    c_gstx = col(:sacc_gstx)
    c_gsty = col(:sacc_gsty)
    c_genx = col(:sacc_genx)
    c_geny = col(:sacc_geny)
    c_ampl = col(:sacc_ampl)
    c_pvel = col(:sacc_pvel)
    sample_period_ms = ed.sample_rate > 0 ? 1000.0 / ed.sample_rate : 1.0

    return _extract_saccades_kernel(
        df[!, mask_col],
        df[!, :time],
        sample_period_ms,
        hasproperty(df, c_dur) ? df[!, c_dur] : nothing,
        hasproperty(df, c_gstx) ? df[!, c_gstx] : nothing,
        hasproperty(df, c_gsty) ? df[!, c_gsty] : nothing,
        hasproperty(df, c_genx) ? df[!, c_genx] : nothing,
        hasproperty(df, c_geny) ? df[!, c_geny] : nothing,
        hasproperty(df, c_ampl) ? df[!, c_ampl] : nothing,
        hasproperty(df, c_pvel) ? df[!, c_pvel] : nothing,
        hasproperty(df, :participant) ? df[!, :participant] : nothing,
        hasproperty(df, :trial) ? df[!, :trial] : nothing,
        include_groups,
    )
end

function _extract_blinks_kernel(
    mask::AbstractVector{Bool},
    times::AbstractVector{<:Real},
    sample_period_ms::Float64,
    dur_col::Union{Nothing,AbstractVector{<:Real}},
    part_col::Union{Nothing,AbstractVector} = nothing,
    trial_col::Union{Nothing,AbstractVector} = nothing,
    include_groups::Bool = false,
)
    n = length(mask)
    m = _count_event_runs(mask, times, part_col, sample_period_ms)
    sttime = Vector{Float64}(undef, m)
    entime = Vector{Float64}(undef, m)
    dur = Vector{Int32}(undef, m)
    p_out = (include_groups && !isnothing(part_col)) ? similar(part_col, m) : nothing
    tr_out = (include_groups && !isnothing(trial_col)) ? similar(trial_col, m) : nothing

    k = 0
    i = 1
    @inbounds while i <= n
        if mask[i]
            j_raw = i + 1
            while j_raw <= n && mask[j_raw]
                j_raw += 1
            end
            while i < j_raw
                j = _next_event_run_end(mask, times, part_col, sample_period_ms, i, j_raw)
                k += 1
                t_start = Float64(times[i])
                t_end = Float64(times[j-1])
                sttime[k] = t_start
                entime[k] = t_end
                dur[k] = _safe_event_dur(dur_col, i, t_start, t_end, sample_period_ms)
                !isnothing(p_out) && (p_out[k] = part_col[i])
                !isnothing(tr_out) && (tr_out[k] = trial_col[i])
                i = j
            end
        else
            i += 1
        end
    end

    result = DataFrame(sttime = sttime, entime = entime, duration = dur; copycols = false)
    if include_groups
        !isnothing(tr_out) && insertcols!(result, 1, :trial => tr_out; copycols = false)
        !isnothing(p_out) && insertcols!(result, 1, :participant => p_out; copycols = false)
    end
    return result
end

"""
    blinks(ed::EyeData; prefix=nothing, selection=nothing, include_groups=false) -> DataFrame

Reconstruct a blinks DataFrame by extracting contiguous blocks from the `in_blink` column.
"""
function blinks(
    ed::EyeData;
    prefix::Union{Nothing,Symbol} = nothing,
    selection = nothing,
    include_groups::Bool = false,
)
    col(name) = isnothing(prefix) ? name : Symbol(prefix, :_, name)
    df = isnothing(selection) ? ed.df : _apply_selection_view(ed, selection)
    mask_col = col(:in_blink)
    !hasproperty(df, mask_col) && return DataFrame()

    c_dur = col(:blink_dur)
    sample_period_ms = ed.sample_rate > 0 ? 1000.0 / ed.sample_rate : 1.0

    return _extract_blinks_kernel(
        df[!, mask_col],
        df[!, :time],
        sample_period_ms,
        hasproperty(df, c_dur) ? df[!, c_dur] : nothing,
        hasproperty(df, :participant) ? df[!, :participant] : nothing,
        hasproperty(df, :trial) ? df[!, :trial] : nothing,
        include_groups,
    )
end

function _collect_messages_kernel(
    times::AbstractVector{<:Real},
    msgs::AbstractVector,
)
    result_time = Float64[]
    result_msg = String[]
    @inbounds for i in eachindex(times, msgs)
        m_val = msgs[i]
        (ismissing(m_val) || isempty(m_val)) && continue
        t = Float64(times[i])
        for part in eachsplit(m_val, "; ")
            s = strip(part)
            isempty(s) && continue
            push!(result_time, t)
            push!(result_msg, String(s))
        end
    end
    return result_time, result_msg
end

"""
    messages(ed::EyeData; summary=false, selection=nothing) -> DataFrame

Extract message events from the `EyeData` sample timeline.

Returns a `DataFrame` with columns `time` and `message` for each non-empty
message entry. Messages that were joined at the same timestamp (separated by
`"; "`) are split back into individual rows.

With `summary=true`, returns a frequency table of unique messages sorted by count,
grouping near-identical messages (e.g. "TRIALID 1"…"TRIALID 894" → "TRIALID").

# Example
```julia
ed = read_et_data("recording.edf")
messages(ed)               # all individual messages
messages(ed; summary=true) # frequency table
```
"""
function messages(ed::EyeData; summary::Bool = false, selection = nothing)
    df = isnothing(selection) ? ed.df : _apply_selection_view(ed, selection)
    !hasproperty(df, :message) && return DataFrame()

    result_time, result_msg = _collect_messages_kernel(df[!, :time], df[!, :message])
    isempty(result_msg) && return DataFrame()
    msg = DataFrame(time = result_time, message = result_msg; copycols = false)
    !summary && return msg

    nrow(msg) == 0 && return DataFrame(message = String[], count = Int[])

    msg_counts = Dict{String,Int}()
    for m in msg.message
        msg_counts[m] = get(msg_counts, m, 0) + 1
    end

    # Group by first word to collapse "TRIALID 1", "TRIALID 2" etc.
    word_counts = Dict{String,Int}()
    word_examples = Dict{String,String}()
    for (m, c) in msg_counts
        w = split(m; limit = 2)[1]
        word_counts[w] = get(word_counts, w, 0) + c
        if !haskey(word_examples, w) || length(m) > length(word_examples[w])
            word_examples[w] = m
        end
    end

    # If grouping by first word reduced count a lot, use grouped view
    if length(word_counts) < length(msg_counts) * 0.5
        rows =
            [(message = w, example = word_examples[w], count = c) for (w, c) in word_counts]
    else
        rows = [(message = m, example = m, count = c) for (m, c) in msg_counts]
    end

    result = DataFrame(rows)
    sort!(result, :count; rev = true)
    return result
end

@inline _prefixed_sym(prefix::Union{Nothing,Symbol}, base::Symbol) =
    isnothing(prefix) ? base : Symbol(prefix, :_, base)

const _BASE_SAMPLE_COLS = Set{Symbol}([
    :time,
    :time_rel,
    :participant,
    :message,
    :gx,
    :gy,
    :pa,
    :gxR,
    :gyR,
    :paR,
    :gxL,
    :gyL,
    :paL,
    :pupxL,
    :pupyL,
    :pupxR,
    :pupyR,
    :diaxL,
    :diayL,
    :crxL,
    :cryL,
    :diaxR,
    :diayR,
    :crxR,
    :cryR,
    :flags,
    :input,
    :status,
    :in_fix,
    :fix_gavx,
    :fix_gavy,
    :fix_ava,
    :fix_dur,
    :in_sacc,
    :sacc_gstx,
    :sacc_gsty,
    :sacc_genx,
    :sacc_geny,
    :sacc_dur,
    :sacc_ampl,
    :sacc_pvel,
    :in_blink,
    :blink_dur,
    :in_pso,
    :pso_dur,
    :in_msacc,
    :msacc_dx,
    :msacc_dy,
    :msacc_ampl,
    :msacc_pvel,
    :msacc_dur,
])

const _EVENT_COL_SUFFIXES = (
    "_in_fix",
    "_fix_gavx",
    "_fix_gavy",
    "_fix_ava",
    "_fix_dur",
    "_in_sacc",
    "_sacc_gstx",
    "_sacc_gsty",
    "_sacc_genx",
    "_sacc_geny",
    "_sacc_dur",
    "_sacc_ampl",
    "_sacc_pvel",
    "_in_blink",
    "_blink_dur",
    "_in_pso",
    "_pso_dur",
    "_in_msacc",
    "_msacc_dx",
    "_msacc_dy",
    "_msacc_ampl",
    "_msacc_pvel",
    "_msacc_dur",
)

function _is_sample_or_event_col(c::Symbol)
    c in _BASE_SAMPLE_COLS && return true
    s = String(c)
    for suf in _EVENT_COL_SUFFIXES
        endswith(s, suf) && return true
    end
    return false
end

function _has_multiple_participants_vec(pcol::AbstractVector)::Bool
    first_idx = 0
    @inbounds for i in eachindex(pcol)
        v = pcol[i]
        (ismissing(v) || isempty(v)) && continue
        if first_idx == 0
            first_idx = i
        else
            fv = pcol[first_idx]
            if !(v === fv || v == fv)
                return true
            end
        end
    end
    return false
end

function _has_multiple_participants(df::AbstractDataFrame)::Bool
    hasproperty(df, :participant) || return false
    return _has_multiple_participants_vec(df[!, :participant])
end

function _gather_first_col(src::AbstractVector, first_rows::Vector{Int})
    m = length(first_rows)
    out = similar(src, m)
    @inbounds for i = 1:m
        out[i] = src[first_rows[i]]
    end
    return out
end

"""
    variables(ed::EyeData) -> DataFrame

Extract the trial-level variables joined to `EyeData.df`.
Returns a `DataFrame` with one row per valid trial (or per `(participant, trial)`
when multiple participants are present).
"""
function variables(ed::EyeData)
    df = ed.df
    !hasproperty(df, :trial) && return DataFrame()

    multi_part = _has_multiple_participants(df)
    keep_cols = Symbol[c for c in propertynames(df) if !_is_sample_or_event_col(c)]
    if multi_part
        pushfirst!(keep_cols, :participant)
        gcols = [:participant, :trial]
    else
        gcols = [:trial]
    end
    gd = groupby(df, gcols; skipmissing = true)
    ng = length(gd)
    first_rows = Vector{Int}(undef, ng)
    @inbounds for i = 1:ng
        first_rows[i] = parentindices(gd[i])[1][1]
    end
    pairs_out = Pair{Symbol,Any}[c => _gather_first_col(df[!, c], first_rows) for c in keep_cols]
    return DataFrame(pairs_out; copycols = false)
end

"""
    AbstractEyeFunMedia

Abstract supertype for stimulus media descriptors rendered by `plot_databrowser` and `plot_stimuli`.
"""
abstract type AbstractEyeFunMedia end

"""
    ImageMedia <: AbstractEyeFunMedia

Visual stimulus descriptor storing an image matrix or file path, optional center `position`,
bounding box `bbox`, onset/offset times in ms, and drawing `z_index`.
"""
Base.@kwdef struct ImageMedia <: AbstractEyeFunMedia
    content::Any                                       # Image Matrix, or String path
    position::Union{Nothing,NTuple{2,Float64}} = nothing # Center (cx, cy)
    bbox::Union{Nothing,NTuple{4,Float64}} = nothing     # (xmin, xmax, ymin, ymax)
    time_on::Union{Nothing,Float64} = nothing         # Onset time in ms
    time_off::Union{Nothing,Float64} = nothing        # Offset time in ms
    z_index::Int = 0                                   # Order of drawing
end

"""
    AudioMedia <: AbstractEyeFunMedia

Audio stimulus descriptor storing a waveform array or `.wav` file path and optional onset time `time_on` in ms.
"""
Base.@kwdef struct AudioMedia <: AbstractEyeFunMedia
    content::Any                                       # Audio waveform or String path to wav
    time_on::Union{Nothing,Float64} = nothing
end

"""
    TextMedia <: AbstractEyeFunMedia

Text stimulus descriptor storing a string `content`, optional screen `position`, onset/offset times in ms, `color`, and `fontsize`.
"""
Base.@kwdef struct TextMedia <: AbstractEyeFunMedia
    content::String
    position::Union{Nothing,NTuple{2,Float64}} = nothing
    time_on::Union{Nothing,Float64} = nothing
    time_off::Union{Nothing,Float64} = nothing
    color::Symbol = :black
    fontsize::Float64 = 16.0
end

const SaccadeInfo = @NamedTuple{
    x1::Float64,
    y1::Float64,
    x2::Float64,
    y2::Float64,
    time_idx::Int,
    angle::Float64,
    amplitude::Float64,
}

const FixationInfo =
    @NamedTuple{x::Float64, y::Float64, dur::Float64, time_start::Int, time_end::Int}
