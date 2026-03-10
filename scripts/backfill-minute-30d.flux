import "timezone"
option location = timezone.location(name: "America/Chicago")

base = from(bucket: "MWPWater")
  |> range(start: -30d, stop: now())
  |> filter(fn: (r) => r._measurement == "mwp_sensors")

rate = base
  |> filter(fn: (r) => r._field == "intervalFlow")
  |> elapsed(unit: 1s, columnName: "elapsed")
  |> map(fn: (r) => ({
      r with
      _value: if r.elapsed > 0.0 then r._value * 60.0 / float(v: r.elapsed) else r._value * 60.0,
      _field: "gpm_rate"
  }))

t1 = base |> filter(fn: (r) => r._field == "intervalFlow") |> aggregateWindow(every: 1m, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_gallons" }))
t2 = base |> filter(fn: (r) => r._field == "pressurePSI") |> aggregateWindow(every: 1m, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_pressure_psi" }))
t3 = base |> filter(fn: (r) => r._field == "pressurePSI") |> aggregateWindow(every: 1m, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_pressure_psi" }))
t4 = base |> filter(fn: (r) => r._field == "pressurePSI") |> aggregateWindow(every: 1m, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_pressure_psi" }))
t5 = rate |> filter(fn: (r) => r._field == "gpm_rate") |> aggregateWindow(every: 1m, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gpm" }))
t6 = rate |> filter(fn: (r) => r._field == "gpm_rate") |> aggregateWindow(every: 1m, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_gpm" }))
t7 = rate |> filter(fn: (r) => r._field == "gpm_rate") |> aggregateWindow(every: 1m, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_gpm" }))
t8 = base |> filter(fn: (r) => r._field == "temperatureF") |> aggregateWindow(every: 1m, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_temperature_f" }))
t9 = base |> filter(fn: (r) => r._field == "amperage") |> aggregateWindow(every: 1m, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_amperage" }))
t10 = base |> filter(fn: (r) => r._field == "secondsOn") |> aggregateWindow(every: 1m, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_seconds_on" }))
t11 = base |> filter(fn: (r) => r._field == "gallonsTank") |> aggregateWindow(every: 1m, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gallons_tank" }))

union(tables: [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11])
  |> set(key: "_measurement", value: "minute")
  |> to(bucket: "MWPWater_Aggregated", org: "Milano")
