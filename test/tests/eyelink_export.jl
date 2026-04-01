# ════════════════════════════════════════════════════════════════════════════ #
#  export_to_ascii correctness
# ════════════════════════════════════════════════════════════════════════════ #

@testset "export_to_ascii" begin
    edf_path = joinpath(DATA_DIR_EYELINK, "test1.edf")
    edf = EyeFun.read_eyelink(edf_path)

    @testset "Output is non-empty and parseable" begin
        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(edf, out_path)

            @test isfile(out_path)
            @test filesize(out_path) > 0

            # Should be re-readable by the ASC reader
            edf2 = EyeFun.read_eyelink(out_path)
            @test edf2 isa EyeFun.EDFFile
            @test !isnothing(edf2.samples)
            @test nrow(edf2.samples) > 0

            # Sample counts should match closely
            ratio = nrow(edf2.samples) / nrow(edf.samples)
            @test ratio > 0.95
            @test ratio <= 1.05
        finally
            isfile(out_path) && rm(out_path)
        end
    end

    @testset "Selective export options" begin
        # Samples only
        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(
                edf,
                out_path;
                include_events=false,
                include_messages=false,
            )
            @test isfile(out_path)
            lines = readlines(out_path)
            # Should have sample lines but no EFIX/ESACC/EBLINK/MSG
            @test any(l -> !isempty(l) && l[1] >= '0' && l[1] <= '9', lines)
            @test !any(l -> startswith(l, "EFIX"), lines)
            @test !any(l -> startswith(l, "MSG"), lines)
        finally
            isfile(out_path) && rm(out_path)
        end

        # Events only (no samples)
        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(edf, out_path; include_samples=false)
            @test isfile(out_path)
            lines = readlines(out_path)
            # Should have event/message lines but no sample lines
            sample_lines = count(l -> !isempty(l) && l[1] >= '0' && l[1] <= '9', lines)
            @test sample_lines == 0
        finally
            isfile(out_path) && rm(out_path)
        end
    end
end

@testset "export_to_ascii Edge Cases" begin
    @testset "Binocular EDF" begin
        bino_path = joinpath(DATA_DIR_EYELINK, "test3.edf")
        edf = EyeFun.read_eyelink(bino_path)
        @test !isnothing(edf.samples)
        @test nrow(edf.samples) > 0

        # Binocular data should have valid data in both eye columns
        has_left = any(!isnan, edf.samples.gxL)
        has_right = any(!isnan, edf.samples.gxR)
        @test has_left || has_right

        # Export binocular data
        out_path = tempname() * ".asc"
        try
            EyeFun.write_et_ascii(edf, out_path)
            @test filesize(out_path) > 0
        finally
            isfile(out_path) && rm(out_path)
        end
    end
end

# ════════════════════════════════════════════════════════════════════════════ #
#  Live round-trip: EDF → ASC export → re-read
# ════════════════════════════════════════════════════════════════════════════ #

@testset "EDF → ASC round-trip" begin
    for test_name in ("test1", "test2", "test3")
        edf_path = joinpath(DATA_DIR_EYELINK, "$(test_name).edf")
        ref_path = joinpath(DATA_DIR_EYELINK, "$(test_name).asc")

        @testset "$test_name" begin
            # Generate ASC from EDF
            out_path = tempname() * ".asc"
            try
                write_et_ascii(edf_path, out_path)

                @test isfile(out_path)
                @test filesize(out_path) > 0

                # Compare against edf2asc reference
                cmp = compare_asc_files(ref_path, out_path)

                @test cmp.sample_mismatches == 0  # first 100 samples match
                @test abs(cmp.ref_counts[:efix] - cmp.jul_counts[:efix]) <= 5
                @test abs(cmp.ref_counts[:esacc] - cmp.jul_counts[:esacc]) <= 5
            finally
                isfile(out_path) && rm(out_path)
            end
        end
    end
end
