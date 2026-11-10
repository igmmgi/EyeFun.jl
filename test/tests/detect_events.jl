@testset "detect_events!" begin
    edf = Main.TEST1_EDF
    df = Main.TEST1_DF

    # Count original EyeLink fixations for comparison
    eyelink_fix_count = count(
        i -> df.df.in_fix[i] && (i == 1 || !df.df.in_fix[i-1]),
        eachindex(df.df.in_fix),
    )

    @testset "I-VT detection" begin
        df_ivt = deepcopy(df)
        detect_events!(df_ivt; method = :ivt, velocity_threshold = 30.0)

        for col in [
            :in_fix,
            :fix_gavx,
            :fix_gavy,
            :fix_ava,
            :fix_dur,
            :in_sacc,
            :sacc_gstx,
            :sacc_gsty,
            :sacc_genx,
            :sacc_geny,
            :sacc_dur,
            :sacc_ampl,
            :sacc_pvel,
        ]
            @test hasproperty(df_ivt.df, col)
        end

        @test eltype(df_ivt.df.in_fix) == Bool
        @test eltype(df_ivt.df.in_sacc) == Bool
        @test eltype(df_ivt.df.fix_gavx) == Float64
        @test eltype(df_ivt.df.sacc_ampl) == Float64

        ivt_fix_count = count(
            i -> df_ivt.df.in_fix[i] && (i == 1 || !df_ivt.df.in_fix[i-1]),
            eachindex(df_ivt.df.in_fix),
        )
        ivt_sacc_count = count(
            i -> df_ivt.df.in_sacc[i] && (i == 1 || !df_ivt.df.in_sacc[i-1]),
            eachindex(df_ivt.df.in_sacc),
        )
        @test ivt_fix_count > 0
        @test ivt_sacc_count > 0
        @test ivt_fix_count > eyelink_fix_count ÷ 5
        @test ivt_fix_count < eyelink_fix_count * 5

        valid_fx = filter(!isnan, df_ivt.df.fix_gavx)
        @test !isempty(valid_fx)
        @test all(v -> -500 < v < 2500, valid_fx)

        valid_ampl = filter(!isnan, df_ivt.df.sacc_ampl)
        @test !isempty(valid_ampl)
        @test all(>=(0), valid_ampl)
    end

    @testset "I-DT detection" begin
        df_idt = deepcopy(df)
        detect_events!(df_idt; method = :idt, dispersion_threshold = 1.5)

        idt_fix_count = count(
            i -> df_idt.df.in_fix[i] && (i == 1 || !df_idt.df.in_fix[i-1]),
            eachindex(df_idt.df.in_fix),
        )
        @test idt_fix_count > 0
    end

    @testset "Prefix mode" begin
        df_pfx = deepcopy(df)
        orig_in_fix = copy(df_pfx.df.in_fix)

        detect_events!(df_pfx; method = :ivt, prefix = :ivt)

        @test df_pfx.df.in_fix == orig_in_fix
        @test hasproperty(df_pfx.df, :ivt_in_fix)
        @test hasproperty(df_pfx.df, :ivt_fix_gavx)
        @test hasproperty(df_pfx.df, :ivt_sacc_ampl)
        @test hasproperty(df_pfx.df, :ivt_sacc_pvel)
        @test any(df_pfx.df.ivt_in_fix)
        @test any(df_pfx.df.ivt_in_sacc)
    end

    @testset "Synthetic data" begin
        # Create a simple fixation → saccade → fixation pattern
        # Fixation at (500, 500) for 200 samples, then saccade to (800, 500),
        # then fixation at (800, 500) for 200 samples
        n = 500
        gx = fill(NaN32, n)
        gy = fill(NaN32, n)

        # Fixation 1: samples 1-200 at (500, 500) with small jitter
        for i = 1:200
            gx[i] = Float32(500.0 + randn() * 2.0)
            gy[i] = Float32(500.0 + randn() * 2.0)
        end
        # Saccade: samples 201-220, linear sweep from 500 to 800
        for i = 201:220
            frac = (i - 201) / 19.0
            gx[i] = Float32(500.0 + 300.0 * frac)
            gy[i] = Float32(500.0)
        end
        # Fixation 2: samples 221-420 at (800, 500) with small jitter
        for i = 221:420
            gx[i] = Float32(800.0 + randn() * 2.0)
            gy[i] = Float32(500.0 + randn() * 2.0)
        end
        # Remaining samples: NaN (noise/missing data)

        syn_df = DataFrame(
            time = UInt32.(1:n),
            trial = fill(1, n),
            gxL = gx,
            gyL = gy,
            gxR = fill(NaN32, n),
            gyR = fill(NaN32, n),
            paL = fill(Float32(1000.0), n),
            paR = fill(NaN32, n),
            in_fix = falses(n),
            fix_gavx = fill(NaN32, n),
            fix_gavy = fill(NaN32, n),
            fix_ava = fill(NaN32, n),
            fix_dur = fill(Int32(0), n),
            in_sacc = falses(n),
            sacc_gstx = fill(NaN32, n),
            sacc_gsty = fill(NaN32, n),
            sacc_genx = fill(NaN32, n),
            sacc_geny = fill(NaN32, n),
            sacc_dur = fill(Int32(0), n),
            sacc_ampl = fill(NaN32, n),
            sacc_pvel = fill(NaN32, n),
            in_blink = falses(n),
            blink_dur = fill(Int32(0), n),
            message = fill("", n),
        )

        syn = EyeData(syn_df)

        detect_events!(
            syn;
            method = :ivt,
            velocity_threshold = 30.0,
            min_fixation_ms = 50,
            eye = :left,
        )

        fix_count = count(
            i -> syn.df.in_fix[i] && (i == 1 || !syn.df.in_fix[i-1]),
            eachindex(syn.df.in_fix),
        )
        @test fix_count >= 2

        sacc_count = count(
            i -> syn.df.in_sacc[i] && (i == 1 || !syn.df.in_sacc[i-1]),
            eachindex(syn.df.in_sacc),
        )
        @test sacc_count >= 1

        first_fix_x = syn.df.fix_gavx[findfirst(syn.df.in_fix)]
        @test 490 < first_fix_x < 510
        @test !any(syn.df.in_sacc[421:500])
    end

    @testset "I-DT separator, NaN pupil in fix_ava, and pixels_per_degree kwarg" begin
        # Two steady 120-sample fixations separated by an instantaneous jump from x=400 to x=800
        n = 260
        gx = vcat(fill(400.0f0, 120), fill(800.0f0, 120), fill(NaN32, 20))
        gy = vcat(fill(500.0f0, 240), fill(NaN32, 20))
        pa = fill(1000.0f0, n)
        pa[10:20] .= NaN32  # partial NaN pupil inside first fixation

        ed_idt = EyeData(
            DataFrame(
                time = collect(1.0:n),
                trial = fill(1, n),
                gxL = gx,
                gyL = gy,
                paL = pa,
                message = fill("", n),
            );
            sample_rate = 1000.0,
        )

        detect_events!(
            ed_idt;
            method = :idt,
            dispersion_threshold = 1.0,
            min_fixation_ms = 80,
            pixels_per_degree = 35.0,
            eye = :left,
        )

        f_idt = fixations(ed_idt)
        # Separates into 2 distinct fixations (at ~400 and ~800)
        @test nrow(f_idt) == 2
        @test f_idt.gavx[1] ≈ 400.0 atol = 1.0
        @test f_idt.gavx[2] ≈ 800.0 atol = 1.0
        # fix_ava must ignore NaN pupil samples and remain finite (~1000.0)
        @test !isnan(f_idt.ava[1])
        @test f_idt.ava[1] ≈ 1000.0 atol = 1e-3
        # Trailing NaN samples must not be classified as saccades
        @test !any(ed_idt.df.in_sacc[241:260])
    end

    @testset "Cross-trial isolation, prefixed blinks, and generic NaN blinks" begin
        # Two trials with a large inter-trial jump at sample 150 -> 151 and a NaN blink in trial 2
        n = 300
        gx = vcat(fill(200.0f0, 150), fill(900.0f0, 50), fill(NaN32, 60), fill(900.0f0, 40))
        gy = vcat(fill(500.0f0, 150), fill(500.0f0, 50), fill(NaN32, 60), fill(500.0f0, 40))
        pa = vcat(fill(1000.0f0, 200), fill(NaN32, 60), fill(1000.0f0, 40))

        ed_pref = EyeData(
            DataFrame(
                participant = vcat(fill("P1", 150), fill("P2", 150)),
                trial = vcat(fill(1, 150), fill(1, 150)),
                time = collect(1.0:n),
                gxL = copy(gx),
                gyL = copy(gy),
                paL = copy(pa),
                message = fill("", n),
            );
            sample_rate = 1000.0,
        )

        detect_events!(ed_pref; method = :ivt, prefix = :ivt, detect_blinks = true, min_blink_ms = 50)
        @test hasproperty(ed_pref.df, :ivt_in_blink)
        @test hasproperty(ed_pref.df, :ivt_blink_dur)
        @test !hasproperty(ed_pref.df, :in_blink)
        @test any(ed_pref.df.ivt_in_blink[201:260])
        # No cross-trial saccade across the (P1, trial 1) -> (P2, trial 1) boundary
        @test !any(ed_pref.df.ivt_in_sacc[148:153])

        # Contiguous same-coordinate fixations across a trial boundary must stay separated
        ed_same = EyeData(
            DataFrame(
                participant = fill("P1", 240),
                trial = vcat(fill(1, 120), fill(2, 120)),
                time = collect(1.0:240),
                gxL = fill(500.0f0, 240),
                gyL = fill(400.0f0, 240),
                paL = fill(1000.0f0, 240),
                message = fill("", 240),
            );
            sample_rate = 1000.0,
        )
        detect_events!(ed_same; method = :ivt)
        @test nrow(fixations(ed_same)) == 2
        @test counts(ed_same.df.in_fix) == 2

        detect_events!(ed_same; method = :idt)
        @test nrow(fixations(ed_same)) == 2
        @test counts(ed_same.df.in_fix) == 2
    end

    @testset "Adaptive I-VT (Nystrom & Holmqvist, 2010)" begin
        # 400 samples: noisy fixation (~4 deg/s noise) -> 10 deg saccade -> noisy fixation + NaN blink
        n = 400
        gx = Vector{Float64}(undef, n)
        gy = fill(400.0, n)
        for i = 1:150
            gx[i] = 300.0 + 0.4 * sin(0.7 * i)
        end
        for i = 151:170
            gx[i] = 300.0 + 20.0 * (i - 150)  # 400 px (~11 deg) saccade over 20 ms
        end
        for i = 171:320
            gx[i] = 700.0 + 0.4 * cos(0.7 * i)
        end
        # Blink gap with boundary artifact spike
        gx[320] = 820.0
        gx[321:360] .= NaN
        gy[321:360] .= NaN
        for i = 361:400
            gx[i] = 700.0 + 0.4 * sin(0.5 * i)
        end

        ed_ad = EyeData(
            DataFrame(
                participant = fill("P1", n),
                trial = fill(1, n),
                time = collect(0.0:(n-1)),
                gxL = gx,
                gyL = gy,
                paL = fill(1000.0, n),
                message = fill("", n),
            );
            sample_rate = 1000.0,
        )
        detect_events!(ed_ad; method = :ivt, velocity_threshold = :adaptive, min_fixation_ms = 30)
        sac_ad = saccades(ed_ad)
        fix_ad = fixations(ed_ad)
        @test nrow(sac_ad) == 1
        @test sac_ad.ampl[1] > 8.0
        @test nrow(fix_ad) >= 2
        @test_throws ArgumentError detect_events!(ed_ad; velocity_threshold = :unknown)
        @test_throws ArgumentError detect_events!(ed_ad; velocity_threshold = 0.0)
    end
end
