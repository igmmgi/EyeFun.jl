@testset "Analysis functions" begin
    edf = Main.TEST1_EDF
    df = Main.TEST1_DF
    edf_path = Main.TEST1_EDF_PATH

    aoi_regions =
        [RectAOI("Center", 640, 480, 400, 400), RectAOI("TopLeft", 160, 120, 320, 240)]

    @testset "data_quality" begin
        dq = data_quality(df)
        @test dq isa DataFrame
        @test nrow(dq) > 0
        @test hasproperty(dq, :trial)
        @test hasproperty(dq, :tracking_loss_pct)
        @test hasproperty(dq, :blink_count)
        @test hasproperty(dq, :mean_pupil)
        @test hasproperty(dq, :duration_ms)
        # tracking_loss_pct should be between 0 and 100
        @test all(0 .<= dq.tracking_loss_pct .<= 100)
    end

    @testset "interpolate_blinks!" begin
        df2 = deepcopy(df)
        pa_col = hasproperty(df2.df, :paL) && !all(isnan, df2.df.paL) ? :paL : :paR
        nan_before = count(isnan, df2.df[!, pa_col])
        interpolate_blinks!(df2)
        nan_after = count(isnan, df2.df[!, pa_col])
        # Should reduce NaN count (blinks replaced with interpolated values)
        @test nan_after <= nan_before
    end

    @testset "smooth_pupil!" begin
        df2 = deepcopy(df)
        pa_col = hasproperty(df2.df, :paL) && !all(isnan, df2.df.paL) ? :paL : :paR
        raw = Float64.(df2.df[!, pa_col])
        smooth_pupil!(df2; window_ms = 20)
        smoothed = Float64.(df2.df[!, pa_col])
        # Smoothed signal should differ from raw
        @test raw != smoothed
        # Smoothed mean should be similar to raw mean (for non-NaN)
        raw_valid = filter(!isnan, raw)
        sm_valid = filter(!isnan, smoothed)
        if !isempty(raw_valid) && !isempty(sm_valid)
            @test abs(mean(raw_valid) - mean(sm_valid)) < 100.0
        end
    end

    @testset "drift_correct!" begin
        df2 = deepcopy(df)
        drift_correct!(df2; target = (640, 480))
        # Should still have valid gaze data
        gx_col = hasproperty(df2.df, :gxL) && !all(isnan, df2.df.gxL) ? :gxL : :gxR
        @test any(!isnan, df2.df[!, gx_col])
    end

    @testset "aoi_metrics" begin
        am = aoi_metrics(df, aoi_regions; selection = (trial = 1,))
        @test am isa DataFrame
        @test nrow(am) > 0
        @test hasproperty(am, :trial)
        @test hasproperty(am, :aoi)
        @test hasproperty(am, :dwell_time_ms)
        @test hasproperty(am, :fixation_count)
        @test hasproperty(am, :entry_count)
        # Should have one row per AOI per trial
        @test nrow(am) == length(aoi_regions)

        # Test with CircleAOI
        circle_aois = [CircleAOI("Center", 640, 480, 200)]
        am2 = aoi_metrics(df, circle_aois; selection = (trial = 1,))
        @test am2 isa DataFrame
        @test nrow(am2) > 0
    end

    @testset "coordinates" begin
        ppd = pixels_per_degree(df)
        @test ppd > 0
        @test ppd isa Float64

        # Screen center should be (0, 0) in degrees
        cx, cy = df.screen_res[1] / 2, df.screen_res[2] / 2
        xd, yd = px_to_deg(df, cx, cy)
        @test xd ≈ 0.0 atol = 0.01
        @test yd ≈ 0.0 atol = 0.01

        # Round-trip
        xp, yp = deg_to_px(df, xd, yd)
        @test xp ≈ cx atol = 0.01
        @test yp ≈ cy atol = 0.01
    end

    @testset "exclude_trials!" begin
        df_copy = deepcopy(df)
        n_before = length(unique(skipmissing(df_copy.df.trial)))
        result = exclude_trials!(df_copy; max_tracking_loss = 50.0)
        @test result.n_before == n_before
        @test result.n_after <= n_before
        @test result.n_excluded >= 0
    end

    @testset "transition_matrix and entropy" begin
        tm = transition_matrix(df, aoi_regions; selection = (trial = 1:5,))
        @test tm.matrix isa Matrix{Float64}
        @test length(tm.labels) == length(aoi_regions)
        @test size(tm.matrix) == (length(aoi_regions), length(aoi_regions))

        ent = transition_entropy(tm)
        @test ent isa Float64
        @test ent >= 0.0
    end

    @testset "fixation_metrics" begin
        fm = fixation_metrics(df, aoi_regions; selection = (trial = 1:5,))
        @test fm isa DataFrame
        @test nrow(fm) > 0
        @test hasproperty(fm, :aoi)
        @test hasproperty(fm, :first_fixation_duration)
        @test hasproperty(fm, :gaze_duration)
        @test hasproperty(fm, :total_time)
        @test hasproperty(fm, :fixation_count)
        @test hasproperty(fm, :revisits)
        @test hasproperty(fm, :skipped)
    end

    @testset "saccade_metrics" begin
        sm = saccade_metrics(df; selection = (trial = 1:5,))
        @test sm isa DataFrame
        @test nrow(sm) > 0
        @test hasproperty(sm, :trial)
        @test hasproperty(sm, :saccade_idx)
        @test hasproperty(sm, :max_curvature_px)
        @test hasproperty(sm, :amplitude_deg)
        @test hasproperty(sm, :curvature_ratio)
    end

    @testset "pupil_peak_metrics" begin
        # Needs trial relative time
        df_copy = deepcopy(df)
        df_copy.df[!, :time_rel] = df_copy.df.time
        pm = pupil_peak_metrics(df_copy; selection = (trial = 1:5,))
        @test pm isa DataFrame
        @test nrow(pm) > 0
        @test hasproperty(pm, :trial)
        @test hasproperty(pm, :max_pupil)
        @test hasproperty(pm, :time_to_peak)
    end

    @testset "scanpath_similarity" begin
        result = scanpath_similarity(
            df,
            aoi_regions;
            selection1 = (trial = 1,),
            selection2 = (trial = 2,),
        )
        @test result.distance isa Int
        @test 0.0 <= result.similarity <= 1.0
        @test result.seq1 isa String
        @test result.seq2 isa String

        # Same trial should have similarity 1.0
        same = scanpath_similarity(
            df,
            aoi_regions;
            selection1 = (trial = 1,),
            selection2 = (trial = 1,),
        )
        @test same.similarity == 1.0
    end

    @testset "time_bin" begin
        tb = time_bin(df; bin_ms = 100, measure = :pupil, selection = (trial = 1:3,))
        @test tb isa DataFrame
        @test nrow(tb) > 0
        @test hasproperty(tb, :time_bin)
        @test hasproperty(tb, :value)
        @test hasproperty(tb, :n)
    end

    @testset "proportion_of_looks" begin
        pol = proportion_of_looks(df, aoi_regions; bin_ms = 100, selection = (trial = 1:3,))
        @test pol isa DataFrame
        @test nrow(pol) > 0
        @test hasproperty(pol, :time_bin)
        @test hasproperty(pol, :outside)
        # Should have columns for each AOI name
        for aoi in aoi_regions
            @test hasproperty(pol, Symbol(aoi.name))
        end
    end

    @testset "velocity_filter!" begin
        df_copy = deepcopy(df)
        n_removed = velocity_filter!(df_copy; threshold_deg_s = 1000.0)
        @test n_removed isa Int
        @test n_removed >= 0
    end

    @testset "outlier_filter!" begin
        df_copy = deepcopy(df)
        n_removed = outlier_filter!(df_copy)
        @test n_removed isa Int
        @test n_removed >= 0
    end

    @testset "interpolate_gaps!" begin
        df_copy = deepcopy(df)
        n_filled = interpolate_gaps!(df_copy; max_gap_ms = 75)
        @test n_filled isa Int
        @test n_filled >= 0
    end

    @testset "group_summary" begin
        gs = group_summary(df)
        @test gs isa DataFrame
        @test nrow(gs) > 0
        @test hasproperty(gs, :trial)
        @test hasproperty(gs, :n_fixations)
        @test hasproperty(gs, :mean_fix_dur)
        @test hasproperty(gs, :n_saccades)
        @test hasproperty(gs, :n_blinks)
        @test hasproperty(gs, :tracking_loss_pct)
    end

    @testset "detect_microsaccades!" begin
        df2 = deepcopy(df)
        detect_microsaccades!(df2)
        @test hasproperty(df2.df, :in_msacc)
        @test hasproperty(df2.df, :msacc_ampl)
        @test hasproperty(df2.df, :msacc_pvel)
        @test hasproperty(df2.df, :msacc_dx)
        @test hasproperty(df2.df, :msacc_dy)
        # in_msacc should be a Bool vector
        @test eltype(df2.df.in_msacc) == Bool
    end

    @testset "prepare_analysis_data" begin
        pad = prepare_analysis_data(
            df;
            measures = [:pupil, :gaze_x],
            selection = (trial = 1:3,),
        )
        @test pad isa DataFrame
        @test nrow(pad) > 0
        @test hasproperty(pad, :time)
        @test hasproperty(pad, :sample)
        @test hasproperty(pad, :pupil)
        @test hasproperty(pad, :gaze_x)
        @test hasproperty(pad, :trial)
    end

    @testset "growth_curve_data" begin
        tb = time_bin(df; bin_ms = 100, measure = :pupil, selection = (trial = 1:3,))
        gcd = growth_curve_data(tb; degree = 3)
        @test gcd isa DataFrame
        @test hasproperty(gcd, :ot1)
        @test hasproperty(gcd, :ot2)
        @test hasproperty(gcd, :ot3)
        # ot columns should be normalized (mean ≈ 0)
        @test abs(mean(gcd.ot1)) < 0.1
    end

    @testset "batch_read via read_et_data" begin
        df_batch = read_et_data(
            [TEST1_EDF_PATH, TEST1_EDF_PATH]; # Mock multiple files
            participant_labels = ["p1", "p2"],
            trial_time_zero = nothing,
        )
        @test df_batch isa EyeData
        @test "p1" in df_batch.df.participant
        @test "p2" in df_batch.df.participant
        @test nrow(df_batch.df) == 2 * nrow(edf.samples)
    end

    @testset "Preprocessing, coordinate transforms, and AOI geometry" begin
        # detect_microsaccades! outputs degrees and deg/s and handles isolated NaNs
        n_ms = 400
        gx_ms = [500.0f0 + 0.05f0 * sin(0.2f0 * i) for i = 1:n_ms]
        gy_ms = [400.0f0 + 0.05f0 * cos(0.2f0 * i) for i = 1:n_ms]
        # Inject a ~18 px (~0.5 deg) microsaccade ramp over 12 ms at samples 180:191
        for k = 0:11
            gx_ms[180+k] = 500.0f0 + 18.0f0 * (k / 11.0f0)
        end
        for i = 192:n_ms
            gx_ms[i] += 18.0f0
        end
        gx_ms[50] = NaN32  # isolated NaN far from microsaccade
        ed_ms = EyeData(
            DataFrame(time = collect(1.0:n_ms), trial = fill(1, n_ms), gxL = gx_ms, gyL = gy_ms);
            sample_rate = 1000.0,
            screen_res = (1920, 1080),
            screen_width_cm = 53.0,
            viewing_distance_cm = 60.0,
        )
        ppd_ms = pixels_per_degree(ed_ms)
        detect_microsaccades!(ed_ms; eye = :left)
        @test any(ed_ms.df.in_msacc)
        valid_ms_ampl = filter(!isnan, ed_ms.df.msacc_ampl)
        @test !isempty(valid_ms_ampl)
        # 18 px / ~38 px/deg ≈ 0.47 deg
        @test all(a -> 0.1 < a < (30.0 / ppd_ms), valid_ms_ampl)

        # exclude_trials! with excluded trials and missing inter-trial rows
        ed_ex = EyeData(
            DataFrame(
                time = collect(1.0:10),
                trial = Union{Int,Missing}[missing, 1, 1, 1, 1, 2, 2, 2, 2, missing],
                gxL = Float32[500, 500, 500, 500, 500, NaN, NaN, NaN, NaN, 500],
                gyL = Float32[400, 400, 400, 400, 400, NaN, NaN, NaN, NaN, 400],
                paL = Float32[1000, 1000, 1000, 1000, 1000, NaN, NaN, NaN, NaN, 1000],
                in_blink = falses(10),
            );
            sample_rate = 1000.0,
        )
        ex_res = exclude_trials!(ed_ex; max_tracking_loss = 50.0)
        @test ex_res.n_before == 2
        @test ex_res.n_excluded == 1
        @test ex_res.n_after == 1
        @test !(2 in skipmissing(ed_ex.df.trial))
        @test count(ismissing, ed_ex.df.trial) == 2

        # drift_correct! updates fix_gavx/fix_gavy and sacc_gstx/sacc_genx consistently
        ed_dc = EyeData(
            DataFrame(
                time = [0.0, 1.0, 2.0, 3.0],
                trial = [1, 1, 1, 1],
                gxL = Float32[650, 650, 650, 750],
                gyL = Float32[490, 490, 490, 490],
                in_fix = [true, true, false, false],
                fix_gavx = [650.0, 650.0, NaN, NaN],
                fix_gavy = [490.0, 490.0, NaN, NaN],
                in_sacc = [false, false, true, true],
                sacc_gstx = [NaN, NaN, 650.0, 650.0],
                sacc_gsty = [NaN, NaN, 490.0, 490.0],
                sacc_genx = [NaN, NaN, 750.0, 750.0],
                sacc_geny = [NaN, NaN, 490.0, 490.0],
            ),
        )
        drift_correct!(ed_dc; target = (640, 480), window_ms = 2, eye = :left)
        @test ed_dc.df.gxL[1] ≈ 640.0f0
        @test ed_dc.df.fix_gavx[1] ≈ 640.0
        @test ed_dc.df.fix_gavy[1] ≈ 480.0
        @test ed_dc.df.sacc_gstx[3] ≈ 640.0
        @test ed_dc.df.sacc_genx[3] ≈ 740.0

        # to_center_coords! honors explicit eye=:left without mutating right eye
        ed_cc = EyeData(
            DataFrame(
                time = [1.0, 2.0],
                gxL = Float32[960, 1060],
                gyL = Float32[540, 440],
                gxR = Float32[960, 1060],
                gyR = Float32[540, 440],
            );
            screen_res = (1920, 1080),
        )
        ppd_cc = pixels_per_degree(ed_cc)
        to_center_coords!(ed_cc; eye = :left)
        @test ed_cc.df.gxL[1] ≈ 0.0f0
        @test ed_cc.df.gyL[2] ≈ Float32((440.0 - 540.0) / ppd_cc) atol = 1e-4
        @test ed_cc.df.gxR[1] ≈ 960.0f0

        # outlier_filter! flags gy outlier even when gx on the same row is NaN
        ed_of = EyeData(
            DataFrame(
                time = [1.0, 2.0, 3.0],
                gxL = Float32[500, NaN, 500],
                gyL = Float32[400, 9999, 400],
            );
            screen_res = (1920, 1080),
        )
        n_out = outlier_filter!(ed_of; eye = :left)
        @test n_out == 1
        @test isnan(ed_of.df.gyL[2])

        # Cubic blink interpolation, baseline correction modes, and smoothing across NaN gaps
        pa_cub = Float32[1000, 1002, 1004, 1006, 1008, NaN, NaN, NaN, 1016, 1018, 1020, 1022, 1024]
        ed_pup = EyeData(
            DataFrame(
                time = collect(0.0:12.0),
                time_rel = collect(0.0:12.0),
                trial = fill(1, 13),
                paL = copy(pa_cub),
                in_blink = Bool[0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0],
            );
            sample_rate = 1000.0,
        )
        interpolate_blinks!(ed_pup; method = :cubic, margin_ms = 0, eye = :left)
        @test !any(isnan, ed_pup.df.paL)
        @test ed_pup.df.paL[7] ≈ 1012.0f0 atol = 0.5f0

        # baseline_correct_pupil!: subtractive, percent, zscore, and 1-sample zscore guard
        for mode in (:subtractive, :percent, :zscore)
            ed_bc = deepcopy(ed_pup)
            baseline_correct_pupil!(ed_bc; window = (0.0, 3.0), method = mode, eye = :left)
            @test all(!isnan, ed_bc.df.paL)
        end
        ed_bc1 = deepcopy(ed_pup)
        baseline_correct_pupil!(ed_bc1; window = (0.0, 0.0), method = :zscore, eye = :left)
        @test !any(isnan, ed_bc1.df.paL) && ed_bc1.df.paL[1] == 1000.0f0

        # smooth_pupil! across a NaN gap longer than window_ms resets running sum
        ed_sm = EyeData(
            DataFrame(
                time = collect(1.0:30.0),
                paL = vcat(fill(1000.0f0, 8), fill(NaN32, 14), fill(500.0f0, 8)),
            );
            sample_rate = 1000.0,
        )
        smooth_pupil!(ed_sm; window_ms = 5, eye = :left)
        @test ed_sm.df.paL[26] ≈ 500.0f0 atol = 1e-4

        # EllipseAOI and PolygonAOI hit testing and aoi_metrics
        ell = EllipseAOI("Ell", 500, 400, 100, 50)
        poly = PolygonAOI("Tri", [(400.0, 300.0), (600.0, 300.0), (500.0, 500.0)])
        @test in_aoi(ell, 500, 400)
        @test !in_aoi(ell, 650, 400)
        @test in_aoi(poly, 500, 380)
        @test !in_aoi(poly, 410, 490)
        am_shapes = aoi_metrics(df, AOI[ell, poly]; selection = (trial = 1,))
        @test nrow(am_shapes) == 2

        # transition_matrix cross-trial isolation, .counts, and normalized transition_entropy
        aois_3 = [
            RectAOI("A", 100, 100, 100, 100),
            RectAOI("B", 300, 100, 100, 100),
            RectAOI("C", 500, 100, 100, 100),
        ]
        ed_tm = EyeData(
            DataFrame(
                time = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
                trial = [1, 1, 1, 2, 2, 2],
                in_fix = [true, false, true, true, false, true],
                fix_gavx = [100.0, NaN, 300.0, 500.0, NaN, 100.0],
                fix_gavy = [100.0, NaN, 100.0, 100.0, NaN, 100.0],
                fix_ava = [500.0, NaN, 500.0, 500.0, NaN, 500.0],
                fix_dur = [100, 0, 100, 100, 0, 100],
            ),
        )
        tm3 = transition_matrix(ed_tm, aois_3)
        # Trial 1: A -> B (counts[1,2] == 1); Trial 2: C -> A (counts[3,1] == 1); no cross-trial B -> C
        @test tm3.counts[1, 2] == 1
        @test tm3.counts[3, 1] == 1
        @test tm3.counts[2, 3] == 0
        # Uniform 3x3 AOI transition counts: normalized entropy == 1.0, unnormalized == log2(9)
        unif_tm = (matrix = fill(1.0 / 3.0, 3, 3), counts = ones(Int, 3, 3), labels = ["A", "B", "C"])
        @test transition_entropy(unif_tm; normalize = true) ≈ 1.0 atol = 1e-12
        @test transition_entropy(unif_tm; normalize = false) ≈ log2(9.0) atol = 1e-12

        # scanpath_similarity method & eye kwargs + velocity measure in time_bin & prepare_analysis_data
        ss = scanpath_similarity(
            df,
            aoi_regions;
            selection1 = (trial = 1,),
            selection2 = (trial = 2,),
            eye = :left,
            method = :levenshtein,
        )
        @test 0.0 <= ss.similarity <= 1.0
        @test_throws ErrorException scanpath_similarity(
            df,
            aoi_regions;
            selection1 = (trial = 1,),
            selection2 = (trial = 2,),
            method = :needleman_wunsch,
        )

        tb_vel = time_bin(df; bin_ms = 100, measure = :velocity, selection = (trial = 1:2,))
        @test nrow(tb_vel) > 0 && hasproperty(tb_vel, :value)

        pad_vel = prepare_analysis_data(df; measures = [:velocity], selection = (trial = 1:2,))
        @test nrow(pad_vel) > 0 && hasproperty(pad_vel, :velocity)
    end

    @testset "Trial boundaries, nested AOIs, entry counts, and variables" begin
        # velocity_filter! and interpolate_gaps! respect trial boundaries
        ed_bound = EyeData(
            DataFrame(
                participant = fill("P1", 40),
                trial = vcat(fill(1, 20), fill(2, 20)),
                time = collect(1.0:40.0),
                gxL = vcat(fill(100.0, 18), [NaN, NaN], fill(1500.0, 20)),
                gyL = vcat(fill(100.0, 18), [NaN, NaN], fill(900.0, 20)),
                paL = vcat(fill(1000.0, 20), fill(2000.0, 20)),
                in_blink = falses(40),
                message = fill("", 40),
            );
            sample_rate = 1000.0,
        )
        ed_vf = EyeData(
            DataFrame(
                participant = fill("P1", 40),
                trial = vcat(fill(1, 20), fill(2, 20)),
                time = collect(1.0:40.0),
                gxL = vcat(fill(100.0, 20), fill(1500.0, 20)),
                gyL = vcat(fill(100.0, 20), fill(900.0, 20)),
                paL = fill(1000.0, 40),
                message = fill("", 40),
            );
            sample_rate = 1000.0,
        )
        n_removed = velocity_filter!(ed_vf; threshold_deg_s = 500.0)
        @test n_removed == 0
        @test !any(isnan, ed_vf.df.gxL)

        n_interp = interpolate_gaps!(ed_bound; max_gap_ms = 50)
        @test n_interp == 0
        @test all(isnan, ed_bound.df.gxL[19:20])

        # smooth_pupil! preserves NaN gaps and isolates trials; interpolate_blinks! isolates trials
        ed_sp = EyeData(
            DataFrame(
                participant = fill("P1", 20),
                trial = vcat(fill(1, 10), fill(2, 10)),
                time = collect(1.0:20.0),
                paL = vcat([1000.0, 1000.0, 1000.0, NaN, NaN, 1000.0, 1000.0, 1000.0, 1000.0, 1000.0], fill(2000.0, 10)),
            );
            sample_rate = 1000.0,
        )
        smooth_pupil!(ed_sp; window_ms = 5)
        @test all(isnan, ed_sp.df.paL[4:5])
        @test ed_sp.df.paL[10] ≈ 1000.0
        @test ed_sp.df.paL[11] ≈ 2000.0

        ed_ib = EyeData(
            DataFrame(
                participant = fill("P1", 20),
                trial = vcat(fill(1, 10), fill(2, 10)),
                time = collect(1.0:20.0),
                paL = vcat(fill(1000.0, 8), [NaN, NaN], fill(5000.0, 10)),
                in_blink = vcat(falses(8), trues(2), falses(10)),
            );
            sample_rate = 1000.0,
        )
        interpolate_blinks!(ed_ib; margin_ms = 2)
        @test maximum(filter(!isnan, ed_ib.df.paL[1:10])) <= 1000.0 + 1e-6

        # Nested AOIs in fixation_metrics and proportion_of_looks + duplicate AOI guard
        nested_aois = AOI[
            RectAOI("Face", 500.0, 400.0, 400.0, 400.0),
            RectAOI("LeftEye", 500.0, 400.0, 80.0, 80.0),
        ]
        ed_nested = EyeData(
            DataFrame(
                participant = fill("P1", 10),
                trial = fill(1, 10),
                time = collect(0.0:9.0),
                gxL = fill(500.0, 10),
                gyL = fill(400.0, 10),
                in_fix = trues(10),
                fix_gavx = fill(500.0, 10),
                fix_gavy = fill(400.0, 10),
                fix_ava = fill(1000.0, 10),
                fix_dur = fill(10, 10),
                message = fill("", 10),
            );
            sample_rate = 1000.0,
        )
        fm_nested = fixation_metrics(ed_nested, nested_aois)
        @test all(==(1), fm_nested.fixation_count)
        pol_nested = proportion_of_looks(ed_nested, nested_aois; bin_ms = 10)
        @test pol_nested.Face[1] ≈ 1.0
        @test pol_nested.LeftEye[1] ≈ 1.0
        @test_throws ErrorException proportion_of_looks(
            ed_nested,
            AOI[RectAOI("Dup", 500, 400, 50, 50), RectAOI("Dup", 600, 400, 50, 50)];
            bin_ms = 10,
        )

        # Single-sample NaN glitch does not split AOI entry_count
        ed_glitch = EyeData(
            DataFrame(
                participant = fill("P1", 10),
                trial = fill(1, 10),
                time = collect(1.0:10.0),
                gxL = [500.0, 500.0, 500.0, 500.0, NaN, 500.0, 500.0, 500.0, 500.0, 500.0],
                gyL = [400.0, 400.0, 400.0, 400.0, NaN, 400.0, 400.0, 400.0, 400.0, 400.0],
                in_fix = trues(10),
                fix_gavx = fill(500.0, 10),
                fix_gavy = fill(400.0, 10),
                fix_ava = fill(1000.0, 10),
                fix_dur = fill(10, 10),
            );
            sample_rate = 1000.0,
        )
        am_glitch = aoi_metrics(ed_glitch, AOI[RectAOI("Target", 500.0, 400.0, 100.0, 100.0)])
        @test am_glitch.entry_count[1] == 1

        # drift_correct! defaults target to screen_res ./ 2
        ed_dc = EyeData(
            DataFrame(
                participant = fill("P1", 5),
                trial = fill(1, 5),
                time = collect(1.0:5.0),
                gxL = fill(780.0, 5),
                gyL = fill(610.0, 5),
                in_fix = trues(5),
                fix_gavx = fill(780.0, 5),
                fix_gavy = fill(610.0, 5),
                fix_ava = fill(1000.0, 5),
                fix_dur = fill(5, 5),
            );
            screen_res = (1600, 1200),
            sample_rate = 1000.0,
        )
        drift_correct!(ed_dc)
        @test ed_dc.df.gxL[1] ≈ 800.0
        @test ed_dc.df.gyL[1] ≈ 600.0

        # Multi-participant variables(ed) preserves per-participant trials
        ed_vars = EyeData(
            DataFrame(
                participant = ["P1", "P1", "P2", "P2"],
                trial = [1, 1, 1, 1],
                time = [1.0, 2.0, 1.0, 2.0],
                gxL = [100.0, 100.0, 200.0, 200.0],
                gyL = [100.0, 100.0, 200.0, 200.0],
                condition = ["A", "A", "B", "B"],
            ),
        )
        v_df = variables(ed_vars)
        @test nrow(v_df) == 2
        @test Set(v_df.condition) == Set(["A", "B"])
    end

    @testset "Tables.jl interface, eye=:both, prefixed events, and column time windows" begin
        # Metadata-preserving copy, filter, subset, constructor validation, show guards
        ed_meta = EyeData(
            DataFrame(
                participant = ["P1", "P1", "P1", "P1"],
                trial = [1, 1, 2, 2],
                time = [0.0, 2.0, 4.0, 6.0],
                gxL = [100.0, 110.0, 200.0, NaN],
                gyL = [300.0, 310.0, NaN, 400.0],
                paL = [1000.0, 1020.0, 1100.0, NaN],
                gxR = [120.0, NaN, 220.0, NaN],
                gyR = [320.0, 330.0, 420.0, NaN],
                paR = [1040.0, NaN, 1140.0, NaN],
                condition = ["A", "A", "B", "B"],
            );
            source = :smi,
            sample_rate = 500.0,
            screen_res = (1680, 1050),
            screen_width_cm = 47.4,
            viewing_distance_cm = 65.0,
        )

        ed_cp = copy(ed_meta)
        @test ed_cp isa EyeData
        @test ed_cp.source == :smi
        @test ed_cp.sample_rate == 500.0
        @test ed_cp.screen_res == (1680, 1050)
        @test ed_cp.screen_width_cm == 47.4
        @test ed_cp.viewing_distance_cm == 65.0
        ed_cp.df.gxL[1] = 999.0
        @test ed_meta.df.gxL[1] == 100.0

        ed_filt = filter(r -> r.trial == 1, ed_meta)
        @test ed_filt isa EyeData
        @test nrow(ed_filt) == 2
        @test ed_filt.sample_rate == 500.0 && ed_filt.screen_res == (1680, 1050)

        ed_sub = DataFrames.subset(ed_meta, :trial => ByRow(==(2)))
        @test ed_sub isa EyeData
        @test nrow(ed_sub) == 2
        @test ed_sub.screen_width_cm == 47.4

        @test_throws ArgumentError EyeData(DataFrame(time = [1.0]); sample_rate = 0.0)
        @test_throws ArgumentError EyeData(DataFrame(time = [1.0]); screen_res = (0, 1080))
        @test_throws ArgumentError EyeData(DataFrame(time = [1.0]); screen_width_cm = -1.0)
        @test_throws ArgumentError EyeData(DataFrame(time = [1.0]); viewing_distance_cm = 0.0)
        @test_throws ArgumentError RectAOI("bad", 100, 100, 0, 50)
        @test_throws ArgumentError CircleAOI("bad", 100, 100, -5)
        @test_throws ArgumentError EllipseAOI("bad", 100, 100, 10, 0)
        @test_throws ArgumentError PolygonAOI("bad", [(0, 0), (10, 10)])

        # Zero sample_rate Base.show guard on SMIFile & TobiiFile
        smi_zero = SMIFile("dummy.txt")
        smi_zero.samples = DataFrame(time = [1.0, 2.0], gxL = [100.0f0, 100.0f0])
        @test !occursin("Inf", sprint(show, MIME("text/plain"), smi_zero))
        tob_zero = TobiiFile("dummy.tsv")
        tob_zero.samples = DataFrame(time = [1.0, 2.0], gxL = [100.0f0, 100.0f0])
        @test !occursin("Inf", sprint(show, MIME("text/plain"), tob_zero))

        # Tables.jl and DataFrames interface
        @test DataFrames.Tables.istable(EyeData)
        @test DataFrames.Tables.columnaccess(EyeData)
        @test nrow(ed_meta) == 4
        @test ncol(ed_meta) == ncol(ed_meta.df)
        @test names(ed_meta) == names(ed_meta.df)
        df_conv = DataFrame(ed_meta)
        @test df_conv isa DataFrame && nrow(df_conv) == 4

        # average_eyes! and eye = :both
        ed_bino = copy(ed_meta)
        average_eyes!(ed_bino)
        @test ed_bino.df.gx[1] ≈ 110.0  # mean(100, 120)
        @test ed_bino.df.gx[2] ≈ 110.0  # fallback to L (R is NaN)
        @test isnan(ed_bino.df.gx[4])   # both NaN
        @test !hasproperty(variables(ed_bino), :gx)

        # eye = :both synthesizes binocular average when gx/gy/pa are absent
        dq_both = data_quality(ed_meta; eye = :both)
        @test nrow(dq_both) == 2
        tb_both = time_bin(ed_meta; eye = :both, bin_ms = 10, measure = :gaze_x)
        @test nrow(tb_both) > 0

        # Prefix end-to-end threading + symbol-tuple time_windows
        ed_pref = EyeData(
            DataFrame(
                participant = fill("P1", 200),
                trial = vcat(fill(1, 100), fill(2, 100)),
                time = vcat(collect(0.0:99.0), collect(0.0:99.0)),
                gxL = vcat(fill(200.0, 45), [200.0 + 40.0 * k for k = 1:5], fill(400.0, 50),
                           fill(200.0, 45), [200.0 + 40.0 * k for k = 1:5], fill(400.0, 50)),
                gyL = fill(300.0, 200),
                paL = vcat(fill(1000.0, 20), fill(1100.0, 80), fill(2000.0, 20), fill(2200.0, 80)),
                w_start = vcat(fill(0.0, 100), fill(0.0, 100)),
                w_end = vcat(fill(40.0, 100), fill(99.0, 100)),
                bl_lo = fill(0.0, 200),
                bl_hi = fill(19.0, 200),
                message = fill("", 200),
            );
            sample_rate = 1000.0,
        )
        detect_events!(ed_pref; method = :ivt, min_fixation_ms = 30, min_saccade_ms = 4, prefix = :ivt)
        aois_pref = AOI[
            RectAOI("Left", 200.0, 300.0, 80.0, 80.0),
            RectAOI("Right", 400.0, 300.0, 80.0, 80.0),
        ]
        am_p = aoi_metrics(ed_pref, aois_pref; prefix = :ivt)
        fm_p = fixation_metrics(ed_pref, aois_pref; prefix = :ivt)
        sm_p = saccade_metrics(ed_pref; prefix = :ivt)
        gs_p = group_summary(ed_pref; prefix = :ivt)
        @test sum(am_p.fixation_count) == 4
        @test sum(fm_p.fixation_count) == 4
        @test nrow(sm_p) == 2
        @test sum(gs_p.n_fixations) == 4

        # Symbol-tuple time_window in transition_matrix, scanpath_similarity, and baseline_correct_pupil!
        # Trial 1 window [0, 40] has only Left (0 transitions); Trial 2 window [0, 99] has Left -> Right (1 transition)
        tm_sym = transition_matrix(ed_pref, aois_pref; time_window = (:w_start, :w_end), prefix = :ivt)
        @test tm_sym.counts[1, 2] == 1.0
        ss_sym = scanpath_similarity(
            ed_pref,
            aois_pref;
            selection1 = (trial = 1,),
            selection2 = (trial = 2,),
            time_window = (:w_start, :w_end),
            prefix = :ivt,
        )
        @test ss_sym.seq1 == "A"
        @test ss_sym.seq2 == "AB"

        baseline_correct_pupil!(ed_pref; window = (:bl_lo, :bl_hi), method = :subtractive)
        @test ed_pref.df.paL[1] ≈ 0.0 atol = 1e-8
        @test ed_pref.df.paL[50] ≈ 100.0 atol = 1e-8
        @test ed_pref.df.paL[150] ≈ 200.0 atol = 1e-8

        # Prefixed plots & eye=:both plots execute cleanly
        @test plot_fixations(ed_pref; prefix = :ivt) isa Figure
        @test plot_heatmap(ed_pref; metric = :count, prefix = :ivt) isa Figure
        @test plot_velocity(ed_pref; prefix = :ivt) isa Figure
        @test plot_sequence(ed_pref; prefix = :ivt) isa Figure
        @test plot_gaze(ed_meta; eye = :both) isa Figure
        @test plot_pupil(ed_meta; eye = :both) isa Figure

        # Uniform create_eyefun_data kwargs on SMIFile & TobiiFile
        smi_kw = deepcopy(Main.TEST_SMI_TXT)
        smi_kw.samples.message[1] = "SYNC"
        ed_smi_kw = create_eyefun_data(
            smi_kw;
            trial_time_zero = "SYNC",
            screen_res = (1440, 900),
            screen_width_cm = 41.0,
            viewing_distance_cm = 58.0,
        )
        @test ed_smi_kw.screen_res == (1440, 900)
        @test ed_smi_kw.screen_width_cm == 41.0
        @test ed_smi_kw.viewing_distance_cm == 58.0
        @test hasproperty(ed_smi_kw.df, :time_rel)

        ed_tob_kw = create_eyefun_data(
            deepcopy(Main.TEST_TOBII_TSV);
            trial_time_zero = "RecordingStart",
            screen_res = (1600, 900),
            screen_width_cm = 44.0,
            viewing_distance_cm = 62.0,
        )
        @test ed_tob_kw.screen_res == (1600, 900)
        @test ed_tob_kw.screen_width_cm == 44.0
        @test ed_tob_kw.viewing_distance_cm == 62.0
        @test hasproperty(ed_tob_kw.df, :time_rel) && ed_tob_kw.df.time_rel[1] == 0.0

        # SubDataFrame selection on a non-initial trial
        @test all(==(2), aoi_metrics(ed_pref, aois_pref; selection = (trial = 2,), prefix = :ivt).trial)
        @test all(==(2), fixation_metrics(ed_pref, aois_pref; selection = (trial = 2,), prefix = :ivt).trial)
        @test all(==(2), saccade_metrics(ed_pref; selection = (trial = 2,), prefix = :ivt).trial)
        @test all(==(2), time_bin(ed_pref; selection = (trial = 2,), bin_ms = 25, measure = :velocity).trial)
        @test all(==(2), proportion_of_looks(ed_pref, aois_pref; selection = (trial = 2,), bin_ms = 25).trial)
        @test all(==(2), pupil_peak_metrics(ed_pref; selection = (trial = 2,)).trial)
        @test all(==(2), prepare_analysis_data(ed_pref; selection = (trial = 2,), measures = [:pupil, :gaze_x, :velocity], prefix = :ivt).trial)
    end

    @testset "Spatial precision, Savitzky-Golay smoothing, and DynamicAOI" begin
        # data_quality rms_s2s_deg and spatial_precision (RMS-S2S, fixation-demeaned STD, BCEA)
        dq_r = data_quality(df)
        @test hasproperty(dq_r, :rms_s2s_deg)
        @test any(isfinite, dq_r.rms_s2s_deg)

        # Trial 1: two distinct fixations at x=300 and x=900 with small jitter (±0.3 px)
        # Trial 2: higher jitter (±4.0 px)
        n_t = 200
        gx_t1 = vcat(
            [300.0 + 0.3 * sin(i) for i = 1:90],
            [300.0 + 60.0 * k for k = 1:10],
            [900.0 + 0.3 * cos(i) for i = 1:100],
        )
        gy_t1 = [400.0 + 0.3 * cos(1.3 * i) for i = 1:n_t]
        gx_t2 = [500.0 + 4.0 * sin(1.7 * i) for i = 1:n_t]
        gy_t2 = [400.0 + 4.0 * cos(1.9 * i) for i = 1:n_t]

        ed_prec = EyeData(
            DataFrame(
                participant = fill("P1", 2 * n_t),
                trial = vcat(fill(1, n_t), fill(2, n_t)),
                time = vcat(collect(0.0:(n_t-1)), collect(0.0:(n_t-1))),
                gxL = vcat(gx_t1, gx_t2),
                gyL = vcat(gy_t1, gy_t2),
                paL = fill(1000.0, 2 * n_t),
                message = fill("", 2 * n_t),
            );
            sample_rate = 1000.0,
        )
        detect_events!(ed_prec; method = :ivt, min_fixation_ms = 40)
        sp = spatial_precision(ed_prec)
        @test nrow(sp) == 2
        @test sp.rms_s2s_deg[1] < sp.rms_s2s_deg[2]
        @test sp.std_deg[1] < sp.std_deg[2]
        @test sp.bcea_deg2[1] < sp.bcea_deg2[2]
        # Per-fixation demeaning prevents the 600 px saccade jump in Trial 1 from inflating std_deg
        @test sp.std_deg[1] < 0.05
        @test_throws ArgumentError spatial_precision(ed_prec; bcea_prob = 1.0)

        # Savitzky-Golay filter quadratic reproduction, NaN preservation, and smooth_pupil!(:savgol)
        ts = collect(1.0:60.0)
        quad_exact = [250.0 + 3.0 * t - 0.04 * t^2 for t in ts]
        ed_sg = EyeData(
            DataFrame(
                participant = fill("P1", 60),
                trial = fill(1, 60),
                time = ts,
                gxL = copy(quad_exact),
                gyL = fill(400.0, 60),
                paL = [1000.0 + 2.0 * t - 0.02 * t^2 + 3.0 * (-1)^Int(t) for t in ts],
            );
            sample_rate = 1000.0,
        )
        savitzky_golay_filter!(ed_sg; window_samples = 11, poly_order = 2, cols = :gaze)
        @test maximum(abs.(ed_sg.df.gxL .- quad_exact)) < 1e-8

        ed_sg.df.paL[28:32] .= NaN
        smooth_pupil!(ed_sg; window_ms = 11, method = :savgol, poly_order = 2)
        @test all(isnan, ed_sg.df.paL[28:32])
        @test all(!isnan, ed_sg.df.paL[1:27])
        @test_throws ArgumentError savitzky_golay_filter!(ed_sg; window_samples = 10)
        @test_throws ArgumentError smooth_pupil!(ed_sg; method = :invalid)

        # Time-varying DynamicAOI across AOI metrics, scanpaths, and plots
        daoi = DynamicAOI(
            "MovingTarget",
            [
                (0.0, 49.0, RectAOI("EarlyPos", 200.0, 300.0, 80.0, 80.0)),
                (50.0, 99.0, RectAOI("LatePos", 600.0, 300.0, 80.0, 80.0)),
            ],
        )
        static_other = RectAOI("Distractor", 600.0, 300.0, 80.0, 80.0)
        @test in_aoi(daoi, 200.0, 300.0, 25.0)
        @test !in_aoi(daoi, 200.0, 300.0, 75.0)
        @test in_aoi(daoi, 600.0, 300.0, 75.0)
        @test in_aoi(daoi, 200.0, 300.0) && in_aoi(daoi, 600.0, 300.0)
        @test occursin("DynamicAOI", sprint(show, daoi))
        @test_throws ArgumentError DynamicAOI("Empty", Tuple{Float64,Float64,AOI}[])
        @test_throws ArgumentError DynamicAOI("BadOrder", [(50.0, 10.0, static_other)])

        # Trial 1: gaze stays at (200, 300) for 100 ms -> inside MovingTarget during 0..49 ms (50 ms)
        # Trial 2: gaze at (200, 300) for 0..44 ms, saccade, then (600, 300) for 55..99 ms
        ed_dyn = EyeData(
            DataFrame(
                participant = fill("P1", 200),
                trial = vcat(fill(1, 100), fill(2, 100)),
                time = vcat(collect(0.0:99.0), collect(0.0:99.0)),
                gxL = vcat(
                    fill(200.0, 100),
                    fill(200.0, 45),
                    [200.0 + 40.0 * k for k = 1:10],
                    fill(600.0, 45),
                ),
                gyL = fill(300.0, 200),
                paL = fill(1000.0, 200),
                message = fill("", 200),
            );
            sample_rate = 1000.0,
        )
        detect_events!(ed_dyn; method = :ivt, min_fixation_ms = 30, min_saccade_ms = 5)
        aois_dyn = AOI[daoi, static_other]

        am_d = aoi_metrics(ed_dyn, aois_dyn)
        @test am_d.dwell_time_ms[1] == 50.0
        @test am_d.fixation_count[3] == 2

        fm_d = fixation_metrics(ed_dyn, aois_dyn)
        @test fm_d.fixation_count[1] == 1
        @test fm_d.fixation_count[3] == 2

        pol_d = proportion_of_looks(ed_dyn, aois_dyn; selection = (trial = 1,), bin_ms = 50)
        @test pol_d.MovingTarget[1] == 1.0
        @test pol_d.MovingTarget[2] == 0.0

        tm_d = transition_matrix(ed_dyn, aois_dyn; selection = (trial = 2,))
        @test tm_d.counts[1, 1] == 1.0

        ss_d = scanpath_similarity(
            ed_dyn,
            aois_dyn;
            selection1 = (trial = 1,),
            selection2 = (trial = 2,),
        )
        @test ss_d.seq1 == "A"
        @test ss_d.seq2 == "AA"

        @test plot_scanpath(ed_dyn; selection = (trial = 2,), aois = aois_dyn) isa Figure
        @test plot_dwell(ed_dyn, aois_dyn; selection = (trial = 1,)) isa Figure

        # Exported symbols docstring check (matches Documenter checkdocs = :exports)
        if isdefined(Base.Docs, :undocumented_names)
            @test isempty(Base.Docs.undocumented_names(EyeFun))
        end
    end
end
