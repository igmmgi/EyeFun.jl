const _IMAGE_CACHE = Dict{String,Any}()

"""
    load_image(path::String; use_cache::Bool=true)

Loads an image from the given path. Automatically caches loaded images in memory.
Uses the vendored `Makie.FileIO.load` for PNG, JPG, and BMP, and delegates to `read_gif` for GIF files.
"""
function load_image(path::String; use_cache::Bool=true)
    if use_cache
        res = get!(_IMAGE_CACHE, path) do
            _load_image_from_disk(path)
        end
        return copy(res)
    else
        return _load_image_from_disk(path)
    end
end

"""
    image_size(path::String)

Returns the `(height, width)` of the image. Queries the internal cache if the image is already loaded, 
otherwise it performs a fast binary header read to determine the dimensions without loading the 
full image data into memory.
"""
function image_size(path::String)
    if haskey(_IMAGE_CACHE, path)
        return size(_IMAGE_CACHE[path])
    end
    return _image_size_from_disk(path)
end

function _image_size_from_disk(path::String)
    open(path, "r") do io
        magic = read(io, 4)
        if magic[1:2] == b"BM"
            seek(io, 18)
            width = Int(read(io, Int32))
            height = Int(read(io, Int32))
            return abs(height), abs(width)
        elseif magic[1:3] == b"GIF"
            seek(io, 6)
            width = Int(read(io, UInt16))
            height = Int(read(io, UInt16))
            return height, width
        elseif magic == b"\x89PNG"
            seek(io, 16)
            width = Int(ntoh(read(io, UInt32)))
            height = Int(ntoh(read(io, UInt32)))
            return height, width
        elseif magic[1:2] == b"\xFF\xD8" # JPEG
            seek(io, 2)
            while !eof(io)
                b = read(io, UInt8)
                if b == 0xFF
                    marker = read(io, UInt8)
                    while marker == 0xFF
                        marker = read(io, UInt8)
                    end
                    if marker >= 0xC0 && marker <= 0xC3
                        skip(io, 3)
                        height = Int(ntoh(read(io, UInt16)))
                        width = Int(ntoh(read(io, UInt16)))
                        return height, width
                    else
                        len = ntoh(read(io, UInt16))
                        skip(io, len - 2)
                    end
                end
            end
        end
        img = _load_image_from_disk(path)
        return size(img)
    end
end

function _load_image_from_disk(path::String)
    magic = open(path, "r") do io
        read(io, 4)
    end

    if magic[1:2] == b"BM"
        return read_bmp(path)
    elseif magic[1:3] == b"GIF"
        return read_gif(path)
    else
        return Makie.FileIO.load(path)
    end
end
