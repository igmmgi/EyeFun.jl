# Allocation ceilings for I/O readers, event accessors, selection, preprocessing, and analysis

@testset "Performance & allocation ceilings" begin
    # Code coverage instrumentation (--code-coverage=user) disables some inlining/SROA
    cov_scale = Base.JLOptions().code_coverage == 0 ? 1 : 4

    edf = Main.TEST1_EDF
    ed = EyeFun.create_eyefun_data(edf; trial_time_zero = "SYNCTIME")
    aois = AOI[
        RectAOI("left", 100.0, 200.0, 400.0, 600.0),
        RectAOI("center", 510.0, 200.0, 910.0, 600.0),
        CircleAOI("fix", 512.0, 384.0, 80.0),
    ]

    # Event accessors
    fixations(ed)
    saccades(ed)
    blinks(ed)
    @test (@allocated fixations(ed)) < 64 * 1024 * cov_scale
    @test (@allocated saccades(ed)) < 96 * 1024 * cov_scale
    @test (@allocated blinks(ed)) < 32 * 1024 * cov_scale

    # Selection helpers
    EyeFun._apply_selection(ed, (trial = 1,))
    EyeFun._apply_selection_view(ed, (trial = 1,))
    @test (@allocated EyeFun._apply_selection(ed, (trial = 1,))) < 1_500_000 * cov_scale
    @test (@allocated EyeFun._apply_selection_view(ed, (trial = 1,))) < 512 * 1024 * cov_scale

    # In-place preprocessing and event detection
    ed_work = copy(ed)
    smooth_pupil!(ed_work)
    interpolate_blinks!(ed_work)
    savitzky_golay_filter!(ed_work)
    pupil_filter!(ed_work)
    correct_pupil_foreshortening!(ed_work)
    detect_events!(ed_work; method = :ivt)
    detect_microsaccades!(ed_work)

    @test (@allocated smooth_pupil!(ed_work)) < 2_000_000 * cov_scale
    @test (@allocated interpolate_blinks!(ed_work)) < 2_000_000 * cov_scale
    @test (@allocated savitzky_golay_filter!(ed_work)) < 5_000_000 * cov_scale
    @test (@allocated pupil_filter!(ed_work)) < 5_000_000 * cov_scale
    @test (@allocated correct_pupil_foreshortening!(ed_work)) < 2_000_000 * cov_scale
    @test (@allocated detect_events!(ed_work; method = :ivt)) < 24_000_000 * cov_scale
    @test (@allocated detect_microsaccades!(ed_work)) < 12_000_000 * cov_scale

    # Summary and scanpath metrics
    data_quality(ed)
    spatial_precision(ed)
    group_summary(ed)
    pupil_peak_metrics(ed)
    aoi_metrics(ed, aois)
    fixation_metrics(ed, aois)
    saccade_metrics(ed)
    time_bin(ed; bin_ms = 50)
    proportion_of_looks(ed, aois; bin_ms = 50)
    transition_matrix(ed, aois)
    scanpath_similarity(ed, aois; selection1 = (trial = 1,), selection2 = (trial = 2,))

    @test (@allocated data_quality(ed)) < 256 * 1024 * cov_scale
    @test (@allocated spatial_precision(ed)) < 4_000_000 * cov_scale
    @test (@allocated group_summary(ed)) < 256 * 1024 * cov_scale
    @test (@allocated pupil_peak_metrics(ed)) < 4_000_000 * cov_scale
    @test (@allocated aoi_metrics(ed, aois)) < 5_000_000 * cov_scale
    @test (@allocated fixation_metrics(ed, aois)) < 5_000_000 * cov_scale
    @test (@allocated saccade_metrics(ed)) < 5_000_000 * cov_scale
    @test (@allocated time_bin(ed; bin_ms = 50)) < 5_000_000 * cov_scale
    @test (@allocated proportion_of_looks(ed, aois; bin_ms = 50)) < 5_000_000 * cov_scale
    @test (@allocated transition_matrix(ed, aois)) < 64 * 1024 * cov_scale
    @test (
        @allocated scanpath_similarity(
            ed,
            aois;
            selection1 = (trial = 1,),
            selection2 = (trial = 2,),
        )
    ) < 512 * 1024 * cov_scale

    # File readers, EyeData conversion, and ASCII exporter
    test3_edf_path = joinpath(Main.DATA_DIR_EYELINK, "test3.edf")
    edf3 = read_eyelink(test3_edf_path)
    read_eyelink(Main.TEST1_EDF_PATH)
    read_eyelink(test3_edf_path)
    read_eyelink(Main.TEST1_ASC_PATH)
    read_smi(Main.TEST_SMI_IDF_PATH)
    read_smi(Main.TEST_SMI_TXT_PATH)
    read_tobii(Main.TEST_TOBII_TSV_PATH)
    create_eyefun_data(edf; trial_time_zero = nothing)
    create_eyefun_data(edf3; trial_time_zero = nothing)

    @test (@allocated read_eyelink(Main.TEST1_EDF_PATH)) < 20_000_000 * cov_scale
    @test (@allocated read_eyelink(test3_edf_path)) < 24_000_000 * cov_scale
    @test (@allocated read_eyelink(Main.TEST1_ASC_PATH)) < 20_000_000 * cov_scale
    @test (@allocated read_smi(Main.TEST_SMI_IDF_PATH)) < 12_000_000 * cov_scale
    @test (@allocated read_smi(Main.TEST_SMI_TXT_PATH)) < 8_000_000 * cov_scale
    @test (@allocated read_tobii(Main.TEST_TOBII_TSV_PATH)) < 2_500_000 * cov_scale
    @test (@allocated create_eyefun_data(edf; trial_time_zero = nothing)) < 20_000_000 * cov_scale
    @test (@allocated create_eyefun_data(edf3; trial_time_zero = nothing)) < 18_000_000 * cov_scale

    tmp_asc = tempname() * ".asc"
    try
        write_et_ascii(edf, tmp_asc)
        @test (@allocated write_et_ascii(edf, tmp_asc)) < 2_500_000 * cov_scale
    finally
        isfile(tmp_asc) && rm(tmp_asc)
    end
end

