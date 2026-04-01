# ════════════════════════════════════════════════════════════════════════════ #
#  read_et dispatcher
# ════════════════════════════════════════════════════════════════════════════ #

@testset "read_eyelink dispatcher" begin
    edf_path = joinpath(DATA_DIR_EYELINK, "test1.edf")
    asc_path = joinpath(DATA_DIR_EYELINK, "test1.asc")

    if isfile(edf_path)
        edf = EyeFun.read_eyelink(edf_path)
        @test edf isa EyeFun.EDFFile
        @test !isnothing(edf.samples)
    end

    if isfile(asc_path)
        asc = EyeFun.read_eyelink(asc_path)
        @test asc isa EyeFun.EDFFile
        @test !isnothing(asc.samples)
    end

    @test_throws ErrorException EyeFun.read_eyelink("file.xyz")
end


# ════════════════════════════════════════════════════════════════════════════ #
#  read_et_dataframe
# ════════════════════════════════════════════════════════════════════════════ #

@testset "create_eyefun_data (EDF from file)" begin
    edf_path = joinpath(DATA_DIR_EYELINK, "test1.edf")
    asc_path = joinpath(DATA_DIR_EYELINK, "test1.asc")

    if isfile(edf_path)
        df = read_et_data(edf_path)
        @test df isa EyeData
        @test nrow(df.df) > 0
        @test hasproperty(df.df, :sacc_ampl)
        @test hasproperty(df.df, :blink_dur)
        @test hasproperty(df.df, :message)
    end

    if isfile(asc_path)
        df = read_et_data(asc_path)
        @test df isa EyeData
        @test nrow(df.df) > 0
    end
end
