# ── Coordinate Utilities ───────────────────────────────────────────────────── #

"""
    pixels_per_degree(ed::EyeData) -> Float64

Compute the number of pixels per degree of visual angle from recording metadata.

# Example
```julia
ppd = pixels_per_degree(ed)  # e.g. 45.3 px/°
```
"""
function pixels_per_degree(ed::EyeData)
    screen_width_px = ed.screen_res[1]
    fov_deg = 2.0 * atand(ed.screen_width_cm / 2.0 / ed.viewing_distance_cm)
    return screen_width_px / fov_deg
end

"""
    px_to_deg(ed::EyeData, x_px, y_px) -> (x_deg, y_deg)

Convert pixel coordinates to degrees of visual angle relative to screen center.

Returns `(0, 0)` at screen center, positive X = right, positive Y = down.

# Example
```julia
x_deg, y_deg = px_to_deg(ed, 640, 480)   # center → (0.0, 0.0) on 1280×960
x_deg, y_deg = px_to_deg(ed, 700, 480)   # ~1.3° right of center
```
"""
function px_to_deg(ed::EyeData, x_px::Real, y_px::Real)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0
    return ((x_px - cx) / ppd, (y_px - cy) / ppd)
end

"""
    deg_to_px(ed::EyeData, x_deg, y_deg) -> (x_px, y_px)

Convert degrees of visual angle (relative to screen center) back to pixel coordinates.

# Example
```julia
x_px, y_px = deg_to_px(ed, 0.0, 0.0)  # → screen center
```
"""
function deg_to_px(ed::EyeData, x_deg::Real, y_deg::Real)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0
    return (cx + x_deg * ppd, cy + y_deg * ppd)
end

"""
    to_center_coords!(ed::EyeData; eye=:auto)

Convert gaze coordinates from pixels to degrees of visual angle relative to
screen center. Modifies the DataFrame in-place.

After conversion, `(0, 0)` = screen center, units = degrees.

# Example
```julia
to_center_coords!(ed)
# ed.df.gxL is now in degrees from center
```
"""
function to_center_coords!(ed::EyeData; eye::Symbol = :auto)
    ppd = pixels_per_degree(ed)
    cx, cy = ed.screen_res[1] / 2.0, ed.screen_res[2] / 2.0

    eye = _resolve_eye(ed, eye)

    if eye == :left || (hasproperty(ed.df, :gxL) && any(!isnan, ed.df.gxL))
        ed.df.gxL .= (ed.df.gxL .- cx) ./ ppd
        ed.df.gyL .= (ed.df.gyL .- cy) ./ ppd
    end
    if eye == :right || (hasproperty(ed.df, :gxR) && any(!isnan, ed.df.gxR))
        ed.df.gxR .= (ed.df.gxR .- cx) ./ ppd
        ed.df.gyR .= (ed.df.gyR .- cy) ./ ppd
    end

    # Convert fixation centers if present
    if hasproperty(ed.df, :fix_gavx)
        ed.df.fix_gavx .= (ed.df.fix_gavx .- cx) ./ ppd
        ed.df.fix_gavy .= (ed.df.fix_gavy .- cy) ./ ppd
    end

    # Convert saccade endpoints if present
    if hasproperty(ed.df, :sacc_gstx)
        ed.df.sacc_gstx .= (ed.df.sacc_gstx .- cx) ./ ppd
        ed.df.sacc_gsty .= (ed.df.sacc_gsty .- cy) ./ ppd
        ed.df.sacc_genx .= (ed.df.sacc_genx .- cx) ./ ppd
        ed.df.sacc_geny .= (ed.df.sacc_geny .- cy) ./ ppd
    end

    return ed
end
