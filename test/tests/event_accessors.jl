# ════════════════════════════════════════════════════════════════════════════ #
#  Event accessors: variables, saccades, fixations, blinks, messages, aois
# ════════════════════════════════════════════════════════════════════════════ #

@testset "Event accessors" begin
    edf = Main.TEST1_EDF

    @testset "fixations" begin
        fix = fixations(edf)
        @test fix isa DataFrame
        @test nrow(fix) > 0
        @test hasproperty(fix, :gavx)
        @test hasproperty(fix, :gavy)
    end

    @testset "saccades" begin
        sac = saccades(edf)
        @test sac isa DataFrame
        @test nrow(sac) > 0
        @test hasproperty(sac, :gstx)
    end

    @testset "blinks" begin
        bl = blinks(edf)
        @test bl isa DataFrame
        @test nrow(bl) > 0
    end

    @testset "messages" begin
        msg = messages(edf)
        @test msg isa DataFrame
        @test nrow(msg) > 0
        @test hasproperty(msg, :message)
    end

    @testset "variables" begin
        vars = variables(edf)
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
            msg_df = messages(edf)
            @test nrow(msg_df) > 0

            # No message should contain null bytes after parsing
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
    end
end
