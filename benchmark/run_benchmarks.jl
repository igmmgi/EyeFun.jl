# Zero-extra-dependency benchmark runner & regression comparator for EyeFun.jl
#
# Usage:
#   julia --project=. benchmark/run_benchmarks.jl
#   julia --project=. benchmark/run_benchmarks.jl --save=baseline.json
#   julia --project=. benchmark/run_benchmarks.jl --compare=baseline.json
#   julia --project=. benchmark/run_benchmarks.jl --compare=baseline.json --fail-on-alloc-regression
#   julia --project=. benchmark/run_benchmarks.jl --compare=baseline.json --fail-on-regression

using EyeFun
using DataFrames
using Printf
using Logging

const ROOT = dirname(@__DIR__)
const EDF1_PATH = joinpath(ROOT, "resources", "data", "eyelink", "test1.edf")
const EDF3_PATH = joinpath(ROOT, "resources", "data", "eyelink", "test3.edf")
const ASC1_PATH = joinpath(ROOT, "resources", "data", "eyelink", "test1.asc")
const ASC3_PATH = joinpath(ROOT, "resources", "data", "eyelink", "test3.asc")
const SMI_IDF_PATH = joinpath(ROOT, "resources", "data", "smi", "pp23671_rest1.idf")
const SMI_TXT_PATH = joinpath(ROOT, "resources", "data", "smi", "pp23671_rest1_samples.txt")
const TOBII_PATH = joinpath(ROOT, "resources", "data", "tobi", "sample_data.tsv")

function _clone_ed(ed::EyeData)
    return EyeData(
        copy(ed.df),
        ed.source,
        ed.sample_rate,
        ed.screen_res,
        ed.screen_width_cm,
        ed.viewing_distance_cm,
    )
end

function _measure(f::F; setup = () -> nothing, samples::Int = 7) where {F}
    with_logger(NullLogger()) do
        arg = setup()
        arg === nothing ? f() : f(arg) # warmup
        best_ms = Inf
        best_bytes = typemax(Int)
        best_allocs = typemax(Int)
        for _ = 1:samples
            arg_i = setup()
            GC.gc(false)
            stats = if arg_i === nothing
                @timed f()
            else
                @timed f(arg_i)
            end
            t_ms = stats.time * 1000.0
            allocs = Base.gc_alloc_count(stats.gcstats)
            if t_ms < best_ms
                best_ms = t_ms
            end
            if stats.bytes < best_bytes
                best_bytes = stats.bytes
                best_allocs = allocs
            end
        end
        return (time_ms = best_ms, bytes = best_bytes, allocs = best_allocs)
    end
end

function _write_json(path::AbstractString, entries::Vector{Pair{String,NamedTuple{(:time_ms, :bytes, :allocs),Tuple{Float64,Int,Int}}}})
    open(path, "w") do io
        println(io, "{")
        for (i, (k, v)) in enumerate(entries)
            comma = i < length(entries) ? "," : ""
            @printf(
                io,
                "  %s: {\"time_ms\": %.6f, \"bytes\": %d, \"allocs\": %d}%s\n",
                repr(k),
                v.time_ms,
                v.bytes,
                v.allocs,
                comma
            )
        end
        println(io, "}")
    end
end

function _read_json(path::AbstractString)
    text = read(path, String)
    out = Dict{String,NamedTuple{(:time_ms, :bytes, :allocs),Tuple{Float64,Int,Int}}}()
    re = r"\"([^\"]+)\"\s*:\s*\{\s*\"time_ms\"\s*:\s*([0-9.eE+-]+)\s*,\s*\"bytes\"\s*:\s*(\d+)\s*,\s*\"allocs\"\s*:\s*(\d+)\s*\}"
    for m in eachmatch(re, text)
        out[m.captures[1]] = (
            time_ms = parse(Float64, m.captures[2]),
            bytes = parse(Int, m.captures[3]),
            allocs = parse(Int, m.captures[4]),
        )
    end
    return out
end

