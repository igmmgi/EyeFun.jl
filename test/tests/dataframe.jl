# ════════════════════════════════════════════════════════════════════════════ #
#  5. create_et_dataframe
# ════════════════════════════════════════════════════════════════════════════ #

@testset "create_eyelink_edf_dataframe" begin
    edf_path = joinpath(DATA_DIR, "test1.edf")
    isfile(edf_path) || @warn "test1.edf not found"

    if isfile(edf_path)
        edf = read_eyelink_edf_binary(edf_path)
        df = create_eyelink_edf_dataframe(edf)

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
    end
end
