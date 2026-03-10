// Validate 9.95 GPM for Controller 3 Zone 1 (well3) – from raw data
// sum(intervalFlow) over 1 minute = GPM
// Use this if aggregated bucket has no data for C3Z1

from(bucket: "MWPWater")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "mwp_sensors")
  |> filter(fn: (r) => r.Controller == "3" and r.Zone == "1")
  |> filter(fn: (r) => r._field == "intervalFlow")
  |> aggregateWindow(every: 1m, fn: sum, createEmpty: false)
  |> map(fn: (r) => ({ r with _field: "gpm" }))
  |> sort(columns: ["_time"], desc: false)
