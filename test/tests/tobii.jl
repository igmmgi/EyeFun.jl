@testset "Tobii TSV reader" begin
    @testset "read_tobii: TobiiFile" begin
        raw = Main.TEST_TOBII_TSV
        @test raw isa EyeFun.TobiiFile
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

    @testset "create_eyefun_data(TobiiFile): EyeData with events" begin
        raw = Main.TEST_TOBII_TSV
        ed = EyeFun.create_eyefun_data(deepcopy(raw))

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
    end

    @testset "Stimulus transition deduplication" begin
        tmp_tsv = tempname() * ".tsv"
        try
            write(
                tmp_tsv,
                join(
                    [
                        "Recording timestamp [ms]\tParticipant name\tGaze point left X [DACS px]\tGaze point left Y [DACS px]\tPupil diameter left [mm]\tValidity left\tPresented Stimulus name\tEvent\tEvent value",
                        "0\tS1\t500,5\t400,25\t3,2\tValid\tSlide1.png\t\t",
                        "2\tS1\t501,0\t401,0\t3,2\tValid\tSlide1.png\t\t",
                        "4\tS1\t\t\t\tInvalid\tSlide1.png\t\t",
                        "6\tS1\t520,0\t410,0\t3,3\tValid\tSlide2.png\tTrigger\tOnset",
                    ],
                    "\n",
                ),
            )
            tob = read_tobii(tmp_tsv)
            @test nrow(tob.samples) == 4
            @test tob.samples.gxL[1] ≈ 500.5f0
            @test tob.samples.gyL[1] ≈ 400.25f0
            @test isnan(tob.samples.gxL[3])
            # Slide1.png emitted only once at onset (row 1), not repeated on rows 2 & 3
            @test tob.samples.message[1] == "Stimulus: Slide1.png"
            @test tob.samples.message[2] == ""
            @test tob.samples.message[3] == ""
            @test occursin("Stimulus: Slide2.png", tob.samples.message[4])
            @test occursin("Trigger: Onset", tob.samples.message[4])
            @test nrow(tob.events) == 1
        finally
            isfile(tmp_tsv) && rm(tmp_tsv)
        end
    end

    @testset "Sensor filtering and microsecond timestamps" begin
        raw = Main.TEST_TOBII_TSV
        @test raw.samples.time[1] == 41.0
        @test occursin("RecordingStart", raw.samples.message[1])
        @test !hasproperty(raw.samples, :pupxL)

        tmp_us = tempname() * ".tsv"
        try
            write(
                tmp_us,
                join(
                    [
                        "Recording timestamp [μs]\tParticipant name\tSensor\tGaze point left X [DACS px]\tGaze point left Y [DACS px]\tPupil diameter left [mm]\tValidity left\tEvent",
                        "0\tP2\t\t\t\t\t\tRecordingStart",
                        "2000\tP2\tEye Tracker\t600.0\t450.0\t3.5\tValid\t",
                        "4000\tP2\tMouse\t\t\t\t\tMouseEvent",
                        "6000\tP2\tEye Tracker\t602.0\t451.0\t3.6\tValid\t",
                    ],
                    "\n",
                ),
            )
            tob_us = read_tobii(tmp_us)
            @test nrow(tob_us.samples) == 2
            @test tob_us.samples.time == [2.0, 6.0]
            @test occursin("RecordingStart", tob_us.samples.message[1])
            @test occursin("MouseEvent", tob_us.samples.message[2])
            @test nrow(tob_us.events) == 2
        finally
            isfile(tmp_us) && rm(tmp_us)
        end
    end
end
