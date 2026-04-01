# ════════════════════════════════════════════════════════════════════════════ #
#  create_et_dataframe
# ════════════════════════════════════════════════════════════════════════════ #

@testset "create_eyefun_data" begin
    edf = Main.TEST1_EDF
    df = Main.TEST1_DF

        @test df isa EyeData
        @test nrow(df.df) == nrow(edf.samples)

        # All expected columns present (including new ones)
        for col in [
            :time,
            :gxL,
            :gyL,
            :paL,
            :in_fix,
            :fix_gavx,
            :fix_gavy,
            :fix_ava,
            :fix_dur,
            :in_sacc,
            :sacc_gstx,
            :sacc_gsty,
            :sacc_genx,
            :sacc_geny,
            :sacc_dur,
            :sacc_ampl,
            :sacc_pvel,
            :in_blink,
            :blink_dur,
            :message,
        ]
            @test hasproperty(df.df, col)
        end

        # Annotations have data
        @test any(df.df.in_fix)
        @test any(df.df.in_sacc)
        @test any(df.df.in_blink)

        # New columns have real values in annotated regions
        sacc_rows = df.df[df.df.in_sacc, :]
        @test any(!isnan, sacc_rows.sacc_ampl)
        @test any(!isnan, sacc_rows.sacc_pvel)
        @test any(>(0), df.df[df.df.in_blink, :blink_dur])

        # Messages exist at trigger timestamps
        @test any(!isempty, df.df.message)

        @testset "copycols=false safety" begin
            # Verify types are correct (not degraded by copycols=false)
            @test eltype(edf.samples.time) == UInt32
            @test eltype(edf.samples.gxL) == Float32
            @test eltype(edf.samples.flags) == UInt16

            # Verify data is valid
            @test all(t -> t > UInt32(0), edf.samples.time)

            # Events DataFrame columns are correct
            @test nrow(edf.events) > 0
            @test hasproperty(edf.events, :type)
            @test hasproperty(edf.events, :sttime)
            @test hasproperty(edf.events, :message)

            ed = create_eyefun_data(edf; trial_time_zero = nothing)
            original_time_first = edf.samples.time[1]

            # Mutating the result should not corrupt the EDFFile
            ed.df.in_fix[1] = !ed.df.in_fix[1]
            @test !isnothing(edf.samples)
            @test edf.samples.time[1] == original_time_first
        end
end
