# ════════════════════════════════════════════════════════════════════════════ #
#  ASC reader: can re-read our own output
# ════════════════════════════════════════════════════════════════════════════ #

@testset "ASC reader reads Julia output" begin
    for test_name in ("test1", "test2", "test3")
        file_path = joinpath(DATA_DIR_EYELINK, "$(test_name)_julia.asc")
        @testset "$test_name" begin
            edf = EyeFun.read_eyelink(file_path)

            @test edf isa EyeFun.EDFFile
            @test !isnothing(edf.samples)
            @test nrow(edf.samples) > 0
            @test nrow(EyeFun.parse_fixations(edf.events)) > 0
            @test nrow(EyeFun.parse_saccades(edf.events)) > 0
        end
    end
end

# ════════════════════════════════════════════════════════════════════════════ #
#  read_et dispatcher
# ════════════════════════════════════════════════════════════════════════════ #

@testset "read_eyelink dispatcher" begin
    edf_file_path = joinpath(DATA_DIR_EYELINK, "test1.edf")
    asc_file_path = joinpath(DATA_DIR_EYELINK, "test1.asc")

    edf_file = EyeFun.read_eyelink(edf_file_path)
    @test edf_file isa EyeFun.EDFFile
    @test !isnothing(edf_file.samples)

    asc_file = EyeFun.read_eyelink(asc_file_path)
    @test asc_file isa EyeFun.EDFFile
    @test !isnothing(asc_file.samples)

    @test_throws ErrorException EyeFun.read_eyelink("file.xyz")
end

# ════════════════════════════════════════════════════════════════════════════ #
#  read_et_dataframe
# ════════════════════════════════════════════════════════════════════════════ #

@testset "create_eyefun_data (EDF from file)" begin
    edf_file_path = joinpath(DATA_DIR_EYELINK, "test1.edf")
    asc_file_path = joinpath(DATA_DIR_EYELINK, "test1.asc")

    edf_file = read_et_data(edf_file_path)
    @test edf_file isa EyeData
    @test nrow(edf_file.df) > 0
    @test hasproperty(edf_file.df, :sacc_ampl)
    @test hasproperty(edf_file.df, :blink_dur)
    @test hasproperty(edf_file.df, :message)

    asc_file = read_et_data(asc_file_path)
    @test asc_file isa EyeData
    @test nrow(asc_file.df) > 0

end
