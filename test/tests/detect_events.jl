# ════════════════════════════════════════════════════════════════════════════ #
#  detect_events! — native event detection
# ════════════════════════════════════════════════════════════════════════════ #

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

        # Column schema must match
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

        # Types
        @test eltype(df_ivt.df.in_fix) == Bool
        @test eltype(df_ivt.df.in_sacc) == Bool
        @test eltype(df_ivt.df.fix_gavx) == Float64
        @test eltype(df_ivt.df.sacc_ampl) == Float64

        # Should find some fixations and saccades
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

        # Fixation count should be in the right ballpark (within 5×)
        @test ivt_fix_count > eyelink_fix_count ÷ 5
        @test ivt_fix_count < eyelink_fix_count * 5

        # Fixation centroids should be within screen bounds
        valid_fx = filter(!isnan, df_ivt.df.fix_gavx)
        @test !isempty(valid_fx)
        @test all(v -> -500 < v < 2500, valid_fx)  # generous bounds

        # Saccade amplitudes should be positive
        valid_ampl = filter(!isnan, df_ivt.df.sacc_ampl)
        @test !isempty(valid_ampl)
        @test all(>=(0), valid_ampl)
    end

    @testset "I-DT detection" begin
        df_idt = deepcopy(df)
        detect_events!(df_idt; method = :idt, dispersion_threshold = 1.5)

        # Should find fixations
        idt_fix_count = count(
            i -> df_idt.df.in_fix[i] && (i == 1 || !df_idt.df.in_fix[i-1]),
            eachindex(df_idt.df.in_fix),
        )
        @test idt_fix_count > 0
    end

    @testset "Prefix mode" begin
        df_pfx = deepcopy(df)
        # Save original EyeLink values
        orig_in_fix = copy(df_pfx.df.in_fix)

        detect_events!(df_pfx; method = :ivt, prefix = :ivt)

        # Original columns should be untouched
        @test df_pfx.df.in_fix == orig_in_fix

        # Prefixed columns should exist
        @test hasproperty(df_pfx.df, :ivt_in_fix)
        @test hasproperty(df_pfx.df, :ivt_fix_gavx)
        @test hasproperty(df_pfx.df, :ivt_sacc_ampl)
        @test hasproperty(df_pfx.df, :ivt_sacc_pvel)

        # Prefixed columns should have data
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
        # Saccade: samples 201-220 — rapid movement from 500 to 800
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

        # Should detect at least 2 fixations
        fix_count = count(
            i -> syn.df.in_fix[i] && (i == 1 || !syn.df.in_fix[i-1]),
            eachindex(syn.df.in_fix),
        )
        @test fix_count >= 2

        # Should detect at least 1 saccade
        sacc_count = count(
            i -> syn.df.in_sacc[i] && (i == 1 || !syn.df.in_sacc[i-1]),
            eachindex(syn.df.in_sacc),
        )
        @test sacc_count >= 1

        # First fixation centroid should be near (500, 500)
        first_fix_x = syn.df.fix_gavx[findfirst(syn.df.in_fix)]
        @test 490 < first_fix_x < 510
    end
end
