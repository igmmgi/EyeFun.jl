# ════════════════════════════════════════════════════════════════════════════ #
#  ASC reader: can re-read our own output
# ════════════════════════════════════════════════════════════════════════════ #

@testset "ASC reader reads Julia output" begin
    for test_name in ("test1", "test2", "test3")
        jul_path = joinpath(DATA_DIR_EYELINK, "$(test_name)_julia.asc")
        isfile(jul_path) || continue

        @testset "$test_name" begin
            edf = EyeFun.read_eyelink(jul_path)

            @test edf isa EyeFun.EDFFile
            @test !isnothing(edf.samples)
            @test nrow(edf.samples) > 0
            @test nrow(fixations(edf)) > 0
            @test nrow(saccades(edf)) > 0
        end
    end
end
