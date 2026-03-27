
@testset "copycols=false safety" begin
    edf_path = joinpath(DATA_DIR, "test1.edf")
    isfile(edf_path) || @warn "test1.edf not found"

    if isfile(edf_path)
        edf = read_eyelink_edf(edf_path)

        @testset "Samples DataFrame is usable after read" begin
            # Verify types are correct (not degraded by copycols=false)
            @test eltype(edf.samples.time) == UInt32
            @test eltype(edf.samples.gxL) == Float32
            @test eltype(edf.samples.flags) == UInt16

            # Verify data is valid
            @test all(t -> t > UInt32(0), edf.samples.time)
            @test nrow(edf.samples) > 0
        end

        @testset "Events DataFrame columns are correct" begin
            @test nrow(edf.events) > 0
            @test hasproperty(edf.events, :type)
            @test hasproperty(edf.events, :sttime)
            @test hasproperty(edf.events, :message)
        end

        @testset "create_edf_dataframe result independent of source" begin
            df = EyeData(edf; trial_time_zero = nothing)
            original_time_first = edf.samples.time[1]

            # Mutating the result should not corrupt the EDFFile
            df.df.in_fix[1] = !df.df.in_fix[1]
            @test edf.samples !== nothing
            @test edf.samples.time[1] == original_time_first
        end
    end
end


# ════════════════════════════════════════════════════════════════════════════ #
#  13. export_to_ascii correctness
# ════════════════════════════════════════════════════════════════════════════ #

@testset "export_to_ascii" begin
    edf_path = joinpath(DATA_DIR, "test1.edf")
    isfile(edf_path) || @warn "test1.edf not found"

    if isfile(edf_path)
        edf = read_eyelink_edf(edf_path)

        @testset "Output is non-empty and parseable" begin
            out_path = tempname() * ".asc"
            try
                EyeFun.export_to_ascii(edf, out_path)

                @test isfile(out_path)
                @test filesize(out_path) > 0

                # Should be re-readable by the ASC reader
                edf2 = read_eyelink_asc(out_path)
                @test edf2 isa EyeFun.EDFFile
                @test edf2.samples !== nothing
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
                EyeFun.export_to_ascii(
                    edf,
                    out_path;
                    include_events = false,
                    include_messages = false,
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
                EyeFun.export_to_ascii(edf, out_path; include_samples = false)
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
end


# ════════════════════════════════════════════════════════════════════════════ #
#  14. Edge cases
# ════════════════════════════════════════════════════════════════════════════ #

@testset "Edge cases" begin
    @testset "Binocular EDF" begin
        bino_path = joinpath(DATA_DIR, "test3.edf")
        if isfile(bino_path)
            edf = read_eyelink_edf(bino_path)
            @test edf.samples !== nothing
            @test nrow(edf.samples) > 0

            # Binocular data should have valid data in both eye columns
            has_left = any(!isnan, edf.samples.gxL)
            has_right = any(!isnan, edf.samples.gxR)
            @test has_left || has_right

            # Export binocular data
            out_path = tempname() * ".asc"
            try
                EyeFun.export_to_ascii(edf, out_path)
                @test filesize(out_path) > 0
            finally
                isfile(out_path) && rm(out_path)
            end
        end
    end

    @testset "Message parsing with null bytes" begin
        edf_path = joinpath(DATA_DIR, "test1.edf")
        if isfile(edf_path)
            edf = read_eyelink_edf(edf_path)
            msg_df = messages(edf)
            @test nrow(msg_df) > 0

            # No message should contain null bytes after parsing
            for m in msg_df.message
                @test !occursin('\0', m)
            end
        end
    end

    @testset "Empty parser inputs" begin
        empty_events = DataFrame()
        @test nrow(EyeFun.parse_fixations(empty_events)) == 0
        @test nrow(EyeFun.parse_saccades(empty_events)) == 0
        @test nrow(EyeFun.parse_blinks(empty_events)) == 0
        @test nrow(EyeFun.parse_messages(empty_events)) == 0
    end
end
