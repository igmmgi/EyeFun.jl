@testset "SMI reader" begin
    @testset "read_smi (txt): SMIFile" begin
        raw = Main.TEST_SMI_TXT
        @test raw isa EyeFun.SMIFile
        @test raw.sample_rate == 50.0
        @test raw.screen_res == (1280, 1024)
        @test raw.screen_width_cm ≈ 30.0
        @test raw.viewing_distance_cm ≈ 50.0
        @test raw.subject == "pp23671"
        @test nrow(raw.samples) > 0

        # Raw samples have gaze columns but no event columns
        @test hasproperty(raw.samples, :gxL)
        @test hasproperty(raw.samples, :time)
        @test hasproperty(raw.samples, :trial)
        @test hasproperty(raw.samples, :participant)
        @test hasproperty(raw.samples, :message)
        @test !hasproperty(raw.samples, :in_fix)    # not yet detected

        # Uncalibrated mock recording: 0.0 is mapped to NaN
        @test all(isnan, raw.samples.gxL)
        @test all(==("pp23671"), raw.samples.participant)
    end

    @testset "create_eyefun_data (txt): EyeData with events" begin
        raw = Main.TEST_SMI_TXT
        ed = EyeFun.create_eyefun_data(deepcopy(raw))

        @test ed isa EyeData
        @test ed.source == :smi
        @test ed.sample_rate == 50.0
        @test ed.screen_res == (1280, 1024)
        @test nrow(ed.df) == nrow(raw.samples)

        @test !hasproperty(ed.df, :in_fix)
        @test !hasproperty(ed.df, :in_sacc)
        @test !hasproperty(ed.df, :in_blink)

        detect_events!(ed)

        @test hasproperty(ed.df, :in_fix)
        @test hasproperty(ed.df, :in_sacc)
        @test hasproperty(ed.df, :in_blink)
        @test hasproperty(ed.df, :fix_gavx)
        @test hasproperty(ed.df, :sacc_gstx)
        @test hasproperty(ed.df, :blink_dur)

        fix = fixations(ed)
        @test fix isa DataFrame
        @test nrow(fix) == 0

        sacc = saccades(ed)
        @test sacc isa DataFrame

        blk = blinks(ed)
        @test blk isa DataFrame
    end

    @testset "read_smi (idf): SMIFile" begin
        raw = Main.TEST_SMI_IDF
        @test raw isa EyeFun.SMIFile
        @test nrow(raw.samples) > 0
        @test hasproperty(raw.samples, :gxL)
        @test hasproperty(raw.samples, :time)
        @test all(isnan, raw.samples.gxL)
    end

    @testset "write_et_ascii: IDF round-trip" begin
        raw = Main.TEST_SMI_IDF
        out = tempname() * ".txt"
        try
            write_et_ascii(raw, out)
            @test isfile(out)

            # Round-trip: read the written file back via the TXT reader
            rt = EyeFun.read_smi(out)
            @test rt isa EyeFun.SMIFile
            @test nrow(rt.samples) == nrow(raw.samples)
            @test rt.sample_rate == raw.sample_rate

            # Timestamps preserved to within 1 µs (round-trip through µs integers)
            @test maximum(abs.(rt.samples.time .- raw.samples.time)) < 0.001

            # Gaze values preserved to 2 decimal places (write_et_ascii uses %.2f)
            valid = .!isnan.(raw.samples.gxL) .& .!isnan.(rt.samples.gxL)
            if any(valid)
                @test maximum(abs.(raw.samples.gxL[valid] .- rt.samples.gxL[valid])) < 0.01
            end
        finally
            isfile(out) && rm(out)
        end
    end

    # Verify IDF binary reader output matches BeGaze TXT export
    function _compare_idf_parity(idf_path, ref_txt_path)
        raw = EyeFun.read_smi(idf_path)
        out = tempname() * ".txt"
        try
            write_et_ascii(raw, out)

            begaze = filter(
                l -> !startswith(l, "##") && !startswith(l, "Time"),
                readlines(ref_txt_path),
            )
            exported =
                filter(l -> !startswith(l, "##") && !startswith(l, "Time"), readlines(out))

            total = min(length(begaze), length(exported))
            # Allow at most 1 row difference (trailing sub-record edge case)
            @test abs(length(begaze) - length(exported)) <= 1

            mismatches = 0
            for i = 1:total
                bg_parts = split(begaze[i], '\t')
                ex_parts = split(exported[i], '\t')

                # Skip Time (1), Type (2), Trial (3), col 15 (Frame/Aux)
                for j = 4:(length(bg_parts)-1)
                    j == 15 && continue
                    j > length(ex_parts) && continue

                    b_f = tryparse(Float64, bg_parts[j])
                    e_f = tryparse(Float64, ex_parts[j])
                    if !isnothing(b_f) && !isnothing(e_f)
                        abs(b_f - e_f) > 0.015 && (mismatches += 1)
                    else
                        strip(bg_parts[j]) != strip(ex_parts[j]) && (mismatches += 1)
                    end
                end
            end
            @test mismatches == 0
        finally
            isfile(out) && rm(out)
        end
        return raw
    end

    parity_cases = [
        ("pp23671_rest1", "pp23671_rest1.idf", "pp23671_rest1_samples.txt"),
        ("pp23671_task1", "pp23671_task1.idf", "pp23671_task1_samples.txt"),
        ("pp31237_rest1", "pp31237_rest1.idf", "pp31237_rest1_samples.txt"),
        ("pp31237_task1", "pp31237_task1.idf", "pp31237_task1_samples.txt"),
    ]

    for (label, idf_fn, txt_fn) in parity_cases
        @testset "IDF/BeGaze parity: $label" begin
            idf_path = joinpath(Main.DATA_DIR_SMI, idf_fn)
            txt_path = joinpath(Main.DATA_DIR_SMI, txt_fn)
            if isfile(idf_path) && isfile(txt_path)
                raw = _compare_idf_parity(idf_path, txt_path)
                @test nrow(raw.events) > 0
                @test all(==("MSG"), raw.events.type)
                @test all(m -> !isnothing(tryparse(Int, m)), raw.events.message)
                @test 49.0 < raw.sample_rate < 51.0
            else
                @warn "SMI test data not found for $label, skipping"
            end
        end
    end

    @testset "Binocular IDF paired sub-record merging" begin
        tmp_idf = tempname() * ".idf"
        try
            buf = UInt8[]
            append!(buf, zeros(UInt8, 32))
            append!(buf, codeunits("TimeStamp L POR X [px] R POR X [px] Trig"))
            append!(buf, zeros(UInt8, 8))  # null padding aligned cleanly

            sub_sz = 106
            # 3 binocular timepoints (6 sub-records: L, R pairs sharing identical timestamps)
            ts_ticks = UInt32[2_000_000, 7_120_000, 12_240_000]  # 20 ms steps (50 Hz)
            for (idx, ts) in enumerate(ts_ticks)
                for is_right in (false, true)
                    rec = zeros(UInt8, sub_sz)
                    rec[1] = 0x01  # non-null record start byte after header null padding
                    # raw_ts at rec[5:8] (1-based sub_off + 4)
                    ts_bytes = reinterpret(UInt8, [htol(ts)])
                    rec[5:8] .= ts_bytes
                    # pupdx/pupdy at +40/+48, gx/gy at +72/+80
                    pup = is_right ? 3.8 : 3.5
                    gx = is_right ? (600.0 + idx) : (590.0 + idx)
                    gy = is_right ? (410.0 + idx) : (400.0 + idx)
                    rec[41:48] .= reinterpret(UInt8, [htol(pup)])
                    rec[49:56] .= reinterpret(UInt8, [htol(pup)])
                    rec[73:80] .= reinterpret(UInt8, [htol(gx)])
                    rec[81:88] .= reinterpret(UInt8, [htol(gy)])
                    append!(buf, rec)
                end
            end
            write(tmp_idf, buf)

            bino = read_smi(tmp_idf)
            @test nrow(bino.samples) == 3
            @test bino.sample_rate ≈ 50.0 atol = 0.5
            @test all(!isnan, bino.samples.gxL)
            @test all(!isnan, bino.samples.gxR)
            @test bino.samples.gxL[1] ≈ 591.0f0
            @test bino.samples.gxR[1] ≈ 601.0f0
        finally
            isfile(tmp_idf) && rm(tmp_idf)
        end
    end

    @testset "SMI TXT MSG rows, missing header fallback, and paL round-trip" begin
        tmp_txt = tempname() * ".txt"
        tmp_out = tempname() * ".txt"
        try
            write(
                tmp_txt,
                join(
                    [
                        "## Subject:\tS_TXT",
                        "Time\tType\tL Dia X [px]\tL POR X [px]\tL POR Y [px]",
                        "1000\tSMP\t14.50\t500.00\t400.00",
                        "1500\tMSG\t# Message: TRIAL_ONSET",
                        "3000\tSMP\t14.75\t502.00\t401.00",
                        "5000\tSMP\t15.00\t504.00\t402.00",
                    ],
                    "\n",
                ),
            )
            smi = read_smi(tmp_txt)
            @test nrow(smi.samples) == 3
            @test smi.sample_rate ≈ 500.0
            @test nrow(smi.events) == 1
            @test occursin("TRIAL_ONSET", smi.events.message[1])
            @test occursin("TRIAL_ONSET", smi.samples.message[2])

            @test_throws ErrorException write_et_ascii(smi, tmp_txt)
            write_et_ascii(smi, tmp_out)
            smi_rt = read_smi(tmp_out)
            @test smi_rt.samples.paL[1] ≈ 14.5f0 atol = 0.02
        finally
            isfile(tmp_txt) && rm(tmp_txt)
            isfile(tmp_out) && rm(tmp_out)
        end
    end
end
