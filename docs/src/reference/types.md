```@meta
CollapsedDocStrings = true
```

# Core Types

Data structures and type definitions in EyeFun.jl.

## Eye Data Container

```@docs
EyeFun.EyeData
```

## Raw File Types

```@docs
EyeFun.EyeFile
EyeFun.EDFFile
EyeFun.EDFRecording
EyeFun.SMIFile
EyeFun.TobiiFile
```

## AOI Types

```@docs
EyeFun.AOI
EyeFun.RectAOI
EyeFun.CircleAOI
EyeFun.EllipseAOI
EyeFun.PolygonAOI
EyeFun.DynamicAOI
```

## Media Components

Typed media objects used with `plot_databrowser`'s `bg_stimulus` callback.

```@docs
EyeFun.AbstractEyeFunMedia
EyeFun.ImageMedia
EyeFun.AudioMedia
EyeFun.TextMedia
```
