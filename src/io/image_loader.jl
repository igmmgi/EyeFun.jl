const _IMAGE_CACHE = Dict{String,Any}()
const _IMAGE_CACHE_MAX = 128

"""
    load_image(path::AbstractString; use_cache::Bool=true)

Load an image from `path`, caching loaded images in memory when `use_cache=true`.
Uses `read_bmp` for BMP files, `read_gif` for GIF files, and `Makie.FileIO.load`
for PNG, JPEG, and other formats.
"""
function load_image(path::AbstractString; use_cache::Bool = true)
    key = String(path)
    if use_cache
        if !haskey(_IMAGE_CACHE, key)
            if length(_IMAGE_CACHE) >= _IMAGE_CACHE_MAX
                delete!(_IMAGE_CACHE, first(keys(_IMAGE_CACHE)))
            end
            _IMAGE_CACHE[key] = _load_image_from_disk(key)
        end
        return copy(_IMAGE_CACHE[key])
    else
        return _load_image_from_disk(key)
    end
end

"""
    image_size(path::AbstractString)

Return `(height, width)` of the image at `path`, reading dimensions from the file
header when the image is not already cached.
"""
function image_size(path::AbstractString)
    key = String(path)
    if haskey(_IMAGE_CACHE, key)
        return size(_IMAGE_CACHE[key])
    end
    return _image_size_from_disk(key)
end

function _image_size_from_disk(path::String)
    isfile(path) || error("File not found: $path")
    fsize = filesize(path)
    fsize < 4 && error("Image file too small (< 4 bytes): $path")
    open(path, "r") do io
        magic = read(io, 4)
        if magic[1:2] == b"BM" && fsize >= 22
            seek(io, 14)
            hdr_sz = Int(ltoh(read(io, UInt32)))
            if hdr_sz == 12
                width = Int(ltoh(read(io, UInt16)))
                height = Int(ltoh(read(io, UInt16)))
                return abs(height), abs(width)
            elseif fsize >= 26
                width = Int(ltoh(read(io, Int32)))
                height = Int(ltoh(read(io, Int32)))
                return abs(height), abs(width)
            end
        elseif magic[1:3] == b"GIF" && fsize >= 10
            seek(io, 6)
            width = Int(ltoh(read(io, UInt16)))
            height = Int(ltoh(read(io, UInt16)))
            return height, width
        elseif magic == b"\x89PNG" && fsize >= 24
            seek(io, 16)
            width = Int(ntoh(read(io, UInt32)))
            height = Int(ntoh(read(io, UInt32)))
            return height, width
        elseif magic[1:2] == b"\xFF\xD8" # JPEG
            seek(io, 2)
            while !eof(io)
                b = read(io, UInt8)
                if b == 0xFF
                    eof(io) && break
                    marker = read(io, UInt8)
                    while marker == 0xFF && !eof(io)
                        marker = read(io, UInt8)
                    end
                    # Standalone markers without length bytes (TEM, RST0..RST7, SOI, EOI)
                    if marker == 0x00 || marker == 0x01 || (0xD0 <= marker <= 0xD9)
                        marker == 0xD9 && break
                        continue
                    end
                    if (0xC0 <= marker <= 0xCF) && !(marker in (0xC4, 0xC8, 0xCC))
                        (fsize - position(io)) < 7 && break
                        skip(io, 3)
                        height = Int(ntoh(read(io, UInt16)))
                        width = Int(ntoh(read(io, UInt16)))
                        return height, width
                    else
                        (fsize - position(io)) < 2 && break
                        len = Int(ntoh(read(io, UInt16)))
                        len < 2 && break
                        (fsize - position(io)) < (len - 2) && break
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

    if length(magic) >= 2 && magic[1:2] == b"BM"
        return read_bmp(path)
    elseif length(magic) >= 3 && magic[1:3] == b"GIF"
        return read_gif(path)
    else
        return Makie.FileIO.load(path)
    end
end
