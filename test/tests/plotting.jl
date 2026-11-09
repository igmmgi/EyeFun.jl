@testset "Plotting functions" begin
    df = Main.TEST1_DF

    aoi_regions =
        [RectAOI("Center", 640, 480, 400, 400), RectAOI("TopLeft", 160, 120, 320, 240)]

    @testset "plot_gaze (DataFrame)" begin
        fig = plot_gaze(df; selection = (trial = 1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_scanpath (DataFrame)" begin
        fig = plot_scanpath(df; selection = (trial = 1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_scanpath with aois" begin
        fig = plot_scanpath(df; selection = (trial = 1,), aois = aoi_regions)
        @test fig isa Makie.Figure
    end

    @testset "plot_heatmap (DataFrame)" begin
        fig = plot_heatmap(df; selection = (trial = 1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_heatmap with aois" begin
        fig = plot_heatmap(df; selection = (trial = 1,), aois = aoi_regions)
        @test fig isa Makie.Figure
    end

    @testset "plot_heatmap metrics" begin
        for m in (:samples, :dwell, :count, :proportion)
            fig = plot_heatmap(df; selection = (trial = 1,), metric = m)
            @test fig isa Makie.Figure
        end
    end

    @testset "plot_fixations" begin
        fig = plot_fixations(df; selection = (trial = 1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_fixations with aois" begin
        fig = plot_fixations(df; selection = (trial = 1,), aois = aoi_regions)
        @test fig isa Makie.Figure
    end

    @testset "plot_pupil" begin
        fig = plot_pupil(df; selection = (trial = 1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_velocity" begin
        fig = plot_velocity(df; selection = (trial = 1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_dwell" begin
        fig = plot_dwell(df, aoi_regions; selection = (trial = 1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_sequence" begin
        fig = plot_sequence(df; selection = (trial = 1:5,))
        @test fig isa Makie.Figure
    end

    @testset "plot_transitions" begin
        fig = plot_transitions(df, aoi_regions; selection = (trial = 1:5,))
        @test fig isa Makie.Figure
    end

    @testset "Multi-panel split_by and plot_databrowser" begin
        fig_multi = plot_gaze(df; selection = (trial = 1:2,), split_by = :trial)
        @test fig_multi isa Makie.Figure

        fig_db, db_state = plot_databrowser(
            df;
            split_by = :trial,
            display_plot = false,
        )
        @test fig_db isa Makie.Figure
        @test db_state isa EyeFun.EyeViewerMediaState
    end

    @testset "Media, image_loader, read_stimuli, and WAV generation" begin
        mktempdir() do dir
            # Create a valid 2×2 24-bit uncompressed BMP (54-byte header + 2×8-byte padded rows = 70 bytes)
            bmp_path = joinpath(dir, "stim1.bmp")
            bmp = zeros(UInt8, 70)
            bmp[1:2] .= b"BM"
            bmp[3:6] .= reinterpret(UInt8, [htol(UInt32(70))])
            bmp[11:14] .= reinterpret(UInt8, [htol(UInt32(54))])  # pixel offset
            bmp[15:18] .= reinterpret(UInt8, [htol(UInt32(40))])  # BITMAPINFOHEADER size
            bmp[19:22] .= reinterpret(UInt8, [htol(Int32(2))])    # width = 2
            bmp[23:26] .= reinterpret(UInt8, [htol(Int32(2))])    # height = 2
            bmp[27:28] .= reinterpret(UInt8, [htol(UInt16(1))])   # planes = 1
            bmp[29:30] .= reinterpret(UInt8, [htol(UInt16(24))])  # bpp = 24
            write(bmp_path, bmp)

            txt_path = joinpath(dir, "prompt.txt")
            write(txt_path, "Read this sentence.")

            @test image_size(bmp_path) == (2, 2)
            img = load_image(bmp_path)
            @test size(img) == (2, 2)

            stim = read_stimuli(dir; file_extensions = ["bmp", "txt"])
            @test haskey(stim, "stim1.bmp")
            @test stim["prompt.txt"] == "Read this sentence."

            wav_path = joinpath(dir, "tone.wav")
            EyeFun._write_pcm16_wav(wav_path, Float32[0.0, 0.5, -0.5, 0.0], 8000)
            @test isfile(wav_path)
            wav_bytes = read(wav_path)
            @test wav_bytes[1:4] == b"RIFF"
            @test wav_bytes[9:12] == b"WAVE"
            @test length(wav_bytes) == 44 + 8  # 44-byte PCM16 header + 4 frames * 2 bytes

            im_med = ImageMedia(content = img)
            au_med = AudioMedia(content = (Float32[0.0, 0.1], 8000))
            tx_med = TextMedia(content = "Hello")
            @test im_med isa AbstractEyeFunMedia
            @test au_med isa AbstractEyeFunMedia
            @test tx_med isa AbstractEyeFunMedia

            # Int16 PCM WAV scaling, default AOI color === nothing, integer bins, gaze-only databrowser
            wav16_path = joinpath(dir, "tone16.wav")
            EyeFun._write_pcm16_wav(wav16_path, Int16[0, 16384, -16384, 0], 8000)
            @test length(read(wav16_path)) == 44 + 8

            @test RectAOI("AutoColor", 200, 200, 100, 100).color === nothing
            fig_bins = plot_heatmap(df; selection = (trial = 1,), bins = 40)
            @test fig_bins isa Makie.Figure

            ed_nopupil = EyeData(
                DataFrame(
                    trial = [1, 1, 1],
                    time = [0.0, 1.0, 2.0],
                    gxL = [500.0, 502.0, 504.0],
                    gyL = [400.0, 401.0, 402.0],
                    in_fix = [true, true, true],
                    fix_gavx = [502.0, 502.0, 502.0],
                    fix_gavy = [401.0, 401.0, 401.0],
                    fix_ava = [NaN, NaN, NaN],
                    fix_dur = [3, 3, 3],
                    message = ["!V IMGLOAD TOP_LEFT stim1.bmp 100 100", "", ""],
                );
                sample_rate = 1000.0,
            )
            fig_np, st_np = plot_databrowser(
                ed_nopupil;
                stimuli = stim,
                match_stimuli = id -> [(bmp_path, (100, 100))],
                display_plot = false,
            )
            @test fig_np isa Makie.Figure
            @test st_np isa EyeFun.EyeViewerMediaState
        end
    end

    @testset "read_gif, plot_stimuli, and headless audio helpers" begin
        mktempdir() do tmpdir
            # Minimal valid 2x2 GIF89a with 4-color GCT (Red, Green, Blue, Transparent)
            gif_bytes = UInt8[
                0x47, 0x49, 0x46, 0x38, 0x39, 0x61, # "GIF89a"
                0x02, 0x00, 0x02, 0x00, 0x81, 0x00, 0x00, # LSD: 2x2, 4-entry GCT
                0xFF, 0x00, 0x00, # 0: red
                0x00, 0xFF, 0x00, # 1: green
                0x00, 0x00, 0xFF, # 2: blue
                0xFF, 0xFF, 0xFF, # 3: transparent white
                0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x03, 0x00, # GCE: tidx = 3
                0x2C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, # Image 2x2
                0x02, 0x03, 0x44, 0x34, 0x05, 0x00, # LZW stream [clear=4, 0, 1, 2, 3, eoi=5]
                0x3B, # Trailer
            ]
            gif_path = joinpath(tmpdir, "tiny.gif")
            write(gif_path, gif_bytes)

            @test image_size(gif_path) == (2, 2)
            gif_img = EyeFun.read_gif(gif_path)
            @test size(gif_img) == (2, 2)
            @test gif_img[1, 1] == Makie.RGBAf(1.0f0, 0.0f0, 0.0f0, 1.0f0)
            @test gif_img[1, 2] == Makie.RGBAf(0.0f0, 1.0f0, 0.0f0, 1.0f0)
            @test gif_img[2, 1] == Makie.RGBAf(0.0f0, 0.0f0, 1.0f0, 1.0f0)
            @test gif_img[2, 2].alpha == 0.0f0
            @test size(load_image(gif_path; use_cache = false)) == (2, 2)

            # plot_stimuli: empty + multi-type dictionary + filter & navigation callbacks
            @test plot_stimuli(Dict{String,Any}()) isa Figure
            stim_mix = Dict{String,Any}(
                "a_tiny.gif" => gif_path,
                "b_mat.png" => fill(Makie.RGBf(0.2f0, 0.4f0, 0.6f0), 4, 4),
                "c_tone.wav" => (zeros(Float32, 16), 8000),
                "d_text.txt" => repeat("café ", 100),
            )
            fig_st = plot_stimuli(stim_mix)
            @test fig_st isa Figure
            menus = [b for b in fig_st.content if b isa Makie.Menu]
            sliders = [b for b in fig_st.content if b isa Makie.Slider]
            @test length(menus) == 1 && length(sliders) == 1
            menus[1].selection[] = ".txt"
            menus[1].selection[] = ".wav"
            menus[1].selection[] = "All"
            Makie.set_close_to!(sliders[1], 2)
            @test sliders[1].value[] >= 1

            # Headless PCM16 WAV encoding helpers
            @test EyeFun._sample_to_pcm16(Int16(1234)) == Int16(1234)
            @test EyeFun._sample_to_pcm16(0x80) == Int16(0)
            @test EyeFun._sample_to_pcm16(0.0f0) == Int16(0)
            @test EyeFun._sample_to_pcm16(1.0) == Int16(32767)
            @test EyeFun._sample_to_pcm16(-1.0) == Int16(-32767)
            @test EyeFun._sample_to_pcm16(NaN) == Int16(0)

            wav_mono = joinpath(tmpdir, "mono.wav")
            EyeFun._write_pcm16_wav(wav_mono, Float32[0.0, 0.5, -0.5, 1.0], 16000)
            raw_wav = read(wav_mono)
            @test length(raw_wav) == 44 + 4 * 2
            @test String(raw_wav[1:4]) == "RIFF"
            @test String(raw_wav[9:12]) == "WAVE"
            @test String(raw_wav[13:16]) == "fmt "
            @test String(raw_wav[37:40]) == "data"

            wav_stereo = joinpath(tmpdir, "stereo.wav")
            EyeFun._write_pcm16_wav(wav_stereo, zeros(Float32, 5, 2), 22050)
            @test filesize(wav_stereo) == 44 + 5 * 2 * 2
        end
    end
end
