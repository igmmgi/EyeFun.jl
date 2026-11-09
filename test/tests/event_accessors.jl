@testset "Event accessors" begin
    ed = Main.TEST1_DF

    @testset "fixations" begin
        fix = fixations(ed)
        @test fix isa DataFrame
        @test nrow(fix) > 0
        @test hasproperty(fix, :gavx)
        @test hasproperty(fix, :gavy)
    end

    @testset "saccades" begin
        sac = saccades(ed)
        @test sac isa DataFrame
        @test nrow(sac) > 0
        @test hasproperty(sac, :gstx)
    end

    @testset "blinks" begin
        bl = blinks(ed)
        @test bl isa DataFrame
        @test nrow(bl) > 0
    end

    @testset "messages" begin
        msg = messages(ed)
        @test msg isa DataFrame
        @test nrow(msg) > 0
        @test hasproperty(msg, :message)
        @test hasproperty(msg, :time)
    end

    @testset "messages summary" begin
        summary = messages(ed; summary = true)
        @test summary isa DataFrame
        @test nrow(summary) > 0
        @test hasproperty(summary, :message)
        @test hasproperty(summary, :count)
    end

    @testset "variables" begin
        vars = variables(ed)
        @test vars isa DataFrame
        # test data may have no trial variables → empty DataFrame is valid
        if nrow(vars) > 0
            @test hasproperty(vars, :trial)
            # Values should be stripped of leading/trailing whitespace
            for col in names(vars)
                col in ("trial", "sttime_min", "sttime_max") && continue
                vals = vars[!, col]
                for v in vals
                    v isa String && @test v == strip(v)
                end
            end
        end
    end

    @testset "Edge cases" begin
        @testset "Message parsing with null bytes" begin
            # messages on EyeData should have no null bytes (cleaned during create_eyefun_data)
            msg_df = messages(ed)
            @test nrow(msg_df) > 0
            for m in msg_df.message
                @test !occursin('\0', m)
            end
        end

        @testset "Empty parser inputs" begin
            empty_events = DataFrame()
            @test nrow(EyeFun.parse_fixations(empty_events)) == 0
            @test nrow(EyeFun.parse_saccades(empty_events)) == 0
            @test nrow(EyeFun.parse_blinks(empty_events)) == 0
            @test nrow(EyeFun.parse_messages(empty_events)) == 0
        end

        @testset "Empty EyeData messages" begin
            # EyeData with no message column
            empty_ed = EyeData(DataFrame(time = [1.0]))
            @test nrow(messages(empty_ed)) == 0

            # EyeData with all-empty messages
            empty_msg_ed = EyeData(DataFrame(time = [1.0, 2.0], message = ["", ""]))
            @test nrow(messages(empty_msg_ed)) == 0
        end

        @testset "counts, variables filtering, and sub-1000 Hz fallback duration" begin
            @test counts(ed.df.in_fix) == nrow(fixations(ed))
            @test counts(ed.df.in_sacc) == nrow(saccades(ed))
            @test counts(ed.df.in_blink) == nrow(blinks(ed))

            # variables(ed) must return only trial-level variable columns, never sample/msacc columns
            ed_vars = EyeData(
                DataFrame(
                    time = [0.0, 2.0, 4.0, 6.0],
                    trial = [1, 1, 2, 2],
                    gxL = Float32[100, 102, 200, 205],
                    gyL = Float32[100, 101, 200, 202],
                    paL = Float32[500, 505, 510, 512],
                    in_fix = [true, false, true, false],
                    fix_gavx = [100.0, NaN, 200.0, NaN],
                    fix_gavy = [100.0, NaN, 200.0, NaN],
                    fix_ava = [500.0, NaN, 510.0, NaN],
                    fix_dur = [0, 0, 0, 0],
                    in_msacc = [false, true, false, false],
                    msacc_ampl = [NaN, 0.4, NaN, NaN],
                    condition = ["easy", "easy", "hard", "hard"],
                );
                sample_rate = 500.0,
            )
            vdf = variables(ed_vars)
            @test nrow(vdf) == 2
            @test hasproperty(vdf, :condition)
            @test !hasproperty(vdf, :gxL)
            @test !hasproperty(vdf, :in_msacc)
            @test !hasproperty(vdf, :msacc_ampl)

            # Single-sample fixation with fix_dur == 0 at 500 Hz must have duration 2.0 ms (not 1.0 ms)
            f_single = fixations(ed_vars)
            @test nrow(f_single) == 2
            @test all(d -> d ≈ 2.0, f_single.duration)
        end
    end
end
