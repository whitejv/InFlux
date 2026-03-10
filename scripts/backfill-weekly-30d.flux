import "timezone"
option location = timezone.location(name: "America/Chicago")

base = from(bucket: "MWPWater_Aggregated")
  |> range(start: -30d, stop: now())
  |> filter(fn: (r) => r._measurement == "daily")

t1 = base |> filter(fn: (r) => r._field == "total_gallons") |> aggregateWindow(every: 1w, fn: sum, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_gallons" }))
t2 = base |> filter(fn: (r) => r._field == "avg_pressure_psi") |> aggregateWindow(every: 1w, fn: mean, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_pressure_psi" }))
t3 = base |> filter(fn: (r) => r._field == "min_pressure_psi") |> aggregateWindow(every: 1w, fn: min, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_pressure_psi" }))
t4 = base |> filter(fn: (r) => r._field == "max_pressure_psi") |> aggregateWindow(every: 1w, fn: max, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_pressure_psi" }))
t5 = base |> filter(fn: (r) => r._field == "avg_gpm") |> aggregateWindow(every: 1w, fn: mean, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gpm" }))
t6 = base |> filter(fn: (r) => r._field == "min_gpm") |> aggregateWindow(every: 1w, fn: min, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_gpm" }))
t7 = base |> filter(fn: (r) => r._field == "max_gpm") |> aggregateWindow(every: 1w, fn: max, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_gpm" }))
t8 = base |> filter(fn: (r) => r._field == "avg_temperature_f") |> aggregateWindow(every: 1w, fn: mean, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_temperature_f" }))
t9 = base |> filter(fn: (r) => r._field == "avg_amperage") |> aggregateWindow(every: 1w, fn: mean, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_amperage" }))
t10 = base |> filter(fn: (r) => r._field == "total_seconds_on") |> aggregateWindow(every: 1w, fn: sum, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_seconds_on" }))
t11 = base |> filter(fn: (r) => r._field == "avg_gallons_tank") |> aggregateWindow(every: 1w, fn: mean, createEmpty: false, offset: -3d, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gallons_tank" }))

union(tables: [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11])
  |> set(key: "_measurement", value: "weekly")
  |> to(bucket: "MWPWater_Aggregated", org: "Milano")
