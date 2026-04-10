
# Test: image loading without explicit FileIO/ImageMagick dependency
# Run with: julia --project=/home/ian/Documents/Julia/EyeFun.jl test_image.jl
#
# No display needed — just check if we can load image data.

png_path = "/home/ian/Documents/Python/pydmc/.venv/lib/python3.13/site-packages/matplotlib/mpl-data/sample_data/logo2.png"

# ── Test 1: FileIO accessible as a transitive dep of Makie? ───────────────
println("── Test 1: import FileIO (transitive via Makie) ──")
try
    import FileIO
    img = FileIO.load(png_path)
    println("  ✅ FileIO.load: $(typeof(img)) size=$(size(img))")
catch e
    println("  ❌ $e")
end

# ── Test 2: Which image backends are loaded? ───────────────────────────────
println("\n── Test 2: available image backends ──")
for pkg in ("ImageMagick", "PNGFiles", "JpegTurbo", "ImageIO")
    try
        Base.require(Main, Symbol(pkg))
        println("  ✅ $pkg is available")
    catch
        println("  ❌ $pkg not available")
    end
end

# ── Test 3: raw read without any package ──────────────────────────────────
# PNG has a simple enough header we can confirm format
println("\n── Test 3: file format detection (no packages) ──")
for path in (png_path,)
    bytes = read(path, 8)
    sig = bytes[1:4]
    if sig == UInt8[0x89, 0x50, 0x4E, 0x47]
        println("  ✅ $(basename(path)) is a valid PNG")
    elseif sig[1:2] == UInt8[0xFF, 0xD8]
        println("  ✅ $(basename(path)) is a valid JPEG")
    elseif sig[1:3] == b"GIF"
        println("  ✅ $(basename(path)) is a valid GIF")
    else
        println("  ❓ $(basename(path)) unknown format: $sig")
    end
end

println("\nDone.")
