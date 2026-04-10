# Interactive test script for EyeFun.jl
# Run line-by-line in the REPL or with `julia --project=. test_interactive.jl`

using EyeFun
using DataFrames
using GLMakie


# ─────────────────────────────────────────────────────────────────────────────
# EyeLink data 
# ─────────────────────────────────────────────────────────────────────────────

stim = read_stimuli("/home/ian/Desktop/EyeTracking/data_2016/exp/")
plot_stimuli(stim)

# sr_ed_txt = read_et_data("/home/ian/Desktop/EyeTracking/data_2016/edf/201.asc");
# write_et_ascii("/home/ian/Desktop/EyeTracking/data_2016/edf/201.edf")

sr_ed_edf = read_et_data("/home/ian/Desktop/EyeTracking/data_2016/edf/201.edf");


aoi_size = 200
aoi = [
    RectAOI("Top", sr_ed_edf.screen_res[1] / 2, sr_ed_edf.screen_res[2] * 0.25, aoi_size, aoi_size),
    RectAOI("Bottom", sr_ed_edf.screen_res[1] / 2, sr_ed_edf.screen_res[2] * 0.75, aoi_size, aoi_size),
    RectAOI("Left", sr_ed_edf.screen_res[1] * 0.25, sr_ed_edf.screen_res[2] * 0.5, aoi_size, aoi_size),
    RectAOI("Right", sr_ed_edf.screen_res[1] * 0.75, sr_ed_edf.screen_res[2] * 0.5, aoi_size, aoi_size)
]

# Custom Layout Parser
# Simply write a function that takes a dataframe row and your stim dictionary,
# and returns a Vector of AbstractEyeFunMedia types.
function parse_my_experiment_layout(row, stim)

    println("Extracting trial ", row.trial)

    media = AbstractEyeFunMedia[]

    # Each trial has two audio file columns, but might be empty on non-sentence trials
    for col in [:soundfile_1, :soundfile_2]
        if string(row[col]) != "EMPTY.wav"
            audio_key = string(row[col])
            if haskey(stim, audio_key)
                push!(media, AudioMedia(content=stim[audio_key]))
                println("  -> Audio [$col]: $audio_key")
            end
        end
    end

    # Grid layout
    grid_pairs = []
    if string(row.GRID) != "[]"
        grid_pairs = eval(Meta.parse(string(row.GRID)))
    end

    layout_vars = ["targplat", "incgoalplat", "compplat", "goalplat", "targobject", "incgoalobject", "compobject", "goalobject"]
    stim_map = Dict(lowercase(splitext(k)[1]) => k for k in keys(stim) if splitext(k)[2] ∈ [".gif", ".bmp", ".png", ".jpg"])

    for slot_name in layout_vars
        val_col, loc_col = Symbol(slot_name), Symbol(slot_name * "loc")

        if string(row[val_col]) != "EMPTY" && string(row[loc_col]) != "NA" && !isempty(grid_pairs)
            asset_key = lowercase(string(row[val_col]))
            slot_idx = Int(row[loc_col]) + 1  # +1: Python 0-based → Julia 1-based

            filename = get(stim_map, asset_key, get(stim_map, asset_key * "_plat", nothing))
            img_data = stim[filename]
            h, w = size(img_data)
            cx, cy = grid_pairs[slot_idx][1] + w / 2, grid_pairs[slot_idx][2] + h / 2

            push!(media, ImageMedia(content=img_data, position=(Float64(cx), Float64(cy))))
            println("  -> Visual [$filename] at ($cx, $cy)")
        end
    end

    return media
end

plot_databrowser(sr_ed_edf, split_by=:trial, aois=aoi, stimuli=stim, match_stimuli=parse_my_experiment_layout);


# Individual plots (whole dataset)
plot_gaze(sr_ed_edf)
plot_pupil(sr_ed_edf)
plot_velocity(sr_ed_edf)
plot_fixations(sr_ed_edf)
plot_scanpath(sr_ed_edf)
plot_heatmap(sr_ed_edf)

# Individual plots (per trial)
plot_gaze(sr_ed_edf, split_by=:trial)
plot_pupil(sr_ed_edf, split_by=:trial)
plot_velocity(sr_ed_edf, split_by=:trial)
plot_fixations(sr_ed_edf, split_by=:trial)
plot_scanpath(sr_ed_edf, split_by=:trial)
plot_heatmap(sr_ed_edf, split_by=:trial)


# --- Test Pipeline: EyeLink EDF ---
detect_events!(sr_ed_edf)
fixations(sr_ed_edf)
saccades(sr_ed_edf)
blinks(sr_ed_edf)
interpolate_blinks!(sr_ed_edf)

plot_databrowser(sr_ed_edf)
plot_gaze(sr_ed_edf)
plot_pupil(sr_ed_edf)
plot_velocity(sr_ed_edf)
plot_fixations(sr_ed_edf)
plot_scanpath(sr_ed_edf)
plot_heatmap(sr_ed_edf)


# ─────────────────────────────────────────────────────────────────────────────
# Tobii data 
# ─────────────────────────────────────────────────────────────────────────────
tob_ed_tsv = read_et_data("resources/data/tobi/sample_data.tsv")

# --- Test Pipeline: Tobii TSV ---
detect_events!(tob_ed_tsv)
fixations(tob_ed_tsv)
saccades(tob_ed_tsv)
blinks(tob_ed_tsv)
interpolate_blinks!(tob_ed_tsv)

plot_databrowser(tob_ed_tsv)
plot_gaze(tob_ed_tsv)
plot_pupil(tob_ed_tsv)
plot_velocity(tob_ed_tsv)
plot_fixations(tob_ed_tsv)
plot_scanpath(tob_ed_tsv)
plot_heatmap(tob_ed_tsv)

# ─────────────────────────────────────────────────────────────────────────────
# SMI data 
# ─────────────────────────────────────────────────────────────────────────────
smi_ed_txt = read_et_data("resources/data/smi/pp23671_task1_samples.txt")
smi_ed_idf = read_et_data("resources/data/smi/pp23671_task1.idf")
write_et_ascii("resources/data/smi/pp23671_task1.idf")

# --- Test Pipeline: SMI TXT ---
detect_events!(smi_ed_txt)
fixations(smi_ed_txt)
saccades(smi_ed_txt)
blinks(smi_ed_txt)
interpolate_blinks!(smi_ed_txt)

plot_databrowser(smi_ed_idf)
plot_gaze(smi_ed_txt)
plot_pupil(smi_ed_txt)
plot_velocity(smi_ed_txt)
plot_fixations(smi_ed_txt)
plot_scanpath(smi_ed_txt)
plot_heatmap(smi_ed_txt)

# --- Test Pipeline: SMI IDF ---
detect_events!(smi_ed_idf)
fixations(smi_ed_idf)
saccades(smi_ed_idf)
blinks(smi_ed_idf)
interpolate_blinks!(smi_ed_idf)

plot_databrowser(smi_ed_idf)
plot_gaze(smi_ed_idf)
plot_pupil(smi_ed_idf)
plot_velocity(smi_ed_idf)
plot_fixations(smi_ed_idf)
plot_scanpath(smi_ed_idf)
plot_heatmap(smi_ed_idf)

