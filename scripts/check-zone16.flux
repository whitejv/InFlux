// Check if Zone 16 exists in raw and aggregated (Controller 1), last 30 days

raw = from(bucket: "MWPWater")
  |> range(start: -30d, stop: now())
  |> filter(fn: (r) => r._measurement == "mwp_sensors")
  |> filter(fn: (r) => r.Controller == "1")
  |> filter(fn: (r) => r.Zone == "16")
  |> filter(fn: (r) => r._field == "intervalFlow")
  |> sum()
  |> map(fn: (r) => ({ r with _field: "raw_gallons", source: "MWPWater" }))

agg = from(bucket: "MWPWater_Aggregated")
  |> range(start: -30d, stop: now())
  |> filter(fn: (r) => r._measurement == "daily")
  |> filter(fn: (r) => r.Controller == "1")
  |> filter(fn: (r) => r.Zone == "16")
  |> filter(fn: (r) => r._field == "total_gallons")
  |> sum()
  |> map(fn: (r) => ({ r with _field: "daily_gallons", source: "MWPWater_Aggregated" }))

union(tables: [raw, agg])
