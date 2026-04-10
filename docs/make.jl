using Documenter
using DocumenterVitepress

# Add the parent directory to the load path so we can load the local package
push!(LOAD_PATH, dirname(@__DIR__))
using EyeFun


pages = [
    "Home" => "index.md",
    "Getting Started" => [
        "Setup & Installation" => "tutorials/getting-started.md",
        "IDE Workflows" => "tutorials/ide-workflows.md",
        "Julia Basics" => "tutorials/julia-basics.md",
    ],
    "Tutorials" => [
        "Overview" => "tutorials/index.md",
        "Data Structures" => "explanations/data-structures.md",
        "Reading EDF Files" => "tutorials/reading-edf.md",
        "Event Analysis" => "tutorials/event-analysis.md",
        "Pupil Processing" => "tutorials/pupil-processing.md",
        "AOI Analysis" => "tutorials/aoi-analysis.md",
        "Event Detection" => "tutorials/event-detection.md",
        "Batch Processing" => "tutorials/batch-processing.md",
    ],
    "How-to Guides" => [
        "I/O" => [
            "Read EDF (Binary)" => "demos/io/read-edf-binary.md",
            "Read ASC" => "demos/io/read-asc.md",
            "Export to ASC" => "demos/io/export-asc.md",
            "Batch Read" => "demos/io/batch-read.md",
        ],
        "Analysis" => [
            "Data Quality" => "demos/analysis/data-quality.md",
            "Fixation Analysis" => "demos/analysis/fixation-analysis.md",
            "Saccade Analysis" => "demos/analysis/saccade-analysis.md",
            "Blink Interpolation" => "demos/analysis/blink-interpolation.md",
            "Pupil Preprocessing" => "demos/analysis/pupil-preprocessing.md",
            "Drift Correction" => "demos/analysis/drift-correction.md",
            "AOI Metrics" => "demos/analysis/aoi-metrics.md",
            "Microsaccades" => "demos/analysis/microsaccades.md",
            "Event Detection (I-VT/I-DT)" => "demos/analysis/event-detection.md",
        ],
        "Plotting" => [
            "Gaze Plot" => "demos/plotting/plot-gaze.md",
            "Scanpath" => "demos/plotting/plot-scanpath.md",
            "Heatmap" => "demos/plotting/plot-heatmap.md",
            "Fixations" => "demos/plotting/plot-fixations.md",
            "Pupil" => "demos/plotting/plot-pupil.md",
            "Velocity" => "demos/plotting/plot-velocity.md",
            "Dwell Time" => "demos/plotting/plot-dwell.md",
            "Stimulus Browser" => "demos/plotting/plot-stimuli.md",
            "Data Browser" => "demos/plotting/plot-databrowser.md",
        ],
    ],
    "Reference" => [
        "Overview" => "reference/index.md",
        "Analysis" => "reference/analysis.md",
        "Plotting" => "reference/plotting.md",
        "Types" => "reference/types.md",
    ],
]

makedocs(;
    modules = [EyeFun],
    authors = "igmmgi",
    sitename = "EyeFun",
    repo = "https://github.com/igmmgi/EyeFun.jl",
    format = DocumenterVitepress.MarkdownVitepress(repo = "https://github.com/igmmgi/EyeFun.jl", devbranch = "main"),
    warnonly = [:linkcheck, :cross_references, :missing_docs],
    draft = false,
    source = "src",
    build = "build",
    pages = pages,
)

# Deploy built VitePress site
DocumenterVitepress.deploydocs(repo = "github.com/igmmgi/EyeFun.jl", devbranch = "main", push_preview = true)
