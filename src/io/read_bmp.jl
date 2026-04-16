# I needed a small bmp file reader to avoid dependency on ImageMagick
# This code was generated with help from Gemini 3.1, and tested on some 
# bmp images I have. It is not exhaustive, but it worked for 
# my purposes at the time.

function read_bmp(path::String)
    open(path, "r") do io
        String(read(io, 2)) == "BM" || error("Not a BMP file: $path")

        skip(io, 8)
        data_offset = read(io, UInt32)

        header_size = read(io, UInt32)
        width = Int(read(io, Int32))
        height = Int(read(io, Int32))
        skip(io, 2) # Skip unused 'planes'
        bpp = read(io, UInt16)

        if !(bpp in (1, 4, 8, 24, 32))
            error(
                "Only 1, 4, 8, 24, and 32-bit uncompressed BMPs are supported (got $(bpp)-bit).",
            )
        end

        compression = read(io, UInt32)
        compression == 0 || error("Compressed BMP not supported")

        # Read Palette if indexed
        palette = Makie.RGBf[]
        if bpp <= 8
            seek(io, 14 + header_size)
            num_colors = div(data_offset - (14 + header_size), 4)
            if num_colors == 0
                num_colors = 1 << bpp
            end
            for _ = 1:num_colors
                b = read(io, UInt8) / 255.0f0
                g = read(io, UInt8) / 255.0f0
                r = read(io, UInt8) / 255.0f0
                skip(io, 1) # Reserved byte
                push!(palette, Makie.RGBf(r, g, b))
            end
        end

        seek(io, data_offset)

        row_bytes = ceil(Int, (width * bpp) / 8)
        padding = (4 - (row_bytes % 4)) % 4

        img = Matrix{Makie.RGBf}(undef, abs(height), width)

        # Hoist bit-depth branching logic completely OUT of the pixel loops for massive speedups
        if bpp == 1
            for y = 1:abs(height)
                row = height > 0 ? abs(height) - y + 1 : y
                bytes = read(io, row_bytes)
                for x = 1:width
                    byte_idx = div(x - 1, 8) + 1
                    bit_idx = 7 - ((x - 1) % 8)
                    idx = ((bytes[byte_idx] >> bit_idx) & 1) + 1
                    img[row, x] =
                        idx <= length(palette) ? palette[idx] : Makie.RGBf(0, 0, 0)
                end
                skip(io, padding)
            end
        elseif bpp == 4
            for y = 1:abs(height)
                row = height > 0 ? abs(height) - y + 1 : y
                bytes = read(io, row_bytes)
                for x = 1:width
                    byte_idx = div(x - 1, 2) + 1
                    idx =
                        (
                            (x - 1) % 2 == 0 ? (bytes[byte_idx] >> 4) :
                            (bytes[byte_idx] & 0x0F)
                        ) + 1
                    img[row, x] =
                        idx <= length(palette) ? palette[idx] : Makie.RGBf(0, 0, 0)
                end
                skip(io, padding)
            end
        elseif bpp == 8
            for y = 1:abs(height)
                row = height > 0 ? abs(height) - y + 1 : y
                for x = 1:width
                    idx = read(io, UInt8) + 1 # 1-based index
                    img[row, x] =
                        idx <= length(palette) ? palette[idx] : Makie.RGBf(0, 0, 0)
                end
                skip(io, padding)
            end
        elseif bpp == 24
            for y = 1:abs(height)
                row = height > 0 ? abs(height) - y + 1 : y
                for x = 1:width
                    b = read(io, UInt8) / 255.0f0
                    g = read(io, UInt8) / 255.0f0
                    r = read(io, UInt8) / 255.0f0
                    img[row, x] = Makie.RGBf(r, g, b)
                end
                skip(io, padding)
            end
        elseif bpp == 32
            for y = 1:abs(height)
                row = height > 0 ? abs(height) - y + 1 : y
                for x = 1:width
                    b = read(io, UInt8) / 255.0f0
                    g = read(io, UInt8) / 255.0f0
                    r = read(io, UInt8) / 255.0f0
                    skip(io, 1) # Skip unused Alpha
                    img[row, x] = Makie.RGBf(r, g, b)
                end
                skip(io, padding)
            end
        end

        return img
    end
end
