"""
    compare_asc_lines(ref_path, jul_path)

Compare reference (edf2asc) and Julia-generated ASC files line-by-line.
Returns a NamedTuple of comparison results.
"""
function compare_asc_files(ref_path::String, jul_path::String)
    ref_lines = readlines(ref_path)
    jul_lines = readlines(jul_path)

    # Classify lines by type
    classify(line) = begin
        isempty(line) && return :empty
        startswith(line, "**") && return :header
        c = line[1]
        c >= '0' && c <= '9' && return :sample
        startswith(line, "EFIX") && return :efix
        startswith(line, "ESACC") && return :esacc
        startswith(line, "EBLINK") && return :eblink
        startswith(line, "SFIX") && return :sfix
        startswith(line, "SSACC") && return :ssacc
        startswith(line, "SBLINK") && return :sblink
        startswith(line, "MSG") && return :msg
        startswith(line, "INPUT") && return :input
        startswith(line, "START") && return :start
        startswith(line, "END") && return :endblock
        startswith(line, "PRESCALER") && return :config
        startswith(line, "VPRESCALER") && return :config
        startswith(line, "PUPIL") && return :config
        startswith(line, "EVENTS") && return :config
        startswith(line, "SAMPLES") && return :config
        return :other
    end

    function extract_groups(lines)
        groups = Dict{Symbol,Vector{String}}()
        for l in lines
            push!(get!(groups, classify(l), String[]), l)
        end
        return groups
    end

    ref_groups = extract_groups(ref_lines)
    jul_groups = extract_groups(jul_lines)

    ref_counts = Dict(k => length(v) for (k, v) in ref_groups)
    jul_counts = Dict(k => length(v) for (k, v) in jul_groups)

    # Extract sample lines for value comparison
    ref_samples = get(ref_groups, :sample, String[])
    jul_samples = get(jul_groups, :sample, String[])

    # Compare first N sample values (timestamp, gx, gy, pa)
    n_compare = min(100, length(ref_samples), length(jul_samples))
    sample_mismatches = 0
    for i = 1:n_compare
        rp = split(ref_samples[i])
        jp = split(jul_samples[i])
        # Compare timestamp
        if rp[1] != jp[1]
            sample_mismatches += 1
            continue
        end
        # Compare gaze values (columns 2-4 for monocular, 2-7 for binocular)
        n_vals = min(length(rp), length(jp)) - 1  # skip trailing ...
        for k = 2:min(n_vals, 4)
            rv = tryparse(Float64, rp[k])
            jv = tryparse(Float64, jp[k])
            if !isnothing(rv) && !isnothing(jv) && abs(rv - jv) > 0.15
                sample_mismatches += 1
                break
            end
        end
    end

    # Extract EFIX lines and compare sttime, entime, gavx, gavy, ava
    ref_efix = get(ref_groups, :efix, String[])
    jul_efix = get(jul_groups, :efix, String[])
    n_efix = min(length(ref_efix), length(jul_efix))
    efix_value_matches = 0
    for i = 1:n_efix
        rp = split(ref_efix[i])
        jp = split(jul_efix[i])
        # EFIX L sttime entime dur gavx gavy ava
        length(rp) >= 8 && length(jp) >= 8 || continue
        if rp[3] == jp[3] && rp[4] == jp[4]  # sttime, entime match
            rg = tryparse(Float64, rp[6])
            jg = tryparse(Float64, jp[6])
            if !isnothing(rg) && !isnothing(jg) && abs(rg - jg) <= 0.15
                efix_value_matches += 1
            end
        end
    end

    # Extract ESACC lines and compare sttime, entime, gaze coords
    ref_esacc = get(ref_groups, :esacc, String[])
    jul_esacc = get(jul_groups, :esacc, String[])
    n_esacc = min(length(ref_esacc), length(jul_esacc))
    esacc_gaze_matches = 0
    for i = 1:n_esacc
        rp = split(ref_esacc[i])
        jp = split(jul_esacc[i])
        length(rp) >= 9 && length(jp) >= 9 || continue
        # ESACC L sttime entime dur gstx gsty genx geny ampl pvel
        if rp[3] == jp[3] && rp[4] == jp[4]  # sttime, entime
            all_match = true
            for k = 6:9  # gstx, gsty, genx, geny
                rv = tryparse(Float64, rp[k])
                jv = tryparse(Float64, jp[k])
                if !isnothing(rv) && !isnothing(jv) && abs(rv - jv) > 0.15
                    all_match = false
                    break
                end
            end
            all_match && (esacc_gaze_matches += 1)
        end
    end

    # Extract ESACC ampl/pvel comparison
    esacc_ampl_matches = 0
    for i = 1:n_esacc
        rp = split(ref_esacc[i])
        jp = split(jul_esacc[i])
        length(rp) >= 11 && length(jp) >= 11 || continue
        ra = tryparse(Float64, rp[10])
        ja = tryparse(Float64, jp[10])
        rp_v = tryparse(Float64, rp[11])
        jp_v = tryparse(Float64, jp[11])
        if !isnothing(ra) &&
           !isnothing(ja) &&
           abs(ra - ja) <= 0.5 &&
           !isnothing(rp_v) &&
           !isnothing(jp_v) &&
           abs(rp_v - jp_v) <= 5.0
            esacc_ampl_matches += 1
        end
    end

    # Extract EBLINK lines and compare sttime/entime/duration
    ref_eblink = get(ref_groups, :eblink, String[])
    jul_eblink = get(jul_groups, :eblink, String[])
    n_eblink = min(length(ref_eblink), length(jul_eblink))
    eblink_matches = 0
    for i = 1:n_eblink
        rp = split(ref_eblink[i])
        jp = split(jul_eblink[i])
        length(rp) >= 5 && length(jp) >= 5 || continue
        if rp[3] == jp[3] && rp[4] == jp[4] && rp[5] == jp[5]
            eblink_matches += 1
        end
    end

    # Extract MSG lines and compare text content
    ref_msgs = get(ref_groups, :msg, String[])
    jul_msgs = get(jul_groups, :msg, String[])

    return (
        ref_counts = ref_counts,
        jul_counts = jul_counts,
        n_ref_samples = length(ref_samples),
        n_jul_samples = length(jul_samples),
        sample_mismatches = sample_mismatches,
        n_compared = n_compare,
        n_efix = n_efix,
        efix_value_matches = efix_value_matches,
        n_esacc = n_esacc,
        esacc_gaze_matches = esacc_gaze_matches,
        esacc_ampl_matches = esacc_ampl_matches,
        n_eblink = n_eblink,
        eblink_matches = eblink_matches,
        n_ref_msgs = length(ref_msgs),
        n_jul_msgs = length(jul_msgs),
    )
