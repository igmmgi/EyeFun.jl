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

@testset "EyeFile protocol, ASC eye modes, and read_et_data dispatch" begin
    edf = Main.TEST1_EDF
    asc = Main.TEST1_ASC
    smi = Main.TEST_SMI_TXT
    tob = Main.TEST_TOBII_TSV

    # Exported types & EyeFile metadata contract
    @test edf isa EDFFile
    @test edf isa EyeFile
    @test smi isa SMIFile
    @test smi isa EyeFile
    @test tob isa TobiiFile
    @test tob isa EyeFile
    @test edf.sample_rate > 0
    @test edf.screen_res[1] > 0 && edf.screen_res[2] > 0

    # EyeData(raw) convenience constructor on all EyeFile subtypes
    ed_from_edf = EyeData(edf; trial_time_zero = nothing)
    @test ed_from_edf isa EyeData
    @test nrow(ed_from_edf.df) == nrow(edf.samples)

    ed_from_smi = EyeData(smi)
    @test ed_from_smi isa EyeData
    @test ed_from_smi.source == :smi

    ed_from_tob = EyeData(tob)
    @test ed_from_tob isa EyeData
    @test ed_from_tob.source == :tobii

    # Left-monocular ASC (test1.asc has START ... LEFT SAMPLES EVENTS) must populate gxL, not gxR
    @test any(!isnan, asc.samples.gxL)
    @test all(isnan, asc.samples.gxR)

    # Binocular ASC with single-eye blink ("." on right eye only) must preserve valid left-eye gaze
    tmp_asc = tempname() * ".asc"
    try
        write(
            tmp_asc,
            """
            MSG\t1000 DISPLAY_COORDS 0 0 1919 1079
            START\t1000 \tLEFT\tRIGHT\tSAMPLES\tEVENTS
            SAMPLES\tGAZE\tLEFT\tRIGHT\tRATE\t1000.00
            1000\t  512.5\t  384.0\t 1200.0\t  515.0\t  386.0\t 1180.0\t.....
            1001\t  513.0\t  385.0\t 1205.0\t   .\t   .\t    0.0\t.....
            END\t1002 \tSAMPLES\tEVENTS\tRES\t  35.00\t  35.00
            """,
        )
        bino_asc = read_eyelink(tmp_asc)
        @test bino_asc.samples.gxL[2] ≈ 513.0f0
        @test bino_asc.samples.gyL[2] ≈ 385.0f0
        @test isnan(bino_asc.samples.gxR[2])
        @test isnan(bino_asc.samples.gyR[2])
    finally
        isfile(tmp_asc) && rm(tmp_asc)
    end

    # read_et_data auto-dispatches SMI .txt and forwards kwargs cleanly
    ed_smi_auto = read_et_data(Main.TEST_SMI_TXT_PATH)
    @test ed_smi_auto isa EyeData
    @test ed_smi_auto.source == :smi

    ed_kw = read_et_data(
        Main.TEST1_EDF_PATH;
        include_variables = false,
        trial_time_zero = nothing,
        screen_res = (1600, 900),
    )
    @test ed_kw.screen_res == (1600, 900)

    # Error messages interpolate extension properly (no literal "$ext")
    err_msg = try
        read_et_data("nonexistent.unsupported_ext")
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin(".unsupported_ext", err_msg)
    @test !occursin("\$ext", err_msg)

    @testset "Binocular event eye filtering & physical geometry forwarding" begin
        edf3 = read_eyelink(joinpath(DATA_DIR_EYELINK, "test3.edf"))
        edf3.screen_width_cm = 51.5
        edf3.viewing_distance_cm = 65.0

        ed3_l = create_eyefun_data(edf3; eye = :left, trial_time_zero = nothing)
        ed3_r = create_eyefun_data(edf3; eye = :right, trial_time_zero = nothing)
        @test ed3_l.screen_width_cm == 51.5
        @test ed3_l.viewing_distance_cm == 65.0

        raw_fix = EyeFun.parse_fixations(edf3.events)
        n_raw_l = count(==(EyeFun.EYE_LEFT), raw_fix.eye)
        n_raw_r = count(==(EyeFun.EYE_RIGHT), raw_fix.eye)
        @test abs(nrow(fixations(ed3_l)) - n_raw_l) <= 10
        @test abs(nrow(fixations(ed3_r)) - n_raw_r) <= 10
        @test !any(ed3_l.df.in_fix .& ed3_l.df.in_sacc)
        @test !any(ed3_r.df.in_fix .& ed3_r.df.in_sacc)
    end
end
