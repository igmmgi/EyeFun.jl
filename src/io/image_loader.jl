# Internal cache to automatically prevent redundant disk reads without cluttering the user's API
const _IMAGE_CACHE = Dict{String,Any}()

"""
    load_image(path::String; use_cache::Bool=true)

Loads an image from the given path. Automatically caches loaded images in memory.
Uses the vendored `Makie.FileIO.load` for PNG, JPG, and BMP, and delegates to `read_gif` for GIF files.
"""
function load_image(path::String; use_cache::Bool = true)
    if use_cache
        # GLMakie tracks arrays by memory pointer. If the EXACT same Matrix instance is
        # fed into `image!` twice across different trials, GLMakie's texture cache can corrupt 
        # its dimensions, flattening it out to a 1D width equaling its total pixel count!
        # Returning `copy()` busts the object-identity bug while still bypassing a heavy disk reload!
        res = get!(_IMAGE_CACHE, path) do
            _load_image_from_disk(path)
        end
        return copy(res)
    else
        return _load_image_from_disk(path)
    end
end

function _load_image_from_disk(path::String)
    # Read the first 4 bytes (magic signature) to determine the TRUE file format,
    # as legacy datasets frequently mislabel JPEGs or PNGs with a .bmp extension!
    magic = open(path, "r") do io
        read(io, 4)
    end

    if magic[1:2] == b"BM"
        return read_bmp(path)
    elseif magic[1:3] == b"GIF"
        return read_gif(path)
    else
        # Fall back to FileIO, which also uses magic bytes and will correctly
        # identify and load mislabeled JPEGs and PNGs using ImageIO.jl
        return Makie.FileIO.load(path)
    end
end
