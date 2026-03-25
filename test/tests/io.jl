# ════════════════════════════════════════════════════════════════════════════ #
#  4. read_et dispatcher
# ════════════════════════════════════════════════════════════════════════════ #

@testset "read_eyelink dispatcher" begin
    edf_path = joinpath(DATA_DIR, "test1.edf")
    asc_path = joinpath(DATA_DIR, "test1.asc")

    if isfile(edf_path)
        edf = read_eyelink(edf_path)
        @test edf isa EyeFun.EDFFile
        @test edf.samples !== nothing
    end

    if isfile(asc_path)
        asc = read_eyelink(asc_path)
        @test asc isa EyeFun.EDFFile
        @test asc.samples !== nothing
    end

    @test_throws ErrorException read_eyelink("file.xyz")
end


# ════════════════════════════════════════════════════════════════════════════ #
#  6. read_et_dataframe
# ════════════════════════════════════════════════════════════════════════════ #

@testset "create_eyelink_edf_dataframe (from file)" begin
    edf_path = joinpath(DATA_DIR, "test1.edf")
    asc_path = joinpath(DATA_DIR, "test1.asc")

    if isfile(edf_path)
        df = create_eyelink_edf_dataframe(read_eyelink(edf_path))
        @test df isa EyeData
        @test nrow(df.df) > 0
        @test hasproperty(df.df, :sacc_ampl)
        @test hasproperty(df.df, :blink_dur)
        @test hasproperty(df.df, :message)
    end

    if isfile(asc_path)
        df = create_eyelink_edf_dataframe(read_eyelink(asc_path))
        @test df isa EyeData
        @test nrow(df.df) > 0
    end
end
