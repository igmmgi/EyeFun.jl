"""
    load_image(path::String)

Loads an image from the given path. Uses the vendored `Makie.FileIO.load`
for PNG, JPG, and BMP, and delegates to `read_gif` for GIF files.
"""
function load_image(path::String)
    ext = lowercase(lstrip(splitext(path)[2], '.'))
    if ext == "gif"
        return read_gif(path)
    else
        return Makie.FileIO.load(path)
    end
end
