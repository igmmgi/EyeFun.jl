# ── Coordinate Utilities ───────────────────────────────────────────────────── #

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

# Example
```julia
x_deg, y_deg = px_to_deg(df, 640, 480)   # center → (0.0, 0.0) on 1280×960
x_deg, y_deg = px_to_deg(df, 700, 480)   # ~1.3° right of center
```
"""
function px_to_deg(ed::EyeData, x_px::Real, y_px::Real)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0
    return ((x_px - cx) / ppd, (y_px - cy) / ppd)
end

"""
    deg_to_px(df::EyeData, x_deg, y_deg) -> (x_px, y_px)

Convert degrees of visual angle (relative to screen center) back to pixel coordinates.

# Example
```julia
x_px, y_px = deg_to_px(df, 0.0, 0.0)  # → screen center
```
"""
function deg_to_px(ed::EyeData, x_deg::Real, y_deg::Real)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0
    return (cx + x_deg * ppd, cy + y_deg * ppd)
end

"""
    to_center_coords!(df::EyeData; eye=:auto)

Convert gaze coordinates from pixels to degrees of visual angle relative to
screen center. Modifies the DataFrame in-place.

After conversion, `(0, 0)` = screen center, units = degrees.

# Example
```julia
to_center_coords!(df)
# df.df.gxL is now in degrees from center
```
"""
function to_center_coords!(ed::EyeData; eye::Symbol = :auto)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0

    # Convert all available X coordinates
    for col in (:gxL, :gxR, :fix_gavx, :sacc_gstx, :sacc_genx)
        if hasproperty(ed.df, col)
            ed.df[!, col] .= (ed.df[!, col] .- cx) ./ ppd
        end
    end

    # Convert all available Y coordinates
    for col in (:gyL, :gyR, :fix_gavy, :sacc_gsty, :sacc_geny)
        if hasproperty(ed.df, col)
            ed.df[!, col] .= (ed.df[!, col] .- cy) ./ ppd
        end
    end

    return ed
end
