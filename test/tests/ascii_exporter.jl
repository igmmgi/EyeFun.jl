# ════════════════════════════════════════════════════════════════════════════ #
#  11. Buffer-based digit writers (ascii_exporter.jl)
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
#  12. copycols=false safety — DataFrame independence
# ════════════════════════════════════════════════════════════════════════════ #
