@testset "Tobii TSV reader" begin
    tobii_dir = joinpath(dirname(dirname(@__DIR__)), "resources", "data", "tobi")

    @testset "read_tobii — returns TobiiFile" begin
        raw = Main.TEST_TOBII_TSV
        @test raw isa TobiiFile
        @test raw.sample_rate ≈ 500.0
        @test raw.subject == "P1"
        
        # Defaults
        @test raw.screen_res == (1920, 1080)
        @test raw.screen_width_cm == 53.0
        @test raw.viewing_distance_cm == 60.0

        @test nrow(raw.samples) > 0
        @test nrow(raw.events) > 0

        # Raw samples
        @test hasproperty(raw.samples, :gxL)
        @test hasproperty(raw.samples, :gyL)
        @test hasproperty(raw.samples, :paL)
        @test hasproperty(raw.samples, :time)
        @test hasproperty(raw.samples, :participant)
        @test hasproperty(raw.samples, :message)
        @test !hasproperty(raw.samples, :in_fix)    # not yet detected
        
        @test any(!isnan, raw.samples.gxL)
        
        # Events
        @test hasproperty(raw.events, :type)
        @test hasproperty(raw.events, :message)
        @test hasproperty(raw.events, :time)
    end

    @testset "create_eyefun_data(TobiiFile) — returns EyeData with events" begin
        raw = Main.TEST_TOBII_TSV
        ed = create_eyefun_data(deepcopy(raw))

        @test ed isa EyeData
        @test ed.source == :tobii
        @test ed.sample_rate ≈ 500.0
        @test ed.screen_res == (1920, 1080)
        @test nrow(ed.df) == nrow(raw.samples)
        @test hasproperty(ed.df, :message)

        # Before detect_events!: event columns are absent
        @test !hasproperty(ed.df, :in_fix)
        @test !hasproperty(ed.df, :in_sacc)
        @test !hasproperty(ed.df, :in_blink)

        # Run event detection
        detect_events!(ed)

        # Event columns populated
        @test hasproperty(ed.df, :in_fix)
        @test hasproperty(ed.df, :in_sacc)
        @test hasproperty(ed.df, :in_blink)
        @test hasproperty(ed.df, :fix_gavx)
        @test hasproperty(ed.df, :sacc_gstx)
        @test hasproperty(ed.df, :blink_dur)

        # High-level accessors work
        fix = fixations(ed)
        @test fix isa DataFrame
        @test nrow(fix) > 0

        sacc = saccades(ed)
        @test sacc isa DataFrame
        @test nrow(sacc) > 0

        blk = blinks(ed)
        @test blk isa DataFrame
        # Sometimes parsing doesn't produce NaN blinks if the eye openness criteria or just general loss of tracking isn't there, 
        # but usually it works. For now, testing type.
    end
end
