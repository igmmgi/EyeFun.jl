@testset "SMI reader" begin
    smi_dir = joinpath(dirname(dirname(@__DIR__)), "resources", "data", "smi")

    @testset "read_smi (txt) — returns SMIFile" begin
        txt_path = joinpath(smi_dir, "pp23671_rest1_samples.txt")
        if isfile(txt_path)
            raw = read_smi(txt_path)
            @test raw isa SMIFile
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
            
            # The test files are uncalibrated mock recordings: 0.0 is successfully cast to NaN
            @test all(isnan, raw.samples.gxL)
            @test all(==("pp23671"), raw.samples.participant)
        else
            @warn "SMI test data not found, skipping txt SMIFile test"
        end
    end

    @testset "create_smi_dataframe (txt) — returns EyeData with events" begin
        txt_path = joinpath(smi_dir, "pp23671_rest1_samples.txt")
        if isfile(txt_path)
            raw = read_smi(txt_path)
            ed  = EyeData(raw)

            @test ed isa EyeData
            @test ed.source == :smi
            @test ed.sample_rate == 50.0
            @test ed.screen_res == (1280, 1024)
            @test nrow(ed.df) == nrow(raw.samples)

            # Before detect_events!: event columns are absent
            @test !hasproperty(ed.df, :in_fix)
            @test !hasproperty(ed.df, :in_sacc)
            @test !hasproperty(ed.df, :in_blink)

            # Run event detection
            detect_events!(ed)

            # Event columns populated
            @test hasproperty(ed.df, :in_fix)
            @test hasproperty(ed.df, :in_sacc)
            @test hasproperty(ed.df, :in_blink)
            @test hasproperty(ed.df, :fix_gavx)
            @test hasproperty(ed.df, :sacc_gstx)
            @test hasproperty(ed.df, :blink_dur)

            # High-level accessors work
            fix = fixations(ed)
            @test fix isa DataFrame
            # Zero fixations expected since the file entirely lacks calibrated gaze coords
            @test nrow(fix) == 0

            sacc = saccades(ed)
            @test sacc isa DataFrame

            blk = blinks(ed)
            @test blk isa DataFrame
        else
            @warn "SMI test data not found, skipping create_smi_dataframe test"
        end
    end

    @testset "read_smi (idf) — returns SMIFile" begin
        idf_path = joinpath(smi_dir, "pp23671_rest1.idf")
        if isfile(idf_path)
            raw = read_smi(idf_path)
            @test raw isa SMIFile
            @test nrow(raw.samples) > 0
            @test hasproperty(raw.samples, :gxL)
            @test hasproperty(raw.samples, :time)
            @test all(isnan, raw.samples.gxL)
        else
            @warn "SMI IDF test data not found, skipping idf test"
        end
    end

    @testset "export_ascii — IDF round-trip" begin
        idf_path = joinpath(smi_dir, "pp23671_rest1.idf")
        if isfile(idf_path)
            raw = read_smi(idf_path)
            out = tempname() * ".txt"
            try
                export_ascii(raw, out)
                @test isfile(out)

                # Round-trip: read the written file back via the TXT reader
                rt = read_smi(out)
                @test rt isa SMIFile
                @test nrow(rt.samples) == nrow(raw.samples)
                @test rt.sample_rate == raw.sample_rate

                # Timestamps preserved to within 1 µs (round-trip through µs integers)
                @test maximum(abs.(rt.samples.time .- raw.samples.time)) < 0.001

                # Gaze values preserved to 2 decimal places (export_ascii uses %.2f)
                valid = .!isnan.(raw.samples.gxL) .& .!isnan.(rt.samples.gxL)
                if any(valid)
                    @test maximum(abs.(raw.samples.gxL[valid] .- rt.samples.gxL[valid])) < 0.01
                end
            finally
                isfile(out) && rm(out)
            end
        else
            @warn "SMI IDF test data not found, skipping export_ascii test"
        end
    end

    # ── IDF ↔ BeGaze parity tests ──────────────────────────────────────── #
    # Verify that IDF binary reader output matches the native BeGaze TXT
    # export for gaze, pupil, corneal reflex, and trigger columns.

    function _compare_idf_parity(idf_path, ref_txt_path)
        raw = read_smi(idf_path)
        out = tempname() * ".txt"
        try
            export_ascii(raw, out)

            begaze   = filter(l -> !startswith(l, "##") && !startswith(l, "Time"), readlines(ref_txt_path))
            exported = filter(l -> !startswith(l, "##") && !startswith(l, "Time"), readlines(out))

            total = min(length(begaze), length(exported))
            # Allow at most 1 row difference (trailing sub-record edge case)
            @test abs(length(begaze) - length(exported)) <= 1

            mismatches = 0
            for i in 1:total
                bg_parts = split(begaze[i], '\t')
                ex_parts = split(exported[i], '\t')

                # Skip Time (1), Type (2), Trial (3), col 15 (Frame/Aux)
                for j in 4:length(bg_parts)-1
                    j == 15 && continue
                    j > length(ex_parts) && continue

                    b_f = tryparse(Float64, bg_parts[j])
                    e_f = tryparse(Float64, ex_parts[j])
                    if b_f !== nothing && e_f !== nothing
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
        @testset "IDF↔BeGaze parity — $label" begin
            idf_path = joinpath(smi_dir, idf_fn)
            txt_path = joinpath(smi_dir, txt_fn)
            if isfile(idf_path) && isfile(txt_path)
                raw = _compare_idf_parity(idf_path, txt_path)

                # Verify trigger events were extracted
                @test nrow(raw.events) > 0
                @test all(==("MSG"), raw.events.type)
                @test all(m -> tryparse(Int, m) !== nothing, raw.events.message)

                # Verify sample rate detection
                @test 49.0 < raw.sample_rate < 51.0
            else
                @warn "SMI test data not found for $label, skipping"
            end
        end
    end
end

