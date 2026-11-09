# BMP image reader supporting 1/4/8/16/24/32-bit uncompressed (BI_RGB) and
# bitfield-masked (BI_BITFIELDS / BI_ALPHABITFIELDS) formats, plus OS/2 BITMAPCOREHEADER.

@inline function _bmp_mask_shift_scale(mask::UInt32)
    mask == 0x00000000 && return (0, 0x00000000, 0.0f0)
    sh = trailing_zeros(mask)
    sm = mask >> sh
    return (sh, sm, 1.0f0 / Float32(sm))
end

function read_bmp(path::AbstractString)
    open(path, "r") do io
        magic = read(io, 2)
        (length(magic) == 2 && magic[1] == UInt8('B') && magic[2] == UInt8('M')) ||
            error("Not a BMP file: $path")

        skip(io, 8)
        data_offset = Int64(ltoh(read(io, UInt32)))
        header_size = Int(ltoh(read(io, UInt32)))

        if header_size == 12
            # OS/2 BITMAPCOREHEADER
            width = Int(ltoh(read(io, UInt16)))
            height = Int(ltoh(read(io, UInt16)))
            (width <= 0 || height == 0) &&
                error("Invalid BMP dimensions ($(width)x$(height)): $path")
            skip(io, 2) # planes
            bpp = Int(ltoh(read(io, UInt16)))
            compression = UInt32(0)
        elseif header_size >= 40
            width = Int(ltoh(read(io, Int32)))
            height = Int(ltoh(read(io, Int32)))
            (width <= 0 || height == 0) &&
                error("Invalid BMP dimensions ($(width)x$(height)): $path")
            skip(io, 2) # planes
            bpp = Int(ltoh(read(io, UInt16)))
            compression = ltoh(read(io, UInt32))
        else
            error("Unsupported BMP DIB header size ($header_size bytes): $path")
        end

        if !(bpp in (1, 4, 8, 16, 24, 32))
            error(
                "Only 1, 4, 8, 16, 24, and 32-bit BMPs are supported (got $(bpp)-bit).",
            )
        end
        if !(compression == 0 || (compression in (3, 6) && bpp in (16, 32)))
            error("Compressed BMP format (compression=$compression) not supported: $path")
        end

        # Bitfield channel masks for 16-bit and 32-bit BMPs
        rmask = UInt32(0x00FF0000)
        gmask = UInt32(0x0000FF00)
        bmask = UInt32(0x000000FF)
        if bpp == 16 && compression == 0
            rmask = UInt32(0x00007C00)
            gmask = UInt32(0x000003E0)
            bmask = UInt32(0x0000001F)
        elseif compression in (3, 6)
            seek(io, 54)
            rmask = ltoh(read(io, UInt32))
            gmask = ltoh(read(io, UInt32))
            bmask = ltoh(read(io, UInt32))
        end

        palette = Makie.RGBf[]
        if bpp <= 8
            palette_start = Int64(14) + Int64(header_size)
            seek(io, palette_start)
            entry_bytes = header_size == 12 ? 3 : 4
            num_colors =
                data_offset > palette_start ?
                Int(div(data_offset - palette_start, entry_bytes)) : 0
            if num_colors <= 0 || num_colors > (1 << bpp)
                num_colors = 1 << bpp
            end
            pal_raw = read(io, num_colors * entry_bytes)
            n_entries = div(length(pal_raw), entry_bytes)
            resize!(palette, n_entries)
            inv255 = 1.0f0 / 255.0f0
            @inbounds for i = 1:n_entries
                off = (i - 1) * entry_bytes
                b = Float32(pal_raw[off+1]) * inv255
                g = Float32(pal_raw[off+2]) * inv255
                r = Float32(pal_raw[off+3]) * inv255
                palette[i] = Makie.RGBf(r, g, b)
            end
        end

        seek(io, data_offset)

        abs_h = abs(height)
        row_bytes = cld(width * bpp, 8)
        padding = (4 - (row_bytes & 3)) & 3
        stride = row_bytes + padding

        buf = read(io, stride * abs_h)
        length(buf) < stride * (abs_h - 1) + row_bytes &&
            error("Truncated BMP pixel data: $path")

        img = Matrix{Makie.RGBf}(undef, abs_h, width)
        inv255 = 1.0f0 / 255.0f0
        n_pal = length(palette)

        if bpp == 1
            @inbounds for y = 1:abs_h
                row = height > 0 ? abs_h - y + 1 : y
                r_off = (y - 1) * stride
                for x = 1:width
                    byte_idx = r_off + ((x - 1) >> 3) + 1
                    bit_idx = 7 - ((x - 1) & 7)
                    idx = Int((buf[byte_idx] >> bit_idx) & 0x01) + 1
                    img[row, x] = idx <= n_pal ? palette[idx] : Makie.RGBf(0, 0, 0)
                end
            end
        elseif bpp == 4
            @inbounds for y = 1:abs_h
                row = height > 0 ? abs_h - y + 1 : y
                r_off = (y - 1) * stride
                for x = 1:width
                    byte_idx = r_off + ((x - 1) >> 1) + 1
                    bval = buf[byte_idx]
                    idx = Int(iseven(x - 1) ? (bval >> 4) : (bval & 0x0F)) + 1
                    img[row, x] = idx <= n_pal ? palette[idx] : Makie.RGBf(0, 0, 0)
                end
            end
        elseif bpp == 8
            @inbounds for y = 1:abs_h
                row = height > 0 ? abs_h - y + 1 : y
                r_off = (y - 1) * stride
                for x = 1:width
                    idx = Int(buf[r_off+x]) + 1
                    img[row, x] = idx <= n_pal ? palette[idx] : Makie.RGBf(0, 0, 0)
                end
            end
        elseif bpp == 16
            rsh, rsm, rsc = _bmp_mask_shift_scale(rmask)
            gsh, gsm, gsc = _bmp_mask_shift_scale(gmask)
            bsh, bsm, bsc = _bmp_mask_shift_scale(bmask)
            @inbounds for y = 1:abs_h
                row = height > 0 ? abs_h - y + 1 : y
                r_off = (y - 1) * stride
                for x = 1:width
                    p = r_off + 2 * (x - 1)
                    px = UInt32(buf[p+1]) | (UInt32(buf[p+2]) << 8)
                    r = Float32((px >> rsh) & rsm) * rsc
                    g = Float32((px >> gsh) & gsm) * gsc
                    b = Float32((px >> bsh) & bsm) * bsc
                    img[row, x] = Makie.RGBf(r, g, b)
                end
            end
        elseif bpp == 24
            @inbounds for y = 1:abs_h
                row = height > 0 ? abs_h - y + 1 : y
                r_off = (y - 1) * stride
                for x = 1:width
                    p = r_off + 3 * (x - 1)
                    b = Float32(buf[p+1]) * inv255
                    g = Float32(buf[p+2]) * inv255
                    r = Float32(buf[p+3]) * inv255
                    img[row, x] = Makie.RGBf(r, g, b)
                end
            end
        elseif bpp == 32
            if compression == 0
                @inbounds for y = 1:abs_h
                    row = height > 0 ? abs_h - y + 1 : y
                    r_off = (y - 1) * stride
                    for x = 1:width
                        p = r_off + 4 * (x - 1)
                        b = Float32(buf[p+1]) * inv255
                        g = Float32(buf[p+2]) * inv255
                        r = Float32(buf[p+3]) * inv255
                        img[row, x] = Makie.RGBf(r, g, b)
                    end
                end
            else
                rsh, rsm, rsc = _bmp_mask_shift_scale(rmask)
                gsh, gsm, gsc = _bmp_mask_shift_scale(gmask)
                bsh, bsm, bsc = _bmp_mask_shift_scale(bmask)
                @inbounds for y = 1:abs_h
                    row = height > 0 ? abs_h - y + 1 : y
                    r_off = (y - 1) * stride
                    for x = 1:width
                        p = r_off + 4 * (x - 1)
                        px =
                            UInt32(buf[p+1]) |
                            (UInt32(buf[p+2]) << 8) |
                            (UInt32(buf[p+3]) << 16) |
                            (UInt32(buf[p+4]) << 24)
                        r = Float32((px >> rsh) & rsm) * rsc
                        g = Float32((px >> gsh) & gsm) * gsc
                        b = Float32((px >> bsh) & bsm) * bsc
                        img[row, x] = Makie.RGBf(r, g, b)
                    end
                end
            end
        end

        return img
    end
end
