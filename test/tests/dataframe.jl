@testset "create_eyefun_data" begin
    edf = Main.TEST1_EDF
    df = Main.TEST1_DF

    @test df isa EyeData
    @test nrow(df.df) == nrow(edf.samples)

    for col in [
        :time,
        :gxL,
        :gyL,
        :paL,
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
        :in_blink,
        :blink_dur,
        :message,
    ]
        @test hasproperty(df.df, col)
    end

    @test any(df.df.in_fix)
    @test any(df.df.in_sacc)
    @test any(df.df.in_blink)

    sacc_rows = df.df[df.df.in_sacc, :]
    @test any(!isnan, sacc_rows.sacc_ampl)
    @test any(!isnan, sacc_rows.sacc_pvel)
    @test any(>(0), df.df[df.df.in_blink, :blink_dur])
    @test any(!isempty, df.df.message)

    @testset "copycols=false safety" begin
        @test eltype(edf.samples.time) == UInt32
        @test eltype(edf.samples.gxL) == Float32
        @test eltype(edf.samples.flags) == UInt16
        @test all(t -> t > UInt32(0), edf.samples.time)

        @test nrow(edf.events) > 0
        @test hasproperty(edf.events, :type)
        @test hasproperty(edf.events, :sttime)
        @test hasproperty(edf.events, :message)

        ed = EyeFun.create_eyefun_data(edf; trial_time_zero = nothing)
        original_time_first = edf.samples.time[1]

        # Mutating the result should not corrupt the EDFFile (including Float32 gaze columns)
        orig_gxl_first = edf.samples.gxL[1]
        ed.df.in_fix[1] = !ed.df.in_fix[1]
        ed.df.gxL[1] = 99999.0f0
        @test !isnothing(edf.samples)
        @test edf.samples.time[1] == original_time_first
        @test (isnan(orig_gxl_first) && isnan(edf.samples.gxL[1])) ||
              edf.samples.gxL[1] == orig_gxl_first
        @test eltype(ed.df.time) == Float64
    end

    @testset "Sub-1000 Hz message snapping, missing trials, and GAZE_COORDS" begin
        # 500 Hz recording: sample timestamps step by 2 ms (1000, 1002, 1004, 1006, 1008)
        samples_500 = DataFrame(
            time = UInt32[998, 1000, 1002, 1004, 1006, 1008],
            trial = Union{Int,Missing}[missing, 1, 1, 1, 1, 1],
            gxL = Float32[500, 500, 500, 500, 500, 500],
            gyL = Float32[400, 400, 400, 400, 400, 400],
            paL = Float32[1000, 1000, 1000, 1000, 1000, 1000],
            gxR = fill(NaN32, 6),
            gyR = fill(NaN32, 6),
            paR = fill(NaN32, 6),
            flags = fill(UInt16(0), 6),
        )
        events_500 = DataFrame(
            type = UInt16[24, 24, 24, 24, 24],  # MESSAGEEVENT = 24
            eye = UInt8[0, 0, 0, 0, 0],
            sttime = UInt32[998, 1000, 1003, 1004, 1008],
            entime = UInt32[0, 0, 0, 0, 0],
            gstx = fill(NaN32, 5),
            gsty = fill(NaN32, 5),
            genx = fill(NaN32, 5),
            geny = fill(NaN32, 5),
            gavx = fill(NaN32, 5),
            gavy = fill(NaN32, 5),
            ava = fill(NaN32, 5),
            avel = fill(NaN32, 5),
            pvel = fill(NaN32, 5),
            svel = fill(NaN32, 5),
            evel = fill(NaN32, 5),
            sta = fill(NaN32, 5),
            ena = fill(NaN32, 5),
            hstx = fill(NaN32, 5),
            hsty = fill(NaN32, 5),
            henx = fill(NaN32, 5),
            heny = fill(NaN32, 5),
            havx = fill(NaN32, 5),
            havy = fill(NaN32, 5),
            supd_x = fill(NaN32, 5),
            supd_y = fill(NaN32, 5),
            eupd_x = fill(NaN32, 5),
            eupd_y = fill(NaN32, 5),
            status = fill(UInt16(0), 5),
            flags = fill(UInt16(0), 5),
            input = fill(UInt16(0), 5),
            buttons = fill(UInt16(0), 5),
            parsedby = fill(UInt16(0), 5),
            message = [
                "GAZE_COORDS 0.00 0.00 1023.00 767.00",
                "TRIALID 1",
                "STIM_ONSET",
                "!V TRIAL_VAR cond congruent",
                "TRIAL OK",
            ],
        )
        recs_500 = DataFrame(
            time = UInt32[998],
            sample_rate = Float32[500.0],
            eflags = UInt16[0],
            sflags = UInt16[0],
            state = UInt8[1],
            record_type = UInt8[3],
            pupil_type = UInt8[0],
            recording_mode = UInt8[0],
            filter_type = UInt8[2],
            pos_type = UInt8[0],
            eye = UInt8[1],
        )
        syn_edf = EyeFun.EDFFile("syn500.edf")
        syn_edf.samples = samples_500
        syn_edf.events = events_500
        syn_edf.recordings = recs_500
        syn_edf.sample_rate = 500.0
        syn_ed = create_eyefun_data(syn_edf; trial_time_zero = nothing)

        # GAZE_COORDS detected (0..1023, 0..767 => 1024×768)
        @test syn_ed.screen_res == (1024, 768)
        # Odd-timestamp message 1003 snapped to 1-ms-adjacent sample instead of being dropped
        @test any(m -> occursin("STIM_ONSET", m), syn_ed.df.message)
        # Inter-trial sample at t=998 has missing trial, while trial 1 gets trial variable joined cleanly
        @test ismissing(syn_ed.df.trial[1])
        @test ismissing(syn_ed.df.cond[1])
        @test syn_ed.df.cond[2] == "congruent"
    end
end
