# AOI Metrics

```julia
using EyeFun

dat = read_et_data("experiment.edf")

face_aoi = RectAOI(100, 100, 200, 200)
house_aoi = CircleAOI(500, 100, 150)

metrics = aoi_metrics(dat, (Face=face_aoi, House=house_aoi))
```