function _fmt_bytes(b::Real)
    abs_b = abs(Float64(b))
    if abs_b >= 1024^2
        return @sprintf("%.2f MiB", b / 1024^2)
    elseif abs_b >= 1024
        return @sprintf("%.1f KiB", b / 1024)
    else
        return @sprintf("%d B", round(Int, b))
    end
end

function main(args::Vector{String})
    save_path = nothing
    compare_path = nothing
    fail_on_alloc = false
    fail_on_time = false
    for a in args
        if startswith(a, "--save=")
            save_path = a[8:end]
        elseif startswith(a, "--compare=")
            compare_path = a[11:end]
        elseif a == "--fail-on-alloc-regression"
            fail_on_alloc = true
        elseif a == "--fail-on-time-regression"
            fail_on_time = true
        elseif a == "--fail-on-regression"
            fail_on_alloc = true
            fail_on_time = true
        end
    end

    raw_edf1, raw_edf3, ed1 = with_logger(NullLogger()) do
        r1 = EyeFun.read_eyelink(EDF1_PATH)
        r3 = EyeFun.read_eyelink(EDF3_PATH)
        e1 = EyeFun.create_eyefun_data(r1; trial_time_zero = "SYNCTIME")
        (r1, r3, e1)
    end

    aois = AOI[
        RectAOI("left", 100.0, 200.0, 400.0, 600.0),
        RectAOI("center", 510.0, 200.0, 910.0, 600.0),
        CircleAOI("fix", 512.0, 384.0, 80.0),
    ]

    tmp_asc = tempname() * ".asc"

    specs = Tuple{String,Function,Function,Int}[
        ("io/read_eyelink(test1.edf)", () -> nothing, () -> EyeFun.read_eyelink(EDF1_PATH), 7),
        ("io/read_eyelink(test3.edf)", () -> nothing, () -> EyeFun.read_eyelink(EDF3_PATH), 7),
        ("io/read_eyelink(test1.asc)", () -> nothing, () -> EyeFun.read_eyelink(ASC1_PATH), 5),
        ("io/read_eyelink(test3.asc)", () -> nothing, () -> EyeFun.read_eyelink(ASC3_PATH), 5),
        ("io/read_smi(rest1.idf)", () -> nothing, () -> EyeFun.read_smi(SMI_IDF_PATH), 7),
        ("io/read_smi(rest1.txt)", () -> nothing, () -> EyeFun.read_smi(SMI_TXT_PATH), 5),
        ("io/read_tobii(sample.tsv)", () -> nothing, () -> EyeFun.read_tobii(TOBII_PATH), 7),
        ("io/create_eyefun_data(edf1)", () -> nothing, () -> EyeFun.create_eyefun_data(raw_edf1), 7),
        ("io/create_eyefun_data(edf3)", () -> nothing, () -> EyeFun.create_eyefun_data(raw_edf3), 5),
        ("io/write_et_ascii(edf1)", () -> nothing, () -> write_et_ascii(raw_edf1, tmp_asc), 5),
        ("events/fixations", () -> nothing, () -> fixations(ed1), 9),
        ("events/saccades", () -> nothing, () -> saccades(ed1), 9),
        ("events/blinks", () -> nothing, () -> blinks(ed1), 9),
        ("events/detect_events!(:ivt)", () -> _clone_ed(ed1), ed -> detect_events!(ed; method = :ivt), 7),
        ("events/detect_events!(:idt)", () -> _clone_ed(ed1), ed -> detect_events!(ed; method = :idt), 7),
        ("events/detect_microsaccades!", () -> _clone_ed(ed1), ed -> detect_microsaccades!(ed), 5),
        ("selection/_apply_selection(scalar)", () -> nothing, () -> EyeFun._apply_selection(ed1, (trial = 1,)), 9),
        ("selection/_apply_selection(range)", () -> nothing, () -> EyeFun._apply_selection(ed1, (trial = 1:3,)), 9),
        ("analysis/data_quality", () -> nothing, () -> data_quality(ed1), 7),
        ("analysis/group_summary", () -> nothing, () -> group_summary(ed1), 7),
        ("analysis/smooth_pupil!", () -> _clone_ed(ed1), ed -> smooth_pupil!(ed), 7),
        ("analysis/interpolate_blinks!", () -> _clone_ed(ed1), ed -> interpolate_blinks!(ed), 7),
        ("analysis/aoi_metrics", () -> nothing, () -> aoi_metrics(ed1, aois), 5),
        ("analysis/fixation_metrics", () -> nothing, () -> fixation_metrics(ed1, aois), 5),
        ("analysis/saccade_metrics", () -> nothing, () -> saccade_metrics(ed1), 7),
        ("analysis/time_bin", () -> nothing, () -> time_bin(ed1; bin_ms = 50, measure = :pupil), 7),
        ("analysis/proportion_of_looks", () -> nothing, () -> proportion_of_looks(ed1, aois; bin_ms = 50), 5),
        ("analysis/transition_matrix", () -> nothing, () -> transition_matrix(ed1, aois), 7),
        ("analysis/scanpath_similarity", () -> nothing, () -> scanpath_similarity(ed1, aois; selection1 = (trial = 1,), selection2 = (trial = 2,)), 7),
    ]

    entries = Pair{String,NamedTuple{(:time_ms, :bytes, :allocs),Tuple{Float64,Int,Int}}}[]
    for (name, setup_fn, run_fn, n_samp) in specs
        res = _measure(run_fn; setup = setup_fn, samples = n_samp)
        push!(entries, name => res)
    end
    isfile(tmp_asc) && rm(tmp_asc; force = true)

    if !isnothing(compare_path)
        ref = _read_json(compare_path)
        println("| Benchmark | Before | After | Speedup | Mem Before | Mem After | Allocs Before -> After |")
        println("|---|---:|---:|---:|---:|---:|---:|")
        regressed = String[]
        time_regressed = String[]
        for (name, cur) in entries
            if haskey(ref, name)
                old = ref[name]
                speedup = old.time_ms / max(cur.time_ms, 1e-6)
                @printf(
                    "| `%s` | %.2f ms | %.2f ms | **%.2f×** | %s | %s | %d -> %d |\n",
                    name,
                    old.time_ms,
                    cur.time_ms,
                    speedup,
                    _fmt_bytes(old.bytes),
                    _fmt_bytes(cur.bytes),
                    old.allocs,
                    cur.allocs
                )
                # Flag >15% + >4 KiB allocation regressions
                if cur.bytes > max(old.bytes * 1.15, old.bytes + 4096)
                    push!(regressed, name)
                end
                # Flag >20% + >2.5 ms runtime regressions
                if cur.time_ms > max(old.time_ms * 1.20, old.time_ms + 2.5)
                    push!(time_regressed, name)
                end
            else
                @printf(
                    "| `%s` | n/a | %.2f ms | n/a | n/a | %s | n/a -> %d |\n",
                    name,
                    cur.time_ms,
                    _fmt_bytes(cur.bytes),
                    cur.allocs
                )
            end
        end
        failed = false
        if !isempty(regressed)
            println("\nAllocation regressions (>15%): ", join(regressed, ", "))
            fail_on_alloc && (failed = true)
        end
        if !isempty(time_regressed)
            println("\nRuntime regressions (>20% & >2.5 ms): ", join(time_regressed, ", "))
            fail_on_time && (failed = true)
        end
        failed && exit(1)
    else
        println("| Benchmark | Min Time | Memory | Allocations |")
        println("|---|---:|---:|---:|")
        for (name, cur) in entries
            @printf(
                "| `%s` | %.2f ms | %s | %d |\n",
                name,
                cur.time_ms,
                _fmt_bytes(cur.bytes),
                cur.allocs
            )
        end
    end

    if !isnothing(save_path)
        mkpath(dirname(abspath(save_path)))
        _write_json(save_path, entries)
        println("\nSaved benchmark baseline to: ", save_path)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
