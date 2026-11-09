using Random

@testset "Multi-participant handling, file formats, and statistical analysis" begin

    @testset "Multi-participant group_by=:auto & event accessor seam splitting" begin
        # Two participants with identical trial numbers (1 and 2) and non-monotonic concatenated time
        n = 100
        t_p1 = vcat(collect(1000.0:1049.0), collect(2000.0:2049.0))
        t_p2 = vcat(collect(500.0:549.0), collect(1500.0:1549.0))  # backward jump at P1->P2 seam

        # P1 Trial 1 has +40 px drift offset; P2 Trial 1 has -20 px drift offset
        gx_p1 = vcat(fill(540.0f0, 50), fill(500.0f0, 50))
        gx_p2 = vcat(fill(480.0f0, 50), fill(500.0f0, 50))
        gy_all = fill(400.0f0, 200)
        pa_p1 = vcat(fill(1200.0f0, 20), fill(1400.0f0, 30), fill(1200.0f0, 50))
        pa_p2 = vcat(fill(800.0f0, 20), fill(900.0f0, 30), fill(NaN32, 50))  # P2 Trial 2 has 100% loss

        msg = fill("", 200)
        msg[1] = "STIM_ON"
        msg[51] = "STIM_ON"
        msg[101] = "STIM_ON"
        # Intentionally omit STIM_ON on P2 Trial 2 (catch trial)

        ed_mp = EyeData(
            DataFrame(
                participant = vcat(fill("P1", n), fill("P2", n)),
                trial = vcat(fill(1, 50), fill(2, 50), fill(1, 50), fill(2, 50)),
                cond = vcat(fill("A", 50), fill("B", 50), fill("A", 50), fill("B", 50)),
                time = vcat(t_p1, t_p2),
                gxL = vcat(gx_p1, gx_p2),
                gyL = gy_all,
                paL = vcat(pa_p1, pa_p2),
                in_fix = trues(200),
                fix_gavx = vcat(gx_p1, gx_p2),
                fix_gavy = gy_all,
                fix_ava = vcat(pa_p1, pa_p2),
                fix_dur = fill(Int32(50), 200),
                in_sacc = falses(200),
                sacc_dur = fill(Int32(0), 200),
                sacc_ampl = fill(NaN32, 200),
                sacc_pvel = fill(NaN32, 200),
                in_blink = falses(200),
                blink_dur = fill(Int32(0), 200),
                message = msg,
            );
            sample_rate = 1000.0,
            screen_res = (1000, 800),
        )

        # Event accessors split across participant & backward-clock seams + support include_groups & selection
        fix_all = fixations(ed_mp; include_groups = true)
        @test nrow(fix_all) >= 2
        @test all(>=(0), fix_all.duration)
        @test hasproperty(fix_all, :participant) && hasproperty(fix_all, :trial)
        fix_p2 = fixations(ed_mp; selection = (participant = "P2",), include_groups = true)
        @test all(==("P2"), fix_p2.participant)

        msg_p1 = messages(ed_mp; selection = (participant = "P1",))
        @test nrow(msg_p1) == 2

        vars_mp = variables(ed_mp)
        @test nrow(vars_mp) == 4
        @test Set(vars_mp.participant) == Set(["P1", "P2"])

        # data_quality and group_summary disambiguate (participant, trial) into 4 rows
        dq_mp = data_quality(ed_mp)
        @test nrow(dq_mp) == 4
        @test hasproperty(dq_mp, :participant)
        dq_sub = data_quality(ed_mp; selection = (participant = "P1",))
        @test nrow(dq_sub) == 2

        gs_mp = group_summary(ed_mp)
        @test nrow(gs_mp) == 4
        gs_sub = group_summary(ed_mp; selection = (participant = "P2",))
        @test nrow(gs_sub) == 2

        # drift_correct! corrects P1 Trial 1 and P2 Trial 1 independently to (500, 400)
        ed_dc = copy(ed_mp)
        drift_correct!(ed_dc; target = (500.0, 400.0), method = :window, window_ms = (0.0, 20.0))
        @test ed_dc.df.gxL[1] ≈ 500.0f0 atol = 1e-3
        @test ed_dc.df.gxL[101] ≈ 500.0f0 atol = 1e-3

        # baseline_correct_pupil! uses each participant's own baseline (1200 vs 800)
        ed_bc = copy(ed_mp)
        baseline_correct_pupil!(ed_bc; window = (0.0, 15.0), method = :subtractive)
        @test ed_bc.df.paL[25] ≈ 200.0f0 atol = 1e-3   # 1400 - 1200
        @test ed_bc.df.paL[125] ≈ 100.0f0 atol = 1e-3  # 900 - 800

        # exclude_trials! drops (P2, trial=2) while keeping (P1, trial=2)
        ed_ex = copy(ed_mp)
        ed_ex.df.gxL[151:200] .= NaN32
        ed_ex.df.gyL[151:200] .= NaN32
        exclude_trials!(ed_ex; max_tracking_loss = 50.0)
        @test any(r -> r.participant == "P1" && r.trial == 2, eachrow(variables(ed_ex)))
        @test !any(r -> r.participant == "P2" && r.trial == 2, eachrow(variables(ed_ex)))

        # set_time_zero! sets NaN on catch trial (P2, trial=2) missing the anchor
        ed_tz = copy(ed_mp)
        set_time_zero!(ed_tz, "STIM_ON")
        @test ed_tz.df.time_rel[1] == 0.0
        @test ed_tz.df.time_rel[101] == 0.0
        @test all(isnan, ed_tz.df.time_rel[151:200])

        tb_tz = time_bin(ed_tz; bin_ms = 25, time_window = (0.0, 50.0))
        # Catch trial (P2, trial=2) excluded; right endpoint ti==50.0 stays inside [0, 50] (2 bins: 12.5, 37.5)
        @test !any(r -> r.participant == "P2" && r.trial == 2, eachrow(tb_tz))
        @test maximum(tb_tz.time_bin) <= 50.0
        @test sort(unique(tb_tz.time_bin)) == [12.5, 37.5]

        # Regex and Symbol column anchors in set_time_zero!
        set_time_zero!(ed_tz, r"^STIM_")
        @test ed_tz.df.time_rel[1] == 0.0
        ed_tz.df.anchor_ts = vcat(fill(1010.0, 50), fill(2010.0, 50), fill(510.0, 50), fill(missing, 50))
        set_time_zero!(ed_tz, :anchor_ts)
        @test ed_tz.df.time_rel[11] == 0.0
        @test ed_tz.df.time_rel[111] == 0.0
        @test all(isnan, ed_tz.df.time_rel[151:200])
    end

    @testset "Coordinate-space tracking & to_center_coords! idempotency" begin
        ed_c = EyeData(
            DataFrame(
                trial = fill(1, 20),
                time = collect(0.0:19.0),
                gxL = fill(960.0f0, 20),
                gyL = fill(540.0f0, 20),
                gxR = fill(960.0f0, 20),
                gyR = fill(540.0f0, 20),
                paL = fill(1000.0f0, 20),
                in_fix = trues(20),
                fix_gavx = fill(960.0f0, 20),
                fix_gavy = fill(540.0f0, 20),
                fix_dur = fill(Int32(20), 20),
                ivt_fix_gavx = fill(960.0, 20),
                ivt_fix_gavy = fill(540.0, 20),
            );
            screen_res = (1920, 1080),
            screen_width_cm = 53.0,
            viewing_distance_cm = 60.0,
        )
        to_center_coords!(ed_c; eye = :left, units = :deg)
        @test ed_c.coords == :px   # gxR/gyR still in pixels until converted
        @test ed_c.df.gxL[1] ≈ 0.0 atol = 1e-9
        @test ed_c.df.fix_gavx[1] ≈ 0.0 atol = 1e-9
        @test ed_c.df.ivt_fix_gavx[1] ≈ 0.0 atol = 1e-9

        # Calling again for :right converts gxR/gyR without double-shifting fix_gavx or ivt_fix_gavx
        to_center_coords!(ed_c; eye = :right, units = :deg)
        @test ed_c.coords == :deg
        @test ed_c.df.gxR[1] ≈ 0.0 atol = 1e-9
        @test ed_c.df.fix_gavx[1] ≈ 0.0 atol = 1e-9
        @test ed_c.df.ivt_fix_gavx[1] ≈ 0.0 atol = 1e-9

        # Repeating for :left is a safe no-op
        to_center_coords!(ed_c; eye = :left, units = :deg)
        @test ed_c.df.gxL[1] ≈ 0.0 atol = 1e-9
    end

    @testset "EyeLink >=256B binary LSTRING, ASC word boundaries, BUTTON, and calibration_summary" begin
        # 1. >= 256-byte big-endian LSTRING in _msg_span_bytes and 16-bit _input_bytes
        long_text = "!V IAREA RECTANGLE 1 " * repeat("X", 280)
        msg_len = sizeof(long_text)
        @test msg_len > 256
        raw_buf = UInt8[0x00, UInt8((msg_len >> 8) & 0xFF), UInt8(msg_len & 0xFF)]
        append!(raw_buf, codeunits(long_text))
        push!(raw_buf, 0x00, 0x00, 0xAB)  # sentinel 0xAB at next record
        ts, te, nxt = EyeFun._msg_span_bytes(raw_buf, 1)
        @test String(raw_buf[ts:te]) == long_text
        @test raw_buf[nxt] == 0xAB

        in_buf = UInt8[0x00, 0x01, 0x02, 0x00, 0xAB]  # extra(1) + uint16_be(0x0102 = 258) + pad(1) + sentinel
        val16, next_in = EyeFun._input_bytes(in_buf, 1)
        @test val16 == 0x0102
        @test in_buf[next_in] == 0xAB

        # 2. ASC word boundaries ("STARTPARSE" / "ENDPARSE" not mistaken for START/END) + BUTTON + !CAL
        mktempdir() do dir
            asc_p = joinpath(dir, "word_bounds.asc")
            write(
                asc_p,
                join(
                    [
                        "** CONVERTED FROM test.edf",
                        "",
                        "** RECORDED BY EyeLink",
                        "MSG\t900 !CAL CALIBRATION (HV9,P-CR) FOR LEFT: GOOD",
                        "MSG\t950 !CAL VALIDATION HV9 R LEFT GOOD ERROR 0.24 avg. 0.51 max  OFFSET 0.18 deg. 4.2,-3.1 pix.",
                        "STARTPARSE\t990",
                        "START\t1000 \tLEFT\tSAMPLES\tEVENTS",
                        "PRESCALER\t1",
                        "VPRESCALER\t1",
                        "SAMPLES\tGAZE\tLEFT\tRATE\t1000.00\tTRACKING\tCR\tFILTER\t2",
                        "EVENTS\tGAZE\tLEFT\tRATE\t1000.00\tTRACKING\tCR\tFILTER\t2",
                        "MSG\t1000 DRIFTCORRECT LR LEFT GOOD OFFSET 0.11 deg.  1.5,2.0 pix.",
                        "MSG\t1000 TRIALID_EXTRA 99",
                        "MSG\t1000 TRIALID 1",
                        "1000\t  500.0\t  400.0\t 1200.0\t...",
                        "BUTTON\t1001\t2\t1",
                        "1001\t  501.0\t  401.0\t 1205.0\t...",
                        "ENDPARSE\t1001",
                        "END\t1002 \tSAMPLES\tEVENTS\tRES\t  35.00\t  35.00",
                    ],
                    "\n",
                ),
            )
            edf_wb = read_eyelink(asc_p)
            @test occursin("RECORDED BY EyeLink", edf_wb.preamble)
            @test count(==(EyeFun.RECORDING_START), edf_wb.recordings.state) == 1
            @test nrow(edf_wb.samples) == 2
            # TRIALID_EXTRA does not trigger a separate trial when start_marker="TRIALID"
            @test Set(skipmissing(edf_wb.samples.trial)) == Set([1])
            # BUTTON event: (state << 8) | button_num = 0x0102
            btn_rows = filter(r -> r.type == EyeFun.EVENT_BUTTONEVENT, edf_wb.events)
            @test nrow(btn_rows) == 1
            @test btn_rows.buttons[1] == UInt16(0x0102)

            cal = calibration_summary(edf_wb)
            @test nrow(cal) == 3
            @test cal.kind == [:calibration, :validation, :drift_correct]
            @test cal.avg_error_deg[2] ≈ 0.24
            @test cal.max_error_deg[2] ≈ 0.51
            @test cal.offset_x_px[2] ≈ 4.2
            @test cal.offset_y_px[2] ≈ -3.1
            @test cal.offset_deg[3] ≈ 0.11

            ed_wb = create_eyefun_data(edf_wb)
            @test nrow(calibration_summary(ed_wb)) >= 1
        end

        # Also test calibration_summary on real SR Research test2.asc
        test2_asc = joinpath(Main.DATA_DIR_EYELINK, "test2.asc")
        if isfile(test2_asc)
            cal2 = calibration_summary(read_eyelink(test2_asc))
            @test nrow(cal2) >= 1
            @test any(==(:validation), cal2.kind)
        end
    end

    @testset "SMI BeGaze events_path, Tobii native I-VT + stimulus trials, and delimited/BIDS I/O" begin
        mktempdir() do dir
            # 1. SMI samples + companion BeGaze *_events.txt
            smi_s = joinpath(dir, "subj01_samples.txt")
            smi_e = joinpath(dir, "subj01_events.txt")
            write(
                smi_s,
                join(
                    [
                        "## Sample Rate:\t500",
                        "## Calibration Area:\t1280\t1024",
                        "Time\tType\tTrial\tL Dia X [px]\tL POR X [px]\tL POR Y [px]",
                        "0\tSMP\t1\t12.0\t400.0\t300.0",
                        "2000\tSMP\t1\t12.0\t402.0\t301.0",
                        "4000\tSMP\t1\t12.0\t401.0\t300.0",
                        "6000\tSMP\t1\t0.0\t0.0\t0.0",
                        "8000\tSMP\t1\t12.0\t600.0\t300.0",
                    ],
                    "\n",
                ),
            )
            write(
                smi_e,
                join(
                    [
                        "Fixation L\t1\t1\t0\t4000\t4001\t401.0\t300.3\t0.5\t0.5\t12.0",
                        "Saccade L\t1\t1\t4000\t8000\t4000\t401.0\t300.0\t600.0\t300.0\t5.2\t180.0",
                        "Blink L\t1\t1\t6000\t6000\t2000",
                    ],
                    "\n",
                ),
            )
            smi_raw = read_smi(smi_s)  # auto-discovers subj01_events.txt
            @test smi_raw.subject == "subj01"
            ed_smi = create_eyefun_data(smi_raw; include_events = true)
            @test any(ed_smi.df.in_fix)
            @test any(ed_smi.df.in_sacc)
            @test any(ed_smi.df.in_blink)

            # Non-numeric message exports as MSG row rather than corrupting Trigger
            ed_smi_out = joinpath(dir, "subj01_out.txt")
            smi_raw.samples.message[2] = "STIMULUS_A"
            write_et_ascii(smi_raw, ed_smi_out)
            out_txt = read(ed_smi_out, String)
            @test occursin("\tMSG\t1\t# Message: STIMULUS_A", out_txt)

            # 2. Tobii fused/normalized gaze fallback, stimulus trial increments, and native I-VT events
            tob_p = joinpath(dir, "tobii_pro.tsv")
            write(
                tob_p,
                join(
                    [
                        "Recording timestamp\tParticipant name\tSensor\tGaze point X [ADCS norm]\tGaze point Y [ADCS norm]\tPupil diameter left\tValidity pupil left\tPresented Stimulus name\tEye movement type\tGaze event duration\tFixation point X [MCS norm]\tFixation point Y [MCS norm]",
                        "0\tPTob\tEye Tracker\t0.5\t0.5\t3.2\tValid\tStim1.png\tFixation\t40\t0.5\t0.5",
                        "20000\tPTob\tEye Tracker\t0.5\t0.5\t3.3\tValid\tStim1.png\tFixation\t40\t0.5\t0.5",
                        "40000\tPTob\tEye Tracker\t0.75\t0.25\t3.1\tInvalid\tStim2.png\tSaccade\t20\t\t",
                        "60000\tPTob\tEye Tracker\t\t\t\tInvalid\tStim2.png\tEyesNotFound\t20\t\t",
                    ],
                    "\n",
                ),
            )
            tob = read_tobii(tob_p; screen_res = (1000, 800))
            @test tob.samples.trial == [1, 1, 2, 2]
            @test tob.samples.gxL[1] ≈ 500.0f0
            @test tob.samples.gyL[1] ≈ 400.0f0
            # Row 3 retains valid gaze (0.75, 0.25) when pupil validity is Invalid
            @test tob.samples.gxL[3] ≈ 750.0f0
            @test isnan(tob.samples.paL[3])

            ed_tob_def = create_eyefun_data(tob)
            @test !hasproperty(ed_tob_def.df, :in_fix)
            ed_tob_ev = create_eyefun_data(tob; include_events = true)
            @test ed_tob_ev.df.in_fix == Bool[true, true, false, false]
            @test ed_tob_ev.df.in_sacc == Bool[false, false, true, false]
            @test ed_tob_ev.df.in_blink == Bool[false, false, false, true]
            @test ed_tob_ev.df.fix_gavx[1] ≈ 500.0f0

            # 3. Generic CSV/TSV & BIDS *_eyetrack.tsv + *_eyetrack.json round-trip
            csv_p = joinpath(dir, "session.csv")
            write_et_delimited(ed_tob_ev, csv_p; write_bids_json = true)
            @test isfile(joinpath(dir, "session.json"))
            ed_csv = read_et_data(csv_p)
            @test ed_csv.sample_rate ≈ ed_tob_ev.sample_rate
            @test ed_csv.screen_res == (1000, 800)
            @test nrow(ed_csv.df) == 4
            @test ed_csv.df.gxL[1] ≈ 500.0f0

            # Headerless BIDS *_eyetrack.tsv + *_eyetrack.json with StartTime in seconds
            bids_tsv = joinpath(dir, "sub-01_task-rest_eyetrack.tsv")
            bids_json = joinpath(dir, "sub-01_task-rest_eyetrack.json")
            write(bids_tsv, "0.000\t100.0\t200.0\t3.5\n0.002\t102.0\t201.0\t3.6\n0.004\t104.0\t202.0\t3.5\n")
            write(
                bids_json,
                """
                {
                  "SamplingFrequency": 500.0,
                  "StartTime": -0.002,
                  "ScreenResolution": [1280, 720],
                  "Columns": ["timestamp", "x_coordinate", "y_coordinate", "pupil_size"]
                }
                """,
            )
            ed_bids = read_et_data(bids_tsv)
            @test ed_bids.sample_rate == 500.0
            @test ed_bids.screen_res == (1280, 720)
            @test nrow(ed_bids.df) == 3
            @test ed_bids.df.gx[2] ≈ 102.0f0
        end
    end

    @testset "BMP headers, stimulus directory loading, and WAV playback validation" begin
        mktempdir() do dir
            # 1. 32-bit BI_BITFIELDS (compression == 3) 2x2 BMP
            bmp32 = joinpath(dir, "bitfields32.bmp")
            io32 = IOBuffer()
            write(io32, UInt8('B'), UInt8('M'))
            write(io32, htol(UInt32(14 + 40 + 12 + 16)))  # file size
            write(io32, htol(UInt32(0)))
            write(io32, htol(UInt32(14 + 40 + 12)))       # pixel data offset = 66
            write(io32, htol(UInt32(40)))                 # BITMAPINFOHEADER
            write(io32, htol(Int32(2)), htol(Int32(2)))   # 2x2 bottom-up
            write(io32, htol(UInt16(1)), htol(UInt16(32)))
            write(io32, htol(UInt32(3)))                  # BI_BITFIELDS
            write(io32, htol(UInt32(16)), htol(Int32(0)), htol(Int32(0)), htol(UInt32(0)), htol(UInt32(0)))
            # Custom RGB masks: R=0x000000FF, G=0x0000FF00, B=0x00FF0000
            write(io32, htol(UInt32(0x000000FF)), htol(UInt32(0x0000FF00)), htol(UInt32(0x00FF0000)))
            for _ = 1:4
                write(io32, htol(UInt32(0x000000FF)))     # pure red under custom mask
            end
            write(bmp32, take!(io32))
            img32 = load_image(bmp32)
            @test size(img32) == (2, 2)
            @test image_size(bmp32) == (2, 2)
            @test img32[1, 1] == Makie.RGBf(1.0f0, 0.0f0, 0.0f0)

            # 2. 12-byte OS/2 BITMAPCOREHEADER 24-bit 2x1 BMP
            bmp12 = joinpath(dir, "os2_core.bmp")
            io12 = IOBuffer()
            write(io12, UInt8('B'), UInt8('M'))
            write(io12, htol(UInt32(26 + 8)), htol(UInt32(0)), htol(UInt32(26)))
            write(io12, htol(UInt32(12)))
            write(io12, htol(UInt16(2)), htol(UInt16(1)), htol(UInt16(1)), htol(UInt16(24)))
            write(io12, UInt8[0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00])  # 2 green BGR pixels + 2B pad
            write(bmp12, take!(io12))
            img12 = load_image(bmp12)
            @test image_size(bmp12) == (1, 2)
            @test img12[1, 1] == Makie.RGBf(0.0f0, 1.0f0, 0.0f0)

            # 3. read_stimuli load_extensions alias + duplicate stem warning
            sub = mkpath(joinpath(dir, "sub"))
            cp(bmp12, joinpath(sub, "os2_core.bmp"))
            stims = @test_logs (:warn, r"Duplicate stimulus basename") read_stimuli(
                dir;
                load_extensions = [".bmp"],
            )
            @test haskey(stims, "os2_core.bmp")

            # 4. play_wav synchronous validation errors
            @test_throws ArgumentError play_wav(joinpath(dir, "missing_audio.wav"))
            @test_throws ArgumentError play_wav(zeros(Float32, 10), 0)
            @test_throws ArgumentError play_wav(zeros(Float32, 2, 2, 2), 44100)
        end
    end

    @testset "Saccade refinement, PSO, pupil filtering, MultiMatch, binocular microsaccades, and cluster permutation" begin
        # Nystrom & Holmqvist (2010) saccade onset/offset refinement and post-saccadic oscillation (PSO)
        n = 300
        gx = Vector{Float64}(undef, n)
        gy = fill(540.0, n)
        # Fixation 1 (1:95) at 400 px
        for i = 1:95
            gx[i] = 400.0 + 0.15 * sin(0.6 * i)
        end
        # Gentle ramp (96:100) -> fast saccade (101:118) -> PSO underdamped ring (119:132) -> Fixation 2 (133:300) at 800 px
        gx[96:100] = [400.5, 401.5, 403.5, 407.0, 412.0]
        for i = 101:118
            gx[i] = 412.0 + (820.0 - 412.0) * ((i - 100) / 18.0)
        end
        # High-velocity ringing oscillation right after saccade landing before settling to 800 px
        pso_ring = [825.0, 822.0, 814.0, 804.0, 795.0, 791.0, 793.0, 798.0, 803.0, 804.0, 802.0, 800.5, 800.0, 800.0]
        gx[119:132] .= pso_ring
        for i = 133:n
            gx[i] = 800.0 + 0.15 * cos(0.6 * i)
        end

        ed_pso = EyeData(
            DataFrame(trial = fill(1, n), time = collect(0.0:(n-1)), gxL = gx, gyL = gy, paL = fill(1000.0, n));
            sample_rate = 1000.0,
        )
        detect_events!(ed_pso; method = :ivt, velocity_threshold = :adaptive, refine_saccades = true, detect_pso = true)
        @test hasproperty(ed_pso.df, :in_pso) && hasproperty(ed_pso.df, :pso_dur)
        @test any(ed_pso.df.in_pso[115:135])
        # PSO samples are excluded from Fixation 2's onset
        @test !any(ed_pso.df.in_fix .& ed_pso.df.in_pso)

        # I-DT separator at low sample rate (60 Hz) does not create 1-sample 0.0 deg saccades
        ed_60 = EyeData(
            DataFrame(
                trial = fill(1, 40),
                time = collect(range(0.0; step = 1000.0 / 60.0, length = 40)),
                gxL = vcat(fill(300.0, 20), fill(305.0, 20)),
                gyL = fill(400.0, 40),
                paL = fill(1000.0, 40),
            );
            sample_rate = 60.0,
        )
        detect_events!(ed_60; method = :idt, dispersion_threshold = 0.05, min_saccade_ms = 10)
        @test all(>(0.0), filter(!isnan, saccades(ed_60).ampl))

        # pupil_filter! (Kret & Sjak-Shie, 2019) and correct_pupil_foreshortening! (Brisson et al., 2013)
        pa_clean = [1000.0 + 10.0 * sin(0.02 * i) for i = 1:300]
        pa_art = copy(pa_clean)
        pa_art[150] = 350.0  # partial-blink drop spike without NaN
        pa_art[151] = 320.0
        ed_pf = EyeData(
            DataFrame(
                trial = fill(1, 300),
                time = collect(0.0:299.0),
                gxL = vcat(fill(960.0f0, 150), fill(1850.0f0, 150)),  # center vs eccentric gaze
                gyL = fill(540.0f0, 300),
                paL = copy(pa_art),
            );
            sample_rate = 1000.0,
            screen_res = (1920, 1080),
            screen_width_cm = 53.0,
            viewing_distance_cm = 60.0,
        )
        n_flagged = pupil_filter!(ed_pf; mad_multiplier = 8.0, margin_ms = 10, max_interp_ms = 0)
        @test n_flagged >= 2
        @test isnan(ed_pf.df.paL[150])

        # With max_interp_ms = 50, short artifact gap is interpolated back near ~1000
        ed_pf2 = EyeData(
            DataFrame(
                trial = fill(1, 300),
                time = collect(0.0:299.0),
                gxL = vcat(fill(960.0f0, 150), fill(1850.0f0, 150)),
                gyL = fill(540.0f0, 300),
                paL = copy(pa_art),
            );
            sample_rate = 1000.0,
            screen_res = (1920, 1080),
            screen_width_cm = 53.0,
            viewing_distance_cm = 60.0,
        )
        pupil_filter!(ed_pf2; mad_multiplier = 8.0, margin_ms = 5, max_interp_ms = 50)
        @test !isnan(ed_pf2.df.paL[150])
        @test abs(ed_pf2.df.paL[150] - 1000.0) < 30.0

        # Foreshortening correction: center gaze (960, 540) has cos(0) == 1 -> unchanged;
        # eccentric gaze (1850, 540) has cos(alpha) < 1 -> corrected area > raw area
        ed_pfe = EyeData(
            DataFrame(
                trial = fill(1, 2),
                time = [0.0, 1.0],
                gxL = [960.0f0, 1850.0f0],
                gyL = [540.0f0, 540.0f0],
                paL = [1000.0f0, 1000.0f0],
            );
            screen_res = (1920, 1080),
            screen_width_cm = 53.0,
            viewing_distance_cm = 60.0,
        )
        correct_pupil_foreshortening!(ed_pfe; measure = :area)
        @test ed_pfe.df.paL[1] ≈ 1000.0f0 atol = 1e-4
        @test ed_pfe.df.paL[2] > 1050.0f0

        # 3. MultiMatch scanpath similarity + >26 AOI Levenshtein support
        ed_mm = EyeData(
            DataFrame(
                trial = vcat(fill(1, 90), fill(2, 90), fill(3, 90)),
                time = repeat(collect(0.0:89.0), 3),
                gxL = vcat(
                    fill(200.0f0, 30), fill(600.0f0, 30), fill(1000.0f0, 30),  # T1: left -> mid -> right
                    fill(205.0f0, 30), fill(605.0f0, 30), fill(1005.0f0, 30),  # T2: nearly identical
                    fill(1000.0f0, 30), fill(200.0f0, 30), fill(900.0f0, 30),  # T3: reversed
                ),
                gyL = vcat(
                    fill(300.0f0, 30), fill(300.0f0, 30), fill(700.0f0, 30),
                    fill(300.0f0, 30), fill(300.0f0, 30), fill(700.0f0, 30),
                    fill(800.0f0, 30), fill(100.0f0, 30), fill(200.0f0, 30),
                ),
                in_fix = repeat(vcat(trues(25), falses(5), trues(25), falses(5), trues(25), falses(5)), 3),
                fix_gavx = vcat(
                    fill(200.0f0, 30), fill(600.0f0, 30), fill(1000.0f0, 30),
                    fill(205.0f0, 30), fill(605.0f0, 30), fill(1005.0f0, 30),
                    fill(1000.0f0, 30), fill(200.0f0, 30), fill(900.0f0, 30),
                ),
                fix_gavy = vcat(
                    fill(300.0f0, 30), fill(300.0f0, 30), fill(700.0f0, 30),
                    fill(300.0f0, 30), fill(300.0f0, 30), fill(700.0f0, 30),
                    fill(800.0f0, 30), fill(100.0f0, 30), fill(200.0f0, 30),
                ),
                fix_dur = fill(Int32(25), 270),
            );
            sample_rate = 1000.0,
            screen_res = (1920, 1080),
        )
        mm_same = scanpath_similarity(ed_mm; selection1 = (trial = 1,), selection2 = (trial = 2,), method = :multimatch)
        mm_diff = scanpath_similarity(ed_mm; selection1 = (trial = 1,), selection2 = (trial = 3,), method = :multimatch)
        @test mm_same.similarity > 0.95
        @test mm_same.similarity > mm_diff.similarity
        @test all(k -> haskey(mm_same, k), (:vector, :direction, :length, :position, :duration, :similarity))

        # > 26 AOIs in Levenshtein scanpath_similarity must not overflow 'A'..'Z'
        many_aois = [RectAOI("AOI_$k", 50.0 * k, 300.0, 40.0, 200.0) for k = 1:30]
        lev30 = scanpath_similarity(ed_mm, many_aois; selection1 = (trial = 1,), selection2 = (trial = 2,))
        @test lev30.similarity == 1.0
        @test lev30.seq1 isa Vector{String}

        # 4. Binocular microsaccades (Engbert & Kliegl, 2003) + microsaccades(ed) accessor
        n_ms = 300
        gxL_ms = [500.0 + 0.05 * sin(0.4 * i) for i = 1:n_ms]
        gxR_ms = [500.0 + 0.05 * cos(0.4 * i) for i = 1:n_ms]
        gyL_ms = fill(400.0, n_ms)
        gyR_ms = fill(400.0, n_ms)
        # True binocular microsaccade at 100..112 (~0.5 deg = 18 px in both eyes)
        for k = 1:12
            gxL_ms[100+k] += 1.5 * k
            gxR_ms[100+k] += 1.5 * k
        end
        gxL_ms[113:n_ms] .+= 18.0
        gxR_ms[113:n_ms] .+= 18.0
        # Monocular artifact in left eye at 210..220 (rejected when binocular=true)
        for k = 1:10
            gxL_ms[210+k] -= 1.8 * k
        end
        gxL_ms[221:n_ms] .-= 18.0

        ed_ms = EyeData(
            DataFrame(
                participant = fill("P1", n_ms),
                trial = fill(1, n_ms),
                time = collect(0.0:(n_ms-1)),
                gxL = gxL_ms,
                gyL = gyL_ms,
                gxR = gxR_ms,
                gyR = gyR_ms,
            );
            sample_rate = 1000.0,
        )
        detect_microsaccades!(ed_ms; binocular = true, prefix = :bino)
        ms_tbl = microsaccades(ed_ms; prefix = :bino, include_groups = true)
        @test nrow(ms_tbl) == 1
        @test 95.0 <= ms_tbl.sttime[1] <= 110.0
        @test ms_tbl.ampl[1] > 0.2

        # 5. empirical_logit (Barr, 2008), cluster_permutation_test (Maris & Oostenveld, 2007), & plot_time_course
        el_zero = empirical_logit(0, 50; weights = true)
        el_full = empirical_logit(50, 50; weights = true)
        @test isfinite(el_zero.elog) && isfinite(el_full.elog)
        @test el_zero.elog ≈ -el_full.elog atol = 1e-12
        @test el_zero.weight > 0.0

        pol_df = DataFrame(time_bin = [25.0, 75.0], target = [0.0, 1.0], n = [40, 40])
        pol_el = empirical_logit(pol_df, :target; weights = true)
        @test hasproperty(pol_el, :target_elog) && hasproperty(pol_el, :target_weight)

        # Synthetic 10-participant, 2-condition time-course with strong sustained effect in 300..550 ms
        rng = MersenneTwister(1234)
        rows_tc = NamedTuple[]
        bins = collect(0.0:50.0:750.0)
        for s = 1:10
            subj = "S$s"
            for cond in ("Control", "HighLoad")
                for b in bins
                    effect = (cond == "HighLoad" && 300.0 <= b <= 550.0) ? 1.8 : 0.0
                    val = effect + 0.25 * randn(rng)
                    push!(rows_tc, (participant = subj, condition = cond, time_bin = b, value = val))
                end
            end
        end
        tc_df = DataFrame(rows_tc)

        clusters_paired = cluster_permutation_test(
            tc_df;
            n_permutations = 250,
            paired = true,
            rng = MersenneTwister(42),
        )
        @test nrow(clusters_paired) >= 1
        sig_c = filter(r -> r.p_value < 0.05, clusters_paired)
        @test nrow(sig_c) == 1
        @test sig_c.t_start[1] <= 350.0 && sig_c.t_end[1] >= 500.0

        clusters_unpaired = cluster_permutation_test(
            tc_df;
            n_permutations = 200,
            paired = false,
            rng = MersenneTwister(42),
        )
        @test any(<(0.05), clusters_unpaired.p_value)

        fig_tc = plot_time_course(tc_df; group_col = :condition, clusters = clusters_paired, error = :ci95)
        @test fig_tc isa Figure
    end
end

