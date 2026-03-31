using Test
using EyeFun
using DataFrames
using Makie
using Statistics

const DATA_DIR = joinpath(dirname(@__DIR__), "resources", "data", "eyelink")

println("Running EyeFun.jl Test Suite")
println("=" ^ 40)

# ── Global Test Fixtures ─────────────────────────────────────────────── #
const DATA_DIR_SMI = joinpath(dirname(@__DIR__), "resources", "data", "smi")
const DATA_DIR_TOBII = joinpath(dirname(@__DIR__), "resources", "data", "tobi")

const TEST1_EDF_PATH = joinpath(DATA_DIR, "test1.edf")
if isfile(TEST1_EDF_PATH)
    println("Loading global test fixtures from test1.edf...")
    const TEST1_EDF = read_eyelink(TEST1_EDF_PATH)
    const TEST1_DF  = EyeData(TEST1_EDF; trial_time_zero = nothing)
else
    @warn "test1.edf not found in $(DATA_DIR). Many tests will be skipped."
end

const TEST_SMI_TXT_PATH = joinpath(DATA_DIR_SMI, "pp23671_rest1_samples.txt")
const TEST_SMI_IDF_PATH = joinpath(DATA_DIR_SMI, "pp23671_rest1.idf")
if isfile(TEST_SMI_TXT_PATH) && isfile(TEST_SMI_IDF_PATH)
    println("Loading global test fixtures from SMI...")
    const TEST_SMI_TXT = read_smi(TEST_SMI_TXT_PATH)
    const TEST_SMI_IDF = read_smi(TEST_SMI_IDF_PATH)
else
    @warn "SMI data missing in $(DATA_DIR_SMI)."
end

const TEST_TOBII_TSV_PATH = joinpath(DATA_DIR_TOBII, "sample_data.tsv")
if isfile(TEST_TOBII_TSV_PATH)
    println("Loading global test fixtures from Tobii TSV...")
    const TEST_TOBII_TSV = read_tobii(TEST_TOBII_TSV_PATH)
else
    @warn "Tobii TSV missing in $(DATA_DIR_TOBII)."
end
# ─────────────────────────────────────────────────────────────────────── #

@testset "EyeFun" begin

    include("tests/ascii_comparison.jl")
    include("tests/round_trip.jl")
    include("tests/ascii_reader.jl")
    include("tests/io.jl")
    include("tests/dataframe.jl")
    include("tests/event_accessors.jl")
    include("tests/plotting.jl")
    include("tests/analysis.jl")
    include("tests/detect_events.jl")
    include("tests/ascii_exporter.jl")
    include("tests/smi.jl")
    include("tests/tobii.jl")

end

println("\nAll tests completed!")
