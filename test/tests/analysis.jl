# ════════════════════════════════════════════════════════════════════════════ #
#  Analysis functions
# ════════════════════════════════════════════════════════════════════════════ #

@testset "Analysis functions" begin
    edf = Main.TEST1_EDF
    df = Main.TEST1_DF
    edf_path = Main.TEST1_EDF_PATH

    aoi_regions =
            [RectAOI("Center", 440, 280, 840, 680), RectAOI("TopLeft", 0, 0, 320, 240)]

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
            result = exclude_trials!(df_copy; max_tracking_loss = 50.0, verbose = false)
            @test result.n_before == n_before
            @test result.n_after <= n_before
            @test result.n_excluded >= 0
        end

        @testset "transition_matrix" begin
            tm = transition_matrix(df, aoi_regions; selection = (trial = 1:5,))
            @test tm.matrix isa Matrix{Float64}
            @test length(tm.labels) == length(aoi_regions)
            @test size(tm.matrix) == (length(aoi_regions), length(aoi_regions))
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
            pol = proportion_of_looks(
                df,
                aoi_regions;
                bin_ms = 100,
                selection = (trial = 1:3,),
            )
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
            # Using the new polymorphic entry point for a batch of files
            df_batch = read_et_data(
                [TEST1_EDF_PATH, TEST1_EDF_PATH]; # Mock multiple files
                participant_labels=["p1", "p2"],
                verbose=false,
                trial_time_zero=nothing
            )
            @test df_batch isa EyeData
            @test "p1" in df_batch.df.participant
            @test "p2" in df_batch.df.participant
            @test nrow(df_batch.df) == 2 * nrow(edf.samples)
        end
end
