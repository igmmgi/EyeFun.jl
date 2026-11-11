```@meta
CollapsedDocStrings = true
```

# Plotting & Audio Functions

All public plotting and audio functions in EyeFun.jl.

## Index

```@index
Pages = ["plotting.md"]
```

## Plotting Functions

```@autodocs
Modules = [EyeFun]
Private = false
Order = [:function]
Filter = t -> startswith(String(nameof(t)), "plot_")
```

## Stimulus & Audio Utilities

```@docs
EyeFun.load_image
EyeFun.image_size
EyeFun.play_wav
```
