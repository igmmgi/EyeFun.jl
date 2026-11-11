using Documenter
using DocumenterVitepress
using JuliaFormatter
using Logging
using Pkg

push!(LOAD_PATH, dirname(@__DIR__))
using EyeFun

"""
Documentation Manager for EyeFun.jl

- Building documentation with Documenter.jl
- Documentation coverage analysis
- Code formatting with JuliaFormatter
- Cleanup and maintenance tasks
- Local preview server via LiveServer
- Interactive menu system

Usage:
    julia --project=docs docs/doc_manager.jl [command]

Commands:
    build                    - Build documentation
    coverage                 - Check documentation coverage
    format                   - Format Julia source and test files
    format-check             - Format files and run syntax check
    clean                    - Clean build and coverage artifacts
    view                     - Serve built documentation locally
    interactive              - Show interactive menu
    all                      - Run complete documentation workflow

If no command is provided, shows interactive menu.
"""

const RED = :red
const GREEN = :green
const YELLOW = :yellow
const BLUE = :blue
const CYAN = :cyan

print_colored(color::Symbol, message::String) = printstyled(message * "\n"; color = color)

function print_header()
    print_colored(BLUE, "EyeFun.jl Documentation Manager")
    println()
end

function get_project_root()
    return dirname(@__DIR__)
end

function _preceding_docstring_chars(lines::AbstractVector{<:AbstractString}, fn_line::Int)::Tuple{Bool,Int}
    j = fn_line - 1
    while j >= 1
        s = strip(lines[j])
        if isempty(s) || (startswith(s, "@") && !startswith(s, "@doc"))
            j -= 1
            continue
        end
        if endswith(s, "\"\"\"")
            if length(s) >= 6 && startswith(s, "\"\"\"")
                return (true, length(s))
            end
            doc_end = j
            doc_start = 0
            for k = (j-1):-1:1
                if startswith(strip(lines[k]), "\"\"\"")
                    doc_start = k
                    break
                end
            end
            if doc_start > 0
                chars = sum(length(strip(lines[k])) for k = doc_start:doc_end)
                return (true, chars)
            end
        elseif length(s) >= 2 && startswith(s, "\"") && endswith(s, "\"")
            return (true, length(s))
        end
        break
    end
    return (false, 0)
end

function build_documentation(project_root::String)
    try
        build_jl_path = joinpath(project_root, "docs", "make.jl")
        print_colored(GREEN, "Building documentation with Documenter.jl...")

        old_logger = global_logger()
        try
            logger = ConsoleLogger(stderr, Logging.Warn)
            global_logger(logger)
            include(build_jl_path)
        finally
            global_logger(old_logger)
        end
        print_colored(GREEN, "Documentation built successfully")

    catch e
        print_colored(RED, "Error building documentation: $e")
        return false
    end

    println()
    return true
end

