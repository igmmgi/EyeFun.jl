# AOI Metrics

```julia
using EyeFun

dat = read_et_data("experiment.edf")

face_aoi = RectAOI("Face", 200, 200, 200, 200)
house_aoi = CircleAOI("House", 500, 200, 150)

metrics = aoi_metrics(dat, [face_aoi, house_aoi])
```
