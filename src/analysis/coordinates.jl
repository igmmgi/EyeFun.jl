"""
    pixels_per_degree(df::EyeData) -> Float64

Compute the number of pixels per degree of visual angle from recording metadata.

# Example
```julia
ppd = pixels_per_degree(df)  # e.g. 45.3 px/°
```
"""
function pixels_per_degree(ed::EyeData)
    screen_width_px = ed.screen_res[1]
    fov_deg = 2.0 * atand(ed.screen_width_cm / 2.0 / ed.viewing_distance_cm)
    return screen_width_px / fov_deg
end

"""
    px_to_deg(df::EyeData, x_px, y_px) -> (x_deg, y_deg)

Convert pixel coordinates to degrees of visual angle relative to screen center.

Returns `(0, 0)` at screen center, positive X = right, positive Y = down.
"""
function px_to_deg(ed::EyeData, x_px::Real, y_px::Real)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0
    return ((x_px - cx) / ppd, (y_px - cy) / ppd)
end

"""
    deg_to_px(df::EyeData, x_deg, y_deg) -> (x_px, y_px)

Convert degrees of visual angle (relative to screen center) back to pixel coordinates.
"""
function deg_to_px(ed::EyeData, x_deg::Real, y_deg::Real)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0
    return (cx + x_deg * ppd, cy + y_deg * ppd)
end

const _EVENT_COORD_X_SUFFIXES = ("_fix_gavx", "_sacc_gstx", "_sacc_genx")
const _EVENT_COORD_Y_SUFFIXES = ("_fix_gavy", "_sacc_gsty", "_sacc_geny")

@inline function _is_col_deg(df::AbstractDataFrame, col::Symbol, fallback_coords::Symbol)::Bool
    hasproperty(df, col) || return fallback_coords === :deg
    return DataFrames.colmetadata(df, col, "eyefun_coords", fallback_coords) === :deg
end

@inline function _is_col_centered(
    df::AbstractDataFrame,
    col::Symbol,
    fallback_coords::Symbol,
)::Bool
    hasproperty(df, col) || return fallback_coords in (:deg, :center_px)
    c = DataFrames.colmetadata(df, col, "eyefun_coords", fallback_coords)
    return c === :deg || c === :center_px
end

@inline function _eye_units_per_deg(ed::EyeData, eye::Symbol)::Float64
    gx_sym = _eye_columns(eye).gx
    return _is_col_deg(ed.df, gx_sym, ed.coords) ? 1.0 : pixels_per_degree(ed)
end

function _shift_scale_col!(
    col::AbstractVector{T},
    center::Float64,
    scale::Float64,
) where {T<:AbstractFloat}
    c = T(center)
    s = T(scale)
    @inbounds for i in eachindex(col)
        col[i] = (col[i] - c) * s
    end
    return nothing
end

function _convert_coord_col!(
    df::DataFrame,
    col::Symbol,
    center::Float64,
    ppd::Float64,
    target_mode::Symbol,
    fallback_coords::Symbol,
)
    hasproperty(df, col) || return nothing
    cur = DataFrames.colmetadata(df, col, "eyefun_coords", fallback_coords)
    cur === target_mode && return nothing

    shift = (cur === :deg || cur === :center_px) ? 0.0 : center
    scale = if cur === :deg && target_mode === :center_px
        ppd
    elseif target_mode === :deg
        1.0 / ppd
    else
        1.0
    end

    vec = df[!, col]
    if eltype(vec) <: AbstractFloat
        _shift_scale_col!(vec, shift, scale)
    else
        df[!, col] = Float64[ismissing(v) ? NaN : (Float64(v) - shift) * scale for v in vec]
    end
    DataFrames.colmetadata!(df, col, "eyefun_coords", target_mode; style = :note)
    return nothing
end

"""
    to_center_coords!(df::EyeData; eye=:auto, units=:deg)

Convert gaze coordinates from top-left pixels to screen-centered coordinates
(`units = :deg` for degrees of visual angle, or `units = :px` for center-referenced
pixels). Modifies the DataFrame in-place and updates coordinate metadata so
downstream functions do not shift or divide by `pixels_per_degree` a second time.

After conversion, `(0, 0)` = screen center.
When `eye = :auto` (default), all available gaze columns (`gx/gy`, `gxL/gyL`, `gxR/gyR`)
plus fixation/saccade coordinate columns (including prefixed event columns) are converted;
when `eye` is `:left`, `:right`, or `:both`, that eye's gaze columns plus event coordinate
columns are converted without double-shifting already-converted columns.
"""
function to_center_coords!(ed::EyeData; eye::Symbol = :auto, units::Symbol = :deg)
    units in (:deg, :px) ||
        throw(ArgumentError("Invalid units=:$units. Expected :deg or :px."))
    target_mode = units === :deg ? :deg : :center_px
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0
    d = ed.df
    fb = ed.coords

    if eye == :auto
        gaze_x = (:gx, :gxL, :gxR)
        gaze_y = (:gy, :gyL, :gyR)
    else
        resolved = _resolve_eye(ed, eye)
        _ensure_eye_cols!(ed, resolved)
        ecols = _eye_columns(resolved)
        gaze_x = (ecols.gx,)
        gaze_y = (ecols.gy,)
    end

    for col in gaze_x
        _convert_coord_col!(d, col, cx, ppd, target_mode, fb)
    end
    for col in gaze_y
        _convert_coord_col!(d, col, cy, ppd, target_mode, fb)
    end

    for col in (:fix_gavx, :sacc_gstx, :sacc_genx)
        _convert_coord_col!(d, col, cx, ppd, target_mode, fb)
    end
    for col in (:fix_gavy, :sacc_gsty, :sacc_geny)
        _convert_coord_col!(d, col, cy, ppd, target_mode, fb)
    end
    for col in propertynames(d)
        s = String(col)
        for suf in _EVENT_COORD_X_SUFFIXES
            if endswith(s, suf)
                _convert_coord_col!(d, col, cx, ppd, target_mode, fb)
                break
            end
        end
        for suf in _EVENT_COORD_Y_SUFFIXES
            if endswith(s, suf)
                _convert_coord_col!(d, col, cy, ppd, target_mode, fb)
                break
            end
        end
    end

    all_conv = true
    any_gaze = false
    for gc in (:gx, :gy, :gxL, :gyL, :gxR, :gyR)
        if hasproperty(d, gc)
            any_gaze = true
            if DataFrames.colmetadata(d, gc, "eyefun_coords", :px) !== target_mode
                all_conv = false
                break
            end
        end
    end
    if eye == :auto || (any_gaze && all_conv)
        ed.coords = target_mode
    end

    return ed
end
