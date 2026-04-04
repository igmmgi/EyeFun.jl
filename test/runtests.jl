using Test
using EyeFun
using DataFrames
using Makie
using Statistics

println("Running EyeFun.jl Test Suite")
println("="^40)

# Get some data for the tests
# Data paths
const DATA_DIR_EYELINK = joinpath(dirname(@__DIR__), "resources", "data", "eyelink")
const DATA_DIR_SMI = joinpath(dirname(@__DIR__), "resources", "data", "smi")
const DATA_DIR_TOBII = joinpath(dirname(@__DIR__), "resources", "data", "tobi")

# SR Research
const TEST1_EDF_PATH = joinpath(DATA_DIR_EYELINK, "test1.edf")
const TEST1_ASC_PATH = joinpath(DATA_DIR_EYELINK, "test1.asc")
println("Loading global test data from EyeLink...")
const TEST1_EDF = EyeFun.read_eyelink(TEST1_EDF_PATH)
const TEST1_DF = EyeFun.create_eyefun_data(TEST1_EDF; trial_time_zero = nothing)
const TEST1_ASC = EyeFun.read_eyelink(TEST1_ASC_PATH)

# TODO: I am not familiar with SMI/TOBII so this will probably need to be updated
# SMI
const TEST_SMI_TXT_PATH = joinpath(DATA_DIR_SMI, "pp23671_rest1_samples.txt")
const TEST_SMI_IDF_PATH = joinpath(DATA_DIR_SMI, "pp23671_rest1.idf")
println("Loading global test data from SMI...")
const TEST_SMI_TXT = EyeFun.read_smi(TEST_SMI_TXT_PATH)
const TEST_SMI_IDF = EyeFun.read_smi(TEST_SMI_IDF_PATH)

# TOBII
const TEST_TOBII_TSV_PATH = joinpath(DATA_DIR_TOBII, "sample_data.tsv")
println("Loading global test data from Tobii TSV...")
const TEST_TOBII_TSV = EyeFun.read_tobii(TEST_TOBII_TSV_PATH)
# ─────────────────────────────────────────────────────────────────────── #

@testset "EyeFun" begin

    include("tests/eyelink_validation.jl")
    include("tests/eyelink_import.jl")
    include("tests/dataframe.jl")
    include("tests/event_accessors.jl")
    include("tests/plotting.jl")
    include("tests/analysis.jl")
    include("tests/detect_events.jl")
    include("tests/eyelink_export.jl")
    include("tests/smi.jl")
    include("tests/tobii.jl")

end

println("\nAll tests completed!")
