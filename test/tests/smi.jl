@testset "SMI reader" begin
    smi_dir = joinpath(dirname(dirname(@__DIR__)), "resources", "data", "smi")

    @testset "read_smi (txt)" begin
        txt_path = joinpath(smi_dir, "pp23671_rest1_samples.txt")
        if isfile(txt_path)
            ed = read_smi(txt_path)
            @test ed isa EyeData
            @test ed.source == :smi
            @test ed.sample_rate == 50.0
            @test nrow(ed.df) > 0
            @test hasproperty(ed.df, :gxL)
            @test hasproperty(ed.df, :gyL)
            @test hasproperty(ed.df, :paL)
            @test hasproperty(ed.df, :time)
            @test hasproperty(ed.df, :trial)
            # Should have some valid data (not all NaN)
            @test any(!isnan, ed.df.gxL)
        else
            @warn "SMI test data not found, skipping txt test"
        end
    end

    @testset "read_smi (idf)" begin
        idf_path = joinpath(smi_dir, "pp23671_rest1.idf")
        if isfile(idf_path)
            ed = read_smi(idf_path)
            @test ed isa EyeData
            @test ed.source == :smi
            @test nrow(ed.df) > 0
            @test hasproperty(ed.df, :gxL)
            @test hasproperty(ed.df, :time)
            # Should have some valid data
            @test any(!isnan, ed.df.gxL)
        else
            @warn "SMI IDF test data not found, skipping idf test"
        end
    end
end
