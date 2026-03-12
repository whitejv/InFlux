// Check hourly data for Controller 1 Zone 15, last 7 days
// How many hourly points exist? What are their dates?

from(bucket: "MWPWater_Aggregated")
  |> range(start: -7d, stop: now())
  |> filter(fn: (r) => r._measurement == "hourly")
  |> filter(fn: (r) => r.Controller == "1")
  |> filter(fn: (r) => r.Zone == "15")
  |> filter(fn: (r) => r._field == "total_gallons")
  |> sort(columns: ["_time"])
  |> keep(columns: ["_time", "_value"])
