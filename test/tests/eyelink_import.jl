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

@testset "Binary EDF 0x21 payload collisions, ENDBLINK entime, and 1000 Hz message snap" begin
    be_u16(x::Integer) = UInt8[(UInt16(x) >> 8) & 0xff, UInt16(x) & 0xff]
    be_u32(x::Integer) = UInt8[
        (UInt32(x) >> 24) & 0xff,
        (UInt32(x) >> 16) & 0xff,
        (UInt32(x) >> 8) & 0xff,
        UInt32(x) & 0xff,
    ]
    msg_pkt(ts::Integer, txt::String) = vcat(
        UInt8[0x18, 0x00, 0x21],
        be_u32(ts),
        UInt8[0x5e],
        be_u16(ncodeunits(txt)),
         Vector{UInt8}(codeunits(txt)),
        UInt8[0x00],
    )

    rec_payload = zeros(UInt8, 29)
    rec_payload[1] = 0x01 # RECORDING_START
    rec_payload[2:3] = be_u16(1000) # 1000 Hz
    rec_payload[27:28] = be_u16(0x8500) # Left eye (0x8000) + gaze (0x0400) + pupil (0x0100)

    raw_edf_bytes = vcat(
        Vector{UInt8}(codeunits("** SYNTHETIC REGRESSION EDF\nENDP:\n")),
        # STARTSAMPLES at ts = 1000
        UInt8[0x0f, 0x00, 0x41],
        be_u32(1000),
        rec_payload,
        # TRIALID 1 message at ts = 1000
        msg_pkt(1000, "TRIALID 1"),
        # Sample 1 at ts = 1000 (full ts: 0x8500 | 0x2000 = 0xa500), gxL = 852.8 (0x2150 has 0x21!)
        be_u16(0xa500),
        be_u32(1000),
        be_u16(8528),
        be_u16(5120),
        be_u16(1200),
        # STARTSACC at ts = 1001 followed by unconsumed payload mimicking MESSAGEEVENT (0x98 & 0x3f == 24, +2 == 0x21)
        UInt8[0x85, 0x80, 0x21],
        be_u32(1001),
        UInt8[0x98, 0x2a, 0x21, 0xee, 0x12, 0x21, 0x33, 0x00, 0xfc, 0x2b],
        # FIXUPDATE at ts = 1001 with short 12B payload (must NOT jump 67B like ENDFIX!)
        UInt8[0x89, 0x80, 0x21],
        be_u32(1001),
        UInt8[0x41],
        be_u32(1002),
        zeros(UInt8, 7),
        # Sample 2 at ts = 1002 (delta ts = 2, leaving a 1 ms gap at ts = 1001)
        be_u16(0x8500),
        UInt8[0x02],
        be_u16(8550),
        be_u16(5120),
        be_u16(1210),
        # Stimulus On message at ts = 1001 (must survive FIXUPDATE and snap across 1 ms gap at 1000 Hz)
        msg_pkt(1001, "Stimulus On"),
        # Duplicate ENDBLINK records at sttime = 1005, entime = 1030 via [0x41, entime(4B), 0x00]
        UInt8[0x84, 0x80, 0x21],
        be_u32(1005),
        UInt8[0x41],
        be_u32(1030),
        UInt8[0x00],
        UInt8[0x84, 0x80, 0x21],
        be_u32(1005),
        UInt8[0x41],
        be_u32(1030),
        UInt8[0x00],
        # Sample 3 at ts = 1035 (delta ts = 33) + TRIAL_RESULT 0
        be_u16(0x8500),
        UInt8[33],
        be_u16(8550),
        be_u16(5120),
        be_u16(1205),
        msg_pkt(1035, "TRIAL_RESULT 0"),
    )

    tmp_edf = tempname() * ".edf"
    try
        write(tmp_edf, raw_edf_bytes)
        edf_syn = read_eyelink(tmp_edf)

        # 1. Zero false MESSAGEEVENTs from 0x21 payload bytes; all 3 real messages intact
        msgs = filter(r -> r.type == EyeFun.EVENT_MESSAGEEVENT, edf_syn.events)
        @test nrow(msgs) == 3
        @test collect(msgs.message) == ["TRIALID 1", "Stimulus On", "TRIAL_RESULT 0"]

        # 2. All 3 samples preserved without swallowing
        @test nrow(edf_syn.samples) == 3
        @test collect(edf_syn.samples.time) == UInt32[1000, 1002, 1035]
        @test edf_syn.samples.gxL[1] ≈ 852.8f0

        # 3. Hardware ENDBLINK entime extracted directly and duplicates deduplicated
        bl_df = EyeFun.parse_blinks(edf_syn.events; samples = edf_syn.samples)
        @test nrow(bl_df) == 1
        @test bl_df.sttime[1] == UInt32(1005)
        @test bl_df.entime[1] == UInt32(1030)
        @test bl_df.duration[1] == UInt32(26)

        # 4. 1000 Hz message snapping across a 1 ms tick gap preserves "Stimulus On" and time_rel
        ed_syn = create_eyefun_data(edf_syn; trial_time_zero = "Stimulus On")
        @test any(m -> occursin("Stimulus On", m), ed_syn.df.message)
        @test all(!ismissing, ed_syn.df.time_rel)
    finally
        isfile(tmp_edf) && rm(tmp_edf)
    end

    # Ground-truth hardware ENDBLINK sttime/entime parity against edf2asc on test1 & test2,
    # plus enclosing-saccade flutter coalescing on binocular test3
    bl_edf1 = EyeFun.parse_blinks(Main.TEST1_EDF.events; samples = Main.TEST1_EDF.samples)
    bl_asc1 = EyeFun.parse_blinks(Main.TEST1_ASC.events; samples = Main.TEST1_ASC.samples)
    @test nrow(bl_edf1) == nrow(bl_asc1)
    @test bl_edf1.sttime == bl_asc1.sttime
    @test bl_edf1.entime == bl_asc1.entime

    edf2 = read_eyelink(joinpath(DATA_DIR_EYELINK, "test2.edf"))
    asc2 = read_eyelink(joinpath(DATA_DIR_EYELINK, "test2.asc"))
    bl_edf2 = EyeFun.parse_blinks(edf2.events; samples = edf2.samples)
    bl_asc2 = EyeFun.parse_blinks(asc2.events; samples = asc2.samples)
    @test nrow(bl_edf2) == nrow(bl_asc2)
    @test bl_edf2.sttime == bl_asc2.sttime
    @test bl_edf2.entime == bl_asc2.entime

    edf3 = read_eyelink(joinpath(DATA_DIR_EYELINK, "test3.edf"))
    asc3 = read_eyelink(joinpath(DATA_DIR_EYELINK, "test3.asc"))
    bl_edf3 = EyeFun.parse_blinks(edf3.events; samples = edf3.samples)
    bl_asc3 = EyeFun.parse_blinks(asc3.events; samples = asc3.samples)
    @test count(==(EyeFun.EVENT_ENDBLINK), edf3.events.type) > 300 # raw flutter fragments
    @test abs(nrow(bl_edf3) - nrow(bl_asc3)) <= 10                 # coalesced cleanly
end
