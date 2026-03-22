# ════════════════════════════════════════════════════════════════════════════ #
#  Live round-trip: EDF → ASC export → re-read
# ════════════════════════════════════════════════════════════════════════════ #

@testset "EDF → ASC round-trip" begin
    for test_name in ("test1", "test2", "test3")
        edf_path = joinpath(DATA_DIR, "$(test_name).edf")
        ref_path = joinpath(DATA_DIR, "$(test_name).asc")
        (isfile(edf_path) && isfile(ref_path)) || continue

        @testset "$test_name" begin
            # Generate ASC from EDF
            out_path = tempname() * ".asc"
            try
                write_eyelink_edf_to_asc(edf_path, out_path)

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
