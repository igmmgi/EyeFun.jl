@testset "write_et_ascii" begin
    edf_path = joinpath(DATA_DIR_EYELINK, "test1.edf")
    edf = EyeFun.read_eyelink(edf_path)

    @testset "Output is non-empty and parseable" begin
        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(edf, out_path)

            @test isfile(out_path)
            @test filesize(out_path) > 0

            edf2 = EyeFun.read_eyelink(out_path)
            @test edf2 isa EyeFun.EDFFile
            @test !isnothing(edf2.samples)
            @test nrow(edf2.samples) > 0

            ratio = nrow(edf2.samples) / nrow(edf.samples)
            @test ratio > 0.95
            @test ratio <= 1.05
        finally
            isfile(out_path) && rm(out_path)
        end
    end

    @testset "Selective export options" begin
        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(
                edf,
                out_path;
                include_events = false,
                include_messages = false,
            )
            @test isfile(out_path)
            lines = readlines(out_path)
            @test any(l -> !isempty(l) && l[1] >= '0' && l[1] <= '9', lines)
            @test !any(l -> startswith(l, "EFIX"), lines)
            @test !any(l -> startswith(l, "MSG"), lines)
        finally
            isfile(out_path) && rm(out_path)
        end

        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(edf, out_path; include_samples = false)
            @test isfile(out_path)
            lines = readlines(out_path)
            sample_lines = count(l -> !isempty(l) && l[1] >= '0' && l[1] <= '9', lines)
            @test sample_lines == 0
        finally
            isfile(out_path) && rm(out_path)
        end
    end
end

@testset "write_et_ascii binocular" begin
    @testset "Binocular EDF" begin
        bino_path = joinpath(DATA_DIR_EYELINK, "test3.edf")
        edf = EyeFun.read_eyelink(bino_path)
        @test !isnothing(edf.samples)
        @test nrow(edf.samples) > 0

        has_left = any(!isnan, edf.samples.gxL)
        has_right = any(!isnan, edf.samples.gxR)
        @test has_left || has_right

        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(edf, out_path)
            @test filesize(out_path) > 0
        finally
            isfile(out_path) && rm(out_path)
        end
    end
end

@testset "EDF to ASC round-trip" begin
    for test_name in ("test1", "test2", "test3")
        edf_path = joinpath(DATA_DIR_EYELINK, "$(test_name).edf")
        ref_path = joinpath(DATA_DIR_EYELINK, "$(test_name).asc")

        @testset "$test_name" begin
            out_path = tempname() * ".asc"
            try
                write_et_ascii(edf_path, out_path)

                @test isfile(out_path)
                @test filesize(out_path) > 0

                cmp = compare_asc_files(ref_path, out_path)
                @test cmp.sample_mismatches == 0
                @test abs(cmp.ref_counts[:efix] - cmp.jul_counts[:efix]) <= 5
                @test abs(cmp.ref_counts[:esacc] - cmp.jul_counts[:esacc]) <= 5
            finally
                isfile(out_path) && rm(out_path)
            end
        end
    end

    @testset "Default output path, self-overwrite guard, and sub-tenth float width" begin
        @test EyeFun._default_asc_output("session.edf") == "session_exported.asc"
        @test EyeFun._default_asc_output("session.asc") == "session_exported.asc"
        @test_throws ErrorException write_et_ascii(Main.TEST1_ASC, Main.TEST1_ASC.filename)

        # -0.04 rounds to 0.0 ("0.0", width 3), whereas -0.06 rounds to -0.1 ("-0.1", width 4)
        @test EyeFun._float1_width(-0.04f0) == 3
        @test EyeFun._float1_width(-0.06f0) == 4
        @test EyeFun._float1_width(Inf32) == 1
    end

    @testset "Directory and vector batch read_et_data & write_et_ascii" begin
        mktempdir() do tmpdir
            asc_template = "** BATCH TEST\nMSG\t1000 DISPLAY_COORDS 0 0 1279 959\nMSG\t1000 TRIALID 1\nSTART\t1000 \tLEFT\tSAMPLES\tEVENTS\nSAMPLES\tGAZE\tLEFT\tRATE\t1000.00\n1000\t  400.0\t  300.0\t 1100.0\t...\n1001\t  401.0\t  300.0\t 1102.0\t...\nEFIX L   1000\t1001\t2\t  400.5\t  300.0\t   1101\nEND\t1002 \tSAMPLES\tEVENTS\tRES\t  35.00\t  35.00\nMSG\t1002 TRIAL_RESULT 0\n"
            f1 = joinpath(tmpdir, "p1.asc")
            f2 = joinpath(tmpdir, "p2.asc")
            write(f1, asc_template)
            write(f2, asc_template)

            @test_throws ErrorException read_et_data(tmpdir)
            ed_dir = read_et_data(tmpdir; ext = ".asc")
            @test nrow(ed_dir) == 4
            @test Set(ed_dir.df.participant) == Set(["p1", "p2"])

            ed_vec = read_et_data([f1, f2]; participant_labels = ["SubjA", "SubjB"])
            @test Set(ed_vec.df.participant) == Set(["SubjA", "SubjB"])

            write_et_ascii(tmpdir; ext = ".asc")
            @test isfile(joinpath(tmpdir, "p1_exported.asc"))
            @test isfile(joinpath(tmpdir, "p2_exported.asc"))
        end
    end
end
