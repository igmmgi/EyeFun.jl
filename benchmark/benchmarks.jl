# BenchmarkTools-compatible benchmark suite for EyeFun.jl
# Usage (with BenchmarkTools installed in an active or stacked environment):
#   using BenchmarkTools
#   include("benchmark/benchmarks.jl")
#   results = run(SUITE; verbose = true)

using BenchmarkTools
using EyeFun
using DataFrames

const _BENCH_ROOT = dirname(@__DIR__)
const _BENCH_EDF1 = joinpath(_BENCH_ROOT, "resources", "data", "eyelink", "test1.edf")
const _BENCH_EDF3 = joinpath(_BENCH_ROOT, "resources", "data", "eyelink", "test3.edf")
const _BENCH_ASC1 = joinpath(_BENCH_ROOT, "resources", "data", "eyelink", "test1.asc")
const _BENCH_ASC3 = joinpath(_BENCH_ROOT, "resources", "data", "eyelink", "test3.asc")
const _BENCH_SMI_IDF = joinpath(_BENCH_ROOT, "resources", "data", "smi", "pp23671_rest1.idf")
const _BENCH_SMI_TXT = joinpath(_BENCH_ROOT, "resources", "data", "smi", "pp23671_rest1_samples.txt")
const _BENCH_TOBII = joinpath(_BENCH_ROOT, "resources", "data", "tobi", "sample_data.tsv")

const _RAW_EDF1 = EyeFun.read_eyelink(_BENCH_EDF1)
const _RAW_EDF3 = EyeFun.read_eyelink(_BENCH_EDF3)
const _ED1 = EyeFun.create_eyefun_data(_RAW_EDF1; trial_time_zero = "SYNCTIME")
const _AOIS = AOI[
    RectAOI("left", 100.0, 200.0, 400.0, 600.0),
    RectAOI("center", 510.0, 200.0, 910.0, 600.0),
    CircleAOI("fix", 512.0, 384.0, 80.0),
]

const SUITE = BenchmarkGroup()

SUITE["io"] = BenchmarkGroup()
SUITE["io"]["read_eyelink_edf1"] = @benchmarkable EyeFun.read_eyelink($_BENCH_EDF1)
SUITE["io"]["read_eyelink_edf3"] = @benchmarkable EyeFun.read_eyelink($_BENCH_EDF3)
SUITE["io"]["read_eyelink_asc1"] = @benchmarkable EyeFun.read_eyelink($_BENCH_ASC1)
SUITE["io"]["read_eyelink_asc3"] = @benchmarkable EyeFun.read_eyelink($_BENCH_ASC3)
SUITE["io"]["read_smi_idf"] = @benchmarkable EyeFun.read_smi($_BENCH_SMI_IDF)
SUITE["io"]["read_smi_txt"] = @benchmarkable EyeFun.read_smi($_BENCH_SMI_TXT)
SUITE["io"]["read_tobii_tsv"] = @benchmarkable EyeFun.read_tobii($_BENCH_TOBII)
SUITE["io"]["create_eyefun_data_edf1"] = @benchmarkable EyeFun.create_eyefun_data($_RAW_EDF1)
SUITE["io"]["create_eyefun_data_edf3"] = @benchmarkable EyeFun.create_eyefun_data($_RAW_EDF3)
SUITE["io"]["write_et_ascii_edf1"] = @benchmarkable begin
    mktemp() do p, io
        close(io)
        write_et_ascii($_RAW_EDF1, p)
    end
end

SUITE["events"] = BenchmarkGroup()
SUITE["events"]["fixations"] = @benchmarkable fixations($_ED1)
SUITE["events"]["saccades"] = @benchmarkable saccades($_ED1)
SUITE["events"]["blinks"] = @benchmarkable blinks($_ED1)
SUITE["events"]["detect_events_ivt"] = @benchmarkable detect_events!(ed; method = :ivt) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
SUITE["events"]["detect_events_idt"] = @benchmarkable detect_events!(ed; method = :idt) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
SUITE["events"]["detect_microsaccades"] = @benchmarkable detect_microsaccades!(ed) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1

SUITE["selection"] = BenchmarkGroup()
SUITE["selection"]["apply_selection_scalar"] = @benchmarkable EyeFun._apply_selection($_ED1, (trial = 1,))
SUITE["selection"]["apply_selection_range"] = @benchmarkable EyeFun._apply_selection($_ED1, (trial = 1:3,))

SUITE["analysis"] = BenchmarkGroup()
SUITE["analysis"]["data_quality"] = @benchmarkable data_quality($_ED1)
SUITE["analysis"]["group_summary"] = @benchmarkable group_summary($_ED1)
SUITE["analysis"]["smooth_pupil"] = @benchmarkable smooth_pupil!(ed) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
SUITE["analysis"]["interpolate_blinks"] = @benchmarkable interpolate_blinks!(ed) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
SUITE["analysis"]["aoi_metrics"] = @benchmarkable aoi_metrics($_ED1, $_AOIS)
SUITE["analysis"]["fixation_metrics"] = @benchmarkable fixation_metrics($_ED1, $_AOIS)
SUITE["analysis"]["saccade_metrics"] = @benchmarkable saccade_metrics($_ED1)
SUITE["analysis"]["time_bin"] = @benchmarkable time_bin($_ED1; bin_ms = 50, measure = :pupil)
SUITE["analysis"]["proportion_of_looks"] = @benchmarkable proportion_of_looks($_ED1, $_AOIS; bin_ms = 50)
SUITE["analysis"]["transition_matrix"] = @benchmarkable transition_matrix($_ED1, $_AOIS)
SUITE["analysis"]["scanpath_similarity"] = @benchmarkable scanpath_similarity($_ED1, $_AOIS; selection1 = (trial = 1,), selection2 = (trial = 2,))
SUITE["analysis"]["scanpath_multimatch"] = @benchmarkable scanpath_similarity($_ED1; selection1 = (trial = 1,), selection2 = (trial = 2,), method = :multimatch)
SUITE["analysis"]["spatial_precision"] = @benchmarkable spatial_precision($_ED1)
SUITE["analysis"]["pupil_peak_metrics"] = @benchmarkable pupil_peak_metrics($_ED1)
SUITE["analysis"]["savitzky_golay_filter"] = @benchmarkable savitzky_golay_filter!(ed) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
SUITE["analysis"]["pupil_filter"] = @benchmarkable pupil_filter!(ed) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
SUITE["analysis"]["correct_pupil_foreshortening"] = @benchmarkable correct_pupil_foreshortening!(ed) setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
SUITE["analysis"]["set_time_zero"] = @benchmarkable set_time_zero!(ed, "TRIALID") setup = (ed = EyeData(copy(_ED1.df); source = _ED1.source, sample_rate = _ED1.sample_rate, screen_res = _ED1.screen_res, screen_width_cm = _ED1.screen_width_cm, viewing_distance_cm = _ED1.viewing_distance_cm)) evals = 1
