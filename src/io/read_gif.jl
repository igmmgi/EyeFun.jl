# GIF87a/GIF89a first-frame image reader.

# GIF data comes in sub-blocks: [count byte | count bytes of data | ... | 0x00]
skip_subblocks(io) =
    while !eof(io) && (n = read(io, UInt8)) != 0x00
        skip(io, n)
    end

function read_subblocks(io)
    buf = UInt8[]
    while !eof(io) && (n = read(io, UInt8)) != 0x00
        append!(buf, read(io, n))
    end
    return buf
end

# Each entry is a (prefix_code, suffix_byte) pair stored in two arrays
function lzw_decompress(data::Vector{UInt8}, min_code::Int, npixels::Int)
    (min_code < 2 || min_code > 8 || npixels <= 0) && return UInt8[]
    clear = 1 << min_code
    eoi = clear + 1

    t_pre = fill(Int16(-1), 4096)         # prefix codes
    t_suf = Vector{UInt8}(undef, 4096)    # suffix bytes
    @inbounds for i = 0:(clear-1)
        t_suf[i+1] = UInt8(i)
    end

    csize = min_code + 1   # current code bit-width
    tsize = eoi + 1        # next free table slot
    bpos = 0               # bit position in data
    prev = -1              # previous code (-1 = none)
    pfst = 0x00            # first byte of previous code's sequence
    out = Vector{UInt8}(undef, npixels)
    n = 0
    stk = Vector{UInt8}(undef, 4096)

    function read_code()
        v = 0
        @inbounds for b = 0:(csize-1)
            i = (bpos >> 3) + 1
            i > length(data) && return -1
            v |= Int((data[i] >> (bpos & 7)) & 1) << b
            bpos += 1
        end
        v
    end

    function emit(code)::UInt8
        sp = 0
        c = code
        @inbounds while c >= clear
            (c < tsize && sp < 4095) || return 0x00
            sp += 1
            stk[sp] = t_suf[c+1]
            c = Int(t_pre[c+1])
        end
        (0 <= c < clear && sp < 4096) || return 0x00
        sp += 1
        @inbounds stk[sp] = t_suf[c+1]
        @inbounds fst = stk[sp]
        @inbounds for i = sp:-1:1
            n >= npixels && break
            n += 1
            out[n] = stk[i]
        end
        fst
    end

    function add_entry(pre, suf)
        tsize < 4096 || return
        @inbounds t_pre[tsize+1] = Int16(pre)
        @inbounds t_suf[tsize+1] = suf
        tsize += 1
        tsize == (1 << csize) && csize < 12 && (csize += 1)
    end

    while n < npixels
        code = read_code()
        (code < 0 || code == eoi) && break
        if code == clear
            csize = min_code + 1
            tsize = eoi + 1
            prev = -1
            continue
        end
        if code < tsize
            fst = emit(code)
            prev >= 0 && add_entry(prev, fst)
        elseif code == tsize && prev >= 0  # KwKwK: sequence is prev_sequence + prev_first
            add_entry(prev, pfst)
            fst = emit(code)
            prev = code
            pfst = fst
            continue
        else
            break
        end
        prev = code
        pfst = fst
    end
    out[1:n]   # trim to actual decoded length (guards against truncated streams)
end

# Colour tables are stored as flat UInt8 byte arrays: [R,G,B, R,G,B, ...]
# Entry i (0-based) lives at bytes ct[3i+1 .. 3i+3].

function read_gif(path::AbstractString)::Matrix{Makie.RGBAf}
    io = IOBuffer(read(path))

    # Header: "GIF" + version ("87a" or "89a")
    String(read(io, 3)) == "GIF" || error("Not a GIF: $path")
    skip(io, 3)

    # Logical Screen Descriptor
    lsd_w = Int(ltoh(read(io, UInt16)))
    lsd_h = Int(ltoh(read(io, UInt16)))
    packed = read(io, UInt8)
    skip(io, 2)                # background colour index + pixel aspect ratio

    # Optional Global Colour Table
    gct = (packed >> 7) & 1 == 1 ? read(io, 3 * (2^((packed & 7) + 1))) : UInt8[]

    tidx = -1   # transparent colour index (-1 = disabled)

    while !eof(io)
        block = read(io, UInt8)

        if block == 0x2C   # Image Descriptor
            ix = Int(ltoh(read(io, UInt16)))
            iy = Int(ltoh(read(io, UInt16)))
            iw = Int(ltoh(read(io, UInt16)))
            ih = Int(ltoh(read(io, UInt16)))
            (iw <= 0 || ih <= 0) && error("Invalid GIF dimensions ($(iw)x$(ih)): $path")
            ipk = read(io, UInt8)

            ct = (ipk >> 7) & 1 == 1 ? read(io, 3 * (2^((ipk & 7) + 1))) : gct
            interlaced = (ipk >> 6) & 1 == 1

            min_lzw = Int(read(io, UInt8))   # must read before sub-blocks
            indices = lzw_decompress(read_subblocks(io), min_lzw, iw * ih)

            # De-interlace (four-pass GIF scheme)
            if interlaced && length(indices) == iw * ih
                tmp = copy(indices)
                src = 1
                for rows in (0:8:(ih-1), 4:8:(ih-1), 2:4:(ih-1), 1:2:(ih-1)), row in rows
                    copyto!(indices, row * iw + 1, tmp, src, iw)
                    src += iw
                end
            end

            cw = lsd_w > 0 ? lsd_w : (ix + iw)
            ch = lsd_h > 0 ? lsd_h : (iy + ih)
            img = if ix == 0 && iy == 0 && iw == cw && ih == ch
                Matrix{Makie.RGBAf}(undef, ch, cw)
            else
                fill(Makie.RGBAf(0, 0, 0, 0), ch, cw)
            end

            n_idx = length(indices)
            inv255 = 1.0f0 / 255.0f0
            @inbounds for pix = 1:(iw*ih)
                r0, c0 = divrem(pix - 1, iw)
                row = iy + r0 + 1
                col = ix + c0 + 1
                (1 <= row <= ch && 1 <= col <= cw) || continue
                if pix <= n_idx
                    ci = Int(indices[pix])          # 0-based palette index
                    base = 3 * ci + 1
                    if base + 2 <= length(ct)
                        r = Float32(ct[base]) * inv255
                        g = Float32(ct[base+1]) * inv255
                        b = Float32(ct[base+2]) * inv255
                        img[row, col] = Makie.RGBAf(r, g, b, ci == tidx ? 0.0f0 : 1.0f0)
                    else
                        img[row, col] = Makie.RGBAf(0, 0, 0, 1)
                    end
                else
                    img[row, col] = Makie.RGBAf(0, 0, 0, 0)
                end
            end
            tidx = -1
            return img

        elseif block == 0x21  # Extension
            ext = read(io, UInt8)
            if ext == 0xF9    # Graphic Control (transparency flag)
                skip(io, 1)   # block size (always 4)
                flags = read(io, UInt8)
                skip(io, 2)   # delay time
                ci = read(io, UInt8)
                skip(io, 1)   # block terminator
                tidx = (flags & 1) == 1 ? Int(ci) : -1
            else
                skip_subblocks(io)   # Comment / Plain Text / Application / unknown
            end

        elseif block == 0x3B  # Trailer (end of stream)
            break
        end
    end
    error("No image data found in $path")
end
