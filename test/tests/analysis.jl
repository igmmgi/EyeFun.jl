# ════════════════════════════════════════════════════════════════════════════ #
#  9. Analysis functions
# ════════════════════════════════════════════════════════════════════════════ #

@testset "Analysis functions" begin
    edf_path = joinpath(DATA_DIR, "test1.edf")
    isfile(edf_path) || @warn "test1.edf not found"

    if isfile(edf_path)
        edf = read_eyelink_edf_binary(edf_path)
        df = create_eyelink_edf_dataframe(edf; trial_time_zero = nothing)

        aoi_regions = Dict("Center" => (440, 280, 840, 680), "TopLeft" => (0, 0, 320, 240))

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
            df2 = EyeData(copy(df.df))
            pa_col = hasproperty(df2.df, :paL) && !all(isnan, df2.df.paL) ? :paL : :paR
            nan_before = count(isnan, df2.df[!, pa_col])
            interpolate_blinks!(df2)
            nan_after = count(isnan, df2.df[!, pa_col])
            # Should reduce NaN count (blinks replaced with interpolated values)
            @test nan_after <= nan_before
        end

        @testset "smooth_pupil!" begin
            df2 = EyeData(copy(df.df))
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
            df2 = EyeData(copy(df.df))
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
            df2 = EyeData(copy(df.df))
            detect_microsaccades!(df2)
            @test hasproperty(df2.df, :in_msacc)
            @test hasproperty(df2.df, :msacc_ampl)
            @test hasproperty(df2.df, :msacc_pvel)
            @test hasproperty(df2.df, :msacc_dx)
            @test hasproperty(df2.df, :msacc_dy)
            # in_msacc should be a Bool vector
            @test eltype(df2.df.in_msacc) == Bool
        end

        @testset "batch_read_eyelink_edf_dataframe" begin
            # Read the same file twice as two "participants"
            df_batch = batch_read_eyelink_edf_dataframe(
                [edf_path, edf_path];
                participant_labels = ["sub01", "sub02"],
            )
            @test df_batch isa EyeData
            @test hasproperty(df_batch.df, :participant)
            @test Set(df_batch.df.participant) == Set(["sub01", "sub02"])
            @test nrow(df_batch.df) == 2 * nrow(edf.samples)
        end
    end
end
