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
Filter = t -> !startswith(string(t), "_") && !startswith(string(t), "plot_") && t !== EyeFun.play_wav
```
