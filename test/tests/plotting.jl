# ════════════════════════════════════════════════════════════════════════════ #
#  Plotting functions (return Figure, no rendering needed)
# ════════════════════════════════════════════════════════════════════════════ #

@testset "Plotting functions" begin
    df = Main.TEST1_DF

    aoi_regions =
        [RectAOI("Center", 640, 480, 400, 400), RectAOI("TopLeft", 160, 120, 320, 240)]

    @testset "plot_gaze (DataFrame)" begin
        fig = plot_gaze(df; selection=(trial=1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_scanpath (DataFrame)" begin
        fig = plot_scanpath(df; selection=(trial=1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_scanpath with aois" begin
        fig = plot_scanpath(df; selection=(trial=1,), aois=aoi_regions)
        @test fig isa Makie.Figure
    end

    @testset "plot_heatmap (DataFrame)" begin
        fig = plot_heatmap(df; selection=(trial=1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_heatmap with aois" begin
        fig = plot_heatmap(df; selection=(trial=1,), aois=aoi_regions)
        @test fig isa Makie.Figure
    end

    @testset "plot_heatmap metrics" begin
        for m in (:samples, :dwell, :count, :proportion)
            fig = plot_heatmap(df; selection=(trial=1,), metric=m)
            @test fig isa Makie.Figure
        end
    end

    @testset "plot_fixations" begin
        fig = plot_fixations(df; selection=(trial=1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_fixations with aois" begin
        fig = plot_fixations(df; selection=(trial=1,), aois=aoi_regions)
        @test fig isa Makie.Figure
    end

    @testset "plot_pupil" begin
        fig = plot_pupil(df; selection=(trial=1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_velocity" begin
        fig = plot_velocity(df; selection=(trial=1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_dwell" begin
        fig = plot_dwell(df, aoi_regions; selection=(trial=1,))
        @test fig isa Makie.Figure
    end

    @testset "plot_sequence" begin
        fig = plot_sequence(df; selection=(trial=1:5,))
        @test fig isa Makie.Figure
    end

    @testset "plot_transitions" begin
        fig = plot_transitions(df, aoi_regions; selection=(trial=1:5,))
        @test fig isa Makie.Figure
    end

    @testset "plot_comparison" begin
        if hasproperty(df.df, :type)
            fig = plot_comparison(df; compare_by=:type)
            @test fig isa Makie.Figure
        end
    end
end
