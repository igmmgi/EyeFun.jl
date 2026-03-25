# ════════════════════════════════════════════════════════════════════════════ #
#  7. Event accessors: variables, saccades, fixations, blinks, messages, aois
# ════════════════════════════════════════════════════════════════════════════ #

@testset "Event accessors" begin
    edf_path = joinpath(DATA_DIR, "test1.edf")
    isfile(edf_path) || @warn "test1.edf not found"

    if isfile(edf_path)
        edf = read_eyelink_edf(edf_path)

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
    end
end
