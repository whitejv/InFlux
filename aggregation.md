# InfluxDB Aggregation Strategy – Irrigation/Well Monitoring

**Purpose**  
Downsample 1-second high-resolution data into usable summaries for operational monitoring (daily totals as must-have) and strategic analysis (weekly/monthly/yearly).  

Data arrives every ~1 second with tags: `Controller`, `Zone`  
Fields logged:  
- `pressurePSI` (float) – pressure in PSI  
- `temperatureF` (float) – temperature in °F  
- `intervalFlow` (float) – gallons added in this ~1-second interval  
- `amperage` (float) – pump current draw  
- `secondsOn` (float/int) – seconds pump/zone was active this interval  
- `gallonsTank` (float) – current tank level in gallons  

**Measurement name**: `"log"` (based on `log_.log.` structure)

## Buckets

| Bucket Name       | Purpose                          | Retention Policy          | Notes                              |
|-------------------|----------------------------------|---------------------------|------------------------------------|
| raw               | 1-second original data           | 30–90 days                | High-resolution recent detail      |
| aggregates        | All downsampled data (1m, 1h, 1d, etc.) | Never expire (or 10+ years) | Long-term summaries, fast queries  |

## Aggregation Levels (Chained)

All stored in `aggregates` bucket, differentiated by `_measurement` value.

| Level       | Window   | Base Source   | Scheduled Every | Key Aggregations                                      | Approx. points after 2 years (per zone+controller) |
|-------------|----------|---------------|-----------------|-------------------------------------------------------|-----------------------------------------------------|
| minute      | 1 minute | raw           | 5 minutes       | sum total_gallons, min/avg/max pressure & GPM, etc.   | ~1 million                                          |
| hourly      | 1 hour   | minute        | 30 minutes      | sum total_gallons, min/avg/max pressure & GPM, etc.   | ~17,500                                             |
| daily       | 1 day    | hourly        | 2 hours         | sum total_gallons, avg/min/max pressure & GPM, etc.   | **730** (must-have)                                 |
| weekly      | 1 week   | daily         | 1 day           | sum total_gallons, avg/min/max pressure & GPM, etc.   | ~104                                                |
| monthly     | 1 month  | daily         | 1 day           | sum total_gallons, avg/min/max pressure & GPM, etc.   | ~24                                                 |

**Derived fields**:
- `total_gallons` = sum(`intervalFlow`)
- `gpm_rate` ≈ `intervalFlow * 60` (approximate gallons per minute)
- Runtime: `total_seconds_on` = sum(`secondsOn`)

## Flux Helper Function (used in all tasks)

