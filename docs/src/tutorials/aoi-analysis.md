# AOI Analysis

```julia
using EyeFun

dat = read_et_data("data.edf")

face_aoi = RectAOI(100, 100, 200, 200)
metrics = aoi_metrics(dat, (Face=face_aoi,))
```