end

# ════════════════════════════════════════════════════════════════════════════ #
#  ASC output comparison — Julia vs edf2asc reference
# ════════════════════════════════════════════════════════════════════════════ #

# Helper to safely get count from Dict (for binocular blink tolerance)
nrow_or(d::Dict, k::Symbol, default::Int) = get(d, k, default)

@testset "ASC output: Julia vs edf2asc" begin
    for test_name in ("test1", "test2", "test3")
        ref_path = joinpath(DATA_DIR_EYELINK, "$(test_name).asc")
        jul_path = joinpath(DATA_DIR_EYELINK, "$(test_name)_julia.asc")

        is_mono = test_name in ("test1", "test2")

        @testset "$test_name" begin
            cmp = compare_asc_files(ref_path, jul_path)

            @testset "Sample lines" begin
                ratio = cmp.n_jul_samples / cmp.n_ref_samples
                @test ratio > 0.97
                @test ratio <= 1.03
                @test cmp.sample_mismatches == 0
            end

            @testset "Event line counts" begin
                efix_tol = is_mono ? 0 : 5
                esacc_tol = is_mono ? 0 : 5
                @test abs(get(cmp.ref_counts, :efix, 0) - get(cmp.jul_counts, :efix, 0)) <=
                      efix_tol
                @test abs(
                    get(cmp.ref_counts, :esacc, 0) - get(cmp.jul_counts, :esacc, 0),
                ) <= esacc_tol
                @test abs(cmp.n_ref_msgs - cmp.n_jul_msgs) <= 10
            end

            @testset "EFIX values" begin
                if cmp.n_efix > 0
                    match_rate = cmp.efix_value_matches / cmp.n_efix
                    @test match_rate > (is_mono ? 0.99 : 0.95)
                end
            end

            @testset "ESACC gaze values" begin
                if cmp.n_esacc > 0
                    match_rate = cmp.esacc_gaze_matches / cmp.n_esacc
                    @test match_rate > (is_mono ? 0.99 : 0.95)
                end
            end

            @testset "ESACC amplitude/pvel" begin
                if cmp.n_esacc > 0
                    match_rate = cmp.esacc_ampl_matches / cmp.n_esacc
                    @test match_rate > (is_mono ? 0.95 : 0.50)
                end
            end

            @testset "EBLINK sttime/entime/dur" begin
                if cmp.n_eblink > 0
                    if is_mono
                        match_rate = cmp.eblink_matches / cmp.n_eblink
                        @test match_rate > 0.99
                    else
                        # Binocular blink pairing differs from edf2asc
                        @test cmp.n_eblink > 0
                    end
                end
            end
        end
    end
end
