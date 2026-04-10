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
Order = [:function]
Filter = t -> startswith(string(t), "plot_")
```

## Audio Functions

```@docs
EyeFun.list_audio_devices
EyeFun.get_best_audio_device
EyeFun.play_wav
```
