```@meta
CollapsedDocStrings = true
```

# Analysis Functions

All public I/O, event accessor, and analysis functions in EyeFun.jl.

## Index

```@index
Pages = ["analysis.md"]
```

## Functions

```@autodocs
Modules = [EyeFun]
Private = false
Order = [:function, :macro]
Filter = t -> !startswith(String(nameof(t)), "_") && !startswith(String(nameof(t)), "plot_") && !(t in (EyeFun.play_wav, EyeFun.load_image, EyeFun.image_size))
```