function check_doc_coverage(project_root::String)
    print_colored(YELLOW, "Checking documentation coverage...")

    try
        doc_files = [
            joinpath(project_root, "docs", "src", "index.md"),
            joinpath(project_root, "docs", "make.jl"),
        ]
        missing_files = filter(!isfile, doc_files)

        if !isempty(missing_files)
            print_colored(RED, "Missing documentation files:")
            for file in missing_files
                println("  - $file")
            end
            return false
        end

        println("\nSource Code Documentation Analysis:")

        src_dir = joinpath(project_root, "src")
        source_files = String[]
        for (root, _, files) in walkdir(src_dir)
            for file in files
                if endswith(file, ".jl")
                    push!(source_files, joinpath(root, file))
                end
            end
        end

        total_functions = 0
        documented_functions = 0
        total_docstring_chars = 0
        files_with_docs = 0

        println("Analyzing $(length(source_files)) source files...")

        for file in source_files
            try
                content = read(file, String)
                lines = split(content, '\n')

                file_func_names = Dict{String,@NamedTuple{has_doc::Bool, doc_chars::Int}}()

                for i in eachindex(lines)
                    line = strip(lines[i])

                    fname_match = match(r"^(?:@inline\s+)?function\s+([\w!]+)", line)
                    if isnothing(fname_match)
                        fname_match = match(r"^(?:@inline\s+)?([\w!]+)\([^=]*\)(?:::[\w{}]+)?(?:\s+where\s+\{.*\})?\s*=(?!=)", line)
                    end

                    if !isnothing(fname_match)
                        fname = fname_match.captures[1]
                        docstring_found, this_doc_chars = _preceding_docstring_chars(lines, i)

                        if haskey(file_func_names, fname)
                            prev = file_func_names[fname]
                            file_func_names[fname] = (
                                has_doc = prev.has_doc || docstring_found,
                                doc_chars = prev.doc_chars + this_doc_chars,
                            )
                        else
                            file_func_names[fname] = (has_doc = docstring_found, doc_chars = this_doc_chars)
                        end
                    end
                end

                file_functions = length(file_func_names)
                file_documented = count(v -> v.has_doc, values(file_func_names))
                file_doc_chars = sum(v -> v.doc_chars, values(file_func_names); init = 0)

                total_functions += file_functions
                documented_functions += file_documented

                if file_functions > 0
                    if file_documented > 0
                        files_with_docs += 1
                    end
                    total_docstring_chars += file_doc_chars
                    println("  $(basename(file)): $file_documented/$file_functions functions documented")
                end

            catch e
                println("  Error reading $file: $e")
            end
        end

        coverage_percent =
            total_functions > 0 ? round((documented_functions / total_functions) * 100, digits = 1) : 0.0
        undoc_exports = Base.Docs.undocumented_names(EyeFun)

        println("\nDocumentation Coverage Summary:")
        println("  Total functions (incl. internal): $total_functions")
        println("  Documented functions: $documented_functions ($coverage_percent%)")
        println("  Undocumented exported symbols: $(length(undoc_exports))")
        println("  Files with docstrings: $files_with_docs/$(length(source_files))")
        println("  Total docstring characters: $total_docstring_chars")

        print_colored(GREEN, "\nDocumentation coverage analysis completed")

    catch e
        print_colored(RED, "Error checking documentation coverage: $e")
        return false
    end

    println()
    return true
end

function clean_docs(project_root::String)
    print_colored(YELLOW, "Cleaning documentation build artifacts...")

    build_dir = joinpath(project_root, "docs", "build")
    if isdir(build_dir)
        rm(build_dir, recursive = true)
        print_colored(GREEN, "Removed docs/build directory")
    else
        print_colored(YELLOW, "No build directory found")
    end

    artifacts = ["site", ".documenter"]
    for artifact in artifacts
        artifact_path = joinpath(project_root, "docs", artifact)
        if isdir(artifact_path) || isfile(artifact_path)
            rm(artifact_path, recursive = true)
            print_colored(GREEN, "Removed docs/$artifact")
        end
    end

    println("\nCleaning coverage files...")
    cov_count = 0
    for dir in ["src", "test"]
        dir_path = joinpath(project_root, dir)
        if isdir(dir_path)
            for (root, _, files) in walkdir(dir_path)
                for file in files
                    if endswith(file, ".cov")
                        rm(joinpath(root, file))
                        cov_count += 1
                    end
                end
            end
        end
    end
    if cov_count > 0
        print_colored(GREEN, "Removed $cov_count coverage file(s)")
    end

    print_colored(GREEN, "Documentation cleanup completed")
    println()
end

function format_source_files(project_root::String)
    print_colored(YELLOW, "Formatting Julia source files...")

    try
        src_dir = joinpath(project_root, "src")
        julia_files = String[]
        for (root, _, files) in walkdir(src_dir)
            for file in files
                if endswith(file, ".jl")
                    push!(julia_files, joinpath(root, file))
                end
            end
        end

        if isempty(julia_files)
            print_colored(YELLOW, "No Julia files found in src directory")
            return true
        end

        println("Found $(length(julia_files)) Julia file(s) to format:")
        for file in julia_files
            println("  - $file")
        end

        formatted_count = 0
        for file in julia_files
            try
                JuliaFormatter.format_file(file)
                formatted_count += 1
            catch e
                print_colored(RED, "Error formatting $file: $e")
            end
        end

        print_colored(GREEN, "Formatted $formatted_count/$(length(julia_files)) file(s)")

        test_dir = joinpath(project_root, "test")
        test_files = String[]
        for (root, _, files) in walkdir(test_dir)
            for file in files
                if endswith(file, ".jl")
                    push!(test_files, joinpath(root, file))
                end
            end
        end

        if !isempty(test_files)
            println("\nFormatting $(length(test_files)) test file(s)...")
            for file in test_files
                try
                    JuliaFormatter.format_file(file)
                catch e
                    print_colored(RED, "Error formatting $file: $e")
                end
            end
        end

    catch e
        print_colored(RED, "Error during formatting: $e")
        return false
    end

    println()
    return true
