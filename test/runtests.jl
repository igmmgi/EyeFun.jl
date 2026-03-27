using Test
using EyeFun
using DataFrames
using Makie
using Statistics

const DATA_DIR = joinpath(dirname(@__DIR__), "resources", "data", "eyelink")

println("Running EyeFun.jl Test Suite")
println("=" ^ 40)

@testset "EyeFun" begin

    include("tests/asc_comparison.jl")
    include("tests/round_trip.jl")
    include("tests/asc_reader.jl")
    include("tests/io.jl")
    include("tests/dataframe.jl")
    include("tests/event_accessors.jl")
    include("tests/plotting.jl")
    include("tests/analysis.jl")
    include("tests/detect_events.jl")
    include("tests/ascii_exporter.jl")
    include("tests/safety.jl")
    include("tests/smi.jl")
    include("tests/tobii.jl")

end

println("\nAll tests completed!")
