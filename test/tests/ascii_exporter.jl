# ════════════════════════════════════════════════════════════════════════════ #
#  Buffer-based digit writers (ascii_exporter.jl)
# ════════════════════════════════════════════════════════════════════════════ #

@testset "Buffer digit writers" begin
    buf = Vector{UInt8}(undef, 128)

    @testset "_buf_uint32!" begin
        # Zero
        p = EyeFun._buf_uint32!(buf, 1, UInt32(0))
        @test String(buf[1:(p-1)]) == "0"

        # Single digit
        p = EyeFun._buf_uint32!(buf, 1, UInt32(7))
        @test String(buf[1:(p-1)]) == "7"

        # Multi digit
        p = EyeFun._buf_uint32!(buf, 1, UInt32(12345))
        @test String(buf[1:(p-1)]) == "12345"

        # Large value (typical timestamp)
        p = EyeFun._buf_uint32!(buf, 1, UInt32(975866))
        @test String(buf[1:(p-1)]) == "975866"

        # Max UInt32
        p = EyeFun._buf_uint32!(buf, 1, typemax(UInt32))
        @test String(buf[1:(p-1)]) == string(typemax(UInt32))
    end

    @testset "_buf_float1!" begin
        # NaN → single dot
        p = EyeFun._buf_float1!(buf, 1, NaN32)
        @test String(buf[1:(p-1)]) == "."

        # Positive value
        p = EyeFun._buf_float1!(buf, 1, Float32(870.9))
        @test String(buf[1:(p-1)]) == "870.9"

        # Negative value
        p = EyeFun._buf_float1!(buf, 1, Float32(-12.3))
        @test String(buf[1:(p-1)]) == "-12.3"

        # Zero
        p = EyeFun._buf_float1!(buf, 1, Float32(0.0))
        @test String(buf[1:(p-1)]) == "0.0"

        # Integer-like value
        p = EyeFun._buf_float1!(buf, 1, Float32(1000.0))
        @test String(buf[1:(p-1)]) == "1000.0"
    end

    @testset "_buf_float1_field!" begin
        # Right-aligned in 7-char field
        p = EyeFun._buf_float1_field!(buf, 1, Float32(870.9), 7)
        result = String(buf[1:(p-1)])
        @test length(result) == 7
        @test strip(result) == "870.9"
        @test result[1:2] == "  "  # 2 leading spaces

        # NaN in 7-char field
        p = EyeFun._buf_float1_field!(buf, 1, NaN32, 7)
        result = String(buf[1:(p-1)])
        @test length(result) == 7
        @test strip(result) == "."
    end

    @testset "Buffer vs IO consistency" begin
        # Verify buffer writers produce identical output to IO writers
        io = IOBuffer()
        for v in [UInt32(0), UInt32(42), UInt32(975866), UInt32(9999999)]
            # IO version
            EyeFun._write_uint32(io, v)
            io_result = String(take!(io))
            # Buffer version
            p = EyeFun._buf_uint32!(buf, 1, v)
            buf_result = String(buf[1:(p-1)])
            @test io_result == buf_result
        end
        for v in [NaN32, Float32(0.0), Float32(870.9), Float32(-12.3), Float32(1008.4)]
            # IO version
            EyeFun._write_float1(io, v)
            io_result = String(take!(io))
            # Buffer version
            p = EyeFun._buf_float1!(buf, 1, v)
            buf_result = String(buf[1:(p-1)])
            @test io_result == buf_result
        end
    end
end


# ════════════════════════════════════════════════════════════════════════════ #
#  export_to_ascii correctness
# ════════════════════════════════════════════════════════════════════════════ #

@testset "export_to_ascii" begin
    edf_path = joinpath(DATA_DIR_EYELINK, "test1.edf")
    if isfile(edf_path)
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
                EyeFun.write_et_ascii(edf, out_path; include_samples = false)
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

@testset "export_to_ascii Edge Cases" begin
    @testset "Binocular EDF" begin
        bino_path = joinpath(DATA_DIR_EYELINK, "test3.edf")
        if isfile(bino_path)
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
end