end

function format_and_check(project_root::String)
    print_colored(YELLOW, "Formatting and checking Julia files...")

    if !format_source_files(project_root)
        return false
    end

    print_colored(YELLOW, "Running syntax check...")
    try
        Pkg.precompile()
        print_colored(GREEN, "Syntax check passed")
    catch e
        print_colored(RED, "Syntax check failed: $e")
        return false
    end

    print_colored(GREEN, "Formatting and syntax check completed")
    println()
    return true
end

function view_documentation(project_root::String)
    print_colored(YELLOW, "Starting documentation server in background...")

    docs_proj = joinpath(project_root, "docs")
    build_dir = joinpath(docs_proj, "build", "1")
    if !isdir(build_dir)
        print_colored(RED, "Documentation not built yet. Run 'Build documentation' first.")
        return false
    end

    serve_expr = "using LiveServer; serve(dir=$(repr(build_dir)), launch_browser=true)"
    cmd = `julia --project=$docs_proj -e $serve_expr`
    run(cmd, wait = false)

    print_colored(GREEN, "Server started at http://localhost:8000")
    print_colored(CYAN, "(Server running in background - close browser tab when done)")

    return true
end

function run_all_docs(project_root::String)
    print_colored(GREEN, "Running complete documentation workflow...")
    println()

    if !format_source_files(project_root)
        print_colored(RED, "Formatting failed")
        return false
    end

    if !build_documentation(project_root)
        print_colored(RED, "Documentation build failed")
        return false
    end

    check_doc_coverage(project_root)
    print_colored(GREEN, "Documentation workflow complete.")

    return true
end

function show_interactive_menu(project_root::String)
    print_header()

    while true
        println("\nChoose an option:")
        println("1. Build documentation")
        println("2. Check documentation coverage")
        println("3. Format source files")
        println("4. Format and check syntax")
        println("5. Clean build artifacts")
        println("6. View documentation (via LiveServer)")
        println("7. Run complete workflow")
        println("8. Exit")

        print("\nEnter your choice (1-8): ")
        choice = readline()

        if choice == "1"
            build_documentation(project_root)
        elseif choice == "2"
            check_doc_coverage(project_root)
        elseif choice == "3"
            format_source_files(project_root)
        elseif choice == "4"
            format_and_check(project_root)
        elseif choice == "5"
            clean_docs(project_root)
        elseif choice == "6"
            view_documentation(project_root)
        elseif choice == "7"
            run_all_docs(project_root)
        elseif choice == "8"
            break
        else
            print_colored(RED, "Invalid choice. Please enter 1-8.")
        end
    end
end

function main()
    project_root = get_project_root()
    command = isempty(ARGS) ? "interactive" : ARGS[1]

    if command == "build"
        build_documentation(project_root)
    elseif command == "coverage"
        check_doc_coverage(project_root)
    elseif command == "format"
        format_source_files(project_root)
    elseif command == "format-check"
        format_and_check(project_root)
    elseif command == "clean"
        clean_docs(project_root)
    elseif command == "view"
        view_documentation(project_root)
    elseif command == "all"
        run_all_docs(project_root)
    elseif command == "interactive"
        show_interactive_menu(project_root)
    else
        print_header()
        println("Usage: julia --project=docs docs/doc_manager.jl [command]")
        println()
        println("Commands:")
        println("  build                    - Build documentation")
        println("  coverage                 - Check documentation coverage")
        println("  format                   - Format Julia source and test files")
        println("  format-check             - Format files and run syntax check")
        println("  clean                    - Clean build and coverage artifacts")
        println("  view                     - Serve built documentation locally")
        println("  interactive              - Show interactive menu")
        println("  all                      - Run complete documentation workflow")
        println()
        println("Examples:")
        println("  julia --project=docs docs/doc_manager.jl build")
        println("  julia --project=docs docs/doc_manager.jl coverage")
        println("  julia --project=docs docs/doc_manager.jl format")
        println("  julia --project=docs docs/doc_manager.jl clean")
        println("  julia --project=docs docs/doc_manager.jl view")
        println("  julia --project=docs docs/doc_manager.jl interactive")
    end
end

main()
