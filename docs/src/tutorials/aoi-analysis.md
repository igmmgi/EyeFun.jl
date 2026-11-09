# AOI Analysis

```julia
using EyeFun

dat = read_et_data("data.edf")

face_aoi = RectAOI("Face", 200, 200, 200, 200)
metrics = aoi_metrics(dat, [face_aoi])
```