```flux
agg = (tables=<-, field, fn, newName, window) => tables
  |> filter(fn: (r) => r._field == field)
  |> aggregateWindow(every: window, fn: fn, createEmpty: false)
  |> map(fn: (r) => ({ r with _field: newName }))

option task = {name: "1-Minute Irrigation Aggregates", every: 5m}

windowPeriod = 1m
base = from(bucket: "raw")  // ← CHANGE TO YOUR ACTUAL RAW BUCKET NAME
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "log")

// Derive approximate GPM rate
rate = base
  |> filter(fn: (r) => r._field == "intervalFlow")
  |> map(fn: (r) => ({ r with _value: r._value * 60.0, _field: "gpm_rate" }))

union(tables: [
  agg(tables: base, field: "intervalFlow",   fn: sum,  newName: "total_gallons",       window: windowPeriod),
  agg(tables: base, field: "pressurePSI",    fn: mean, newName: "avg_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "pressurePSI",    fn: min,  newName: "min_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "pressurePSI",    fn: max,  newName: "max_pressure_psi",    window: windowPeriod),
  agg(tables: rate, field: "gpm_rate",       fn: mean, newName: "avg_gpm",             window: windowPeriod),
  agg(tables: rate, field: "gpm_rate",       fn: min,  newName: "min_gpm",             window: windowPeriod),
  agg(tables: rate, field: "gpm_rate",       fn: max,  newName: "max_gpm",             window: windowPeriod),
  agg(tables: base, field: "temperatureF",   fn: mean, newName: "avg_temperature_f",   window: windowPeriod),
  agg(tables: base, field: "amperage",       fn: mean, newName: "avg_amperage",        window: windowPeriod),
  agg(tables: base, field: "secondsOn",      fn: sum,  newName: "total_seconds_on",    window: windowPeriod),
  agg(tables: base, field: "gallonsTank",    fn: mean, newName: "avg_gallons_tank",    window: windowPeriod)
])
  |> set(key: "_measurement", value: "minute")
  |> to(bucket: "aggregates")

option task = {name: "Hourly Irrigation Aggregates", every: 30m}

windowPeriod = 1h
base = from(bucket: "aggregates")
  |> range(start: -3h)
  |> filter(fn: (r) => r._measurement == "minute")

union(tables: [
  agg(tables: base, field: "total_gallons",       fn: sum,  newName: "total_gallons",       window: windowPeriod),
  agg(tables: base, field: "avg_pressure_psi",    fn: mean, newName: "avg_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "min_pressure_psi",    fn: min,  newName: "min_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "max_pressure_psi",    fn: max,  newName: "max_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "avg_gpm",             fn: mean, newName: "avg_gpm",             window: windowPeriod),
  agg(tables: base, field: "min_gpm",             fn: min,  newName: "min_gpm",             window: windowPeriod),
  agg(tables: base, field: "max_gpm",             fn: max,  newName: "max_gpm",             window: windowPeriod),
  agg(tables: base, field: "avg_temperature_f",   fn: mean, newName: "avg_temperature_f",   window: windowPeriod),
  agg(tables: base, field: "avg_amperage",        fn: mean, newName: "avg_amperage",        window: windowPeriod),
  agg(tables: base, field: "total_seconds_on",    fn: sum,  newName: "total_seconds_on",    window: windowPeriod),
  agg(tables: base, field: "avg_gallons_tank",    fn: mean, newName: "avg_gallons_tank",    window: windowPeriod)
])
  |> set(key: "_measurement", value: "hourly")
  |> to(bucket: "aggregates")

option task = {name: "Daily Irrigation Aggregates", every: 2h}

windowPeriod = 1d
base = from(bucket: "aggregates")
  |> range(start: -3d)
  |> filter(fn: (r) => r._measurement == "hourly")

union(tables: [
  agg(tables: base, field: "total_gallons",       fn: sum,  newName: "total_gallons",       window: windowPeriod),
  agg(tables: base, field: "avg_pressure_psi",    fn: mean, newName: "avg_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "min_pressure_psi",    fn: min,  newName: "min_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "max_pressure_psi",    fn: max,  newName: "max_pressure_psi",    window: windowPeriod),
  agg(tables: base, field: "avg_gpm",             fn: mean, newName: "avg_gpm",             window: windowPeriod),
  agg(tables: base, field: "min_gpm",             fn: min,  newName: "min_gpm",             window: windowPeriod),
  agg(tables: base, field: "max_gpm",             fn: max,  newName: "max_gpm",             window: windowPeriod),
  agg(tables: base, field: "avg_temperature_f",   fn: mean, newName: "avg_temperature_f",   window: windowPeriod),
  agg(tables: base, field: "avg_amperage",        fn: mean, newName: "avg_amperage",        window: windowPeriod),
  agg(tables: base, field: "total_seconds_on",    fn: sum,  newName: "total_seconds_on",    window: windowPeriod),
  agg(tables: base, field: "avg_gallons_tank",    fn: mean, newName: "avg_gallons_tank",    window: windowPeriod)
])
  |> set(key: "_measurement", value: "daily")
  |> to(bucket: "aggregates")


Weekly & Monthly Tasks
Copy the Daily task structure and adjust:

windowPeriod = 1w or 1mo
range(start: -21d) or -40d
filter(fn: (r) => r._measurement == "daily")
set(key: "_measurement", value: "weekly") or "monthly"
every: 1d

Backfilling Historical Data (2 Years)

Start with 1-minute task → test small range (-7d), then backfill in chunks (e.g., 90 days each) via Data Explorer or script.
Run hourly task on the new minute data.
Run daily task on hourly data (fastest step).

from(bucket: "aggregates")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "daily" and r._field == "total_gallons")
  |> group(columns: ["Zone"])

from(bucket: "aggregates")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "daily" and 
      (r._field == "min_pressure_psi" or r._field == "max_pressure_psi" or r._field == "max_gpm"))

Replace "raw" with your actual raw bucket name.
If intervalFlow is not gallons per ~1-second interval, adjust the * 60.0 multiplier for GPM.
Monitor server load during initial backfill — process in smaller time chunks if needed.
Use Grafana to visualize — query aggregates bucket for speed.


