// Validate 9.95 GPM for Controller 3 Zone 1 (well3)
// sum(intervalFlow) over 1 minute = GPM (gallons per minute)
// Expected: ~9.95 when pump runs

from(bucket: "MWPWater_Aggregated")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "minute")
  |> filter(fn: (r) => r.Controller == "3" and r.Zone == "1")
  |> filter(fn: (r) => r._field == "total_gallons")
  |> sort(columns: ["_time"], desc: false)
