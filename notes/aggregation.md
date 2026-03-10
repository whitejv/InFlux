# InfluxDB Aggregation Strategy – Irrigation/Well Monitoring

**Purpose**  
Downsample 1-second high-resolution data into usable summaries for operational monitoring (daily totals as must-have) and strategic analysis (weekly/monthly/yearly).

**Data characteristics:** Sparse—data is only written while pumps run (~6–7 hours/day total). ~22k–25k points/day instead of 86k. Sensor data has near-zero latency (read, processed, transmitted once per second).

**Core requirement:** Accurate, non-duplicated summation of water usage (and runtime) on clean hour/day/week/month/year boundaries, with no risk of the same raw `intervalFlow` or `secondsOn` being counted twice.

## Configuration

| Setting | Value |
|---------|-------|
| **Organization** | Milano |
| **Timezone** | America/Chicago |
| **Host** | http://localhost:8086 |

## Data Sources

Data arrives every ~1 second with tags: `Controller`, `Zone`, `host`, `topic`

**Measurements in MWPWater:**
- `mwp_sensors` – main sensor data (used for aggregation)
- `irrigation_sensors`
- `pump_metrics`

**Fields logged (mwp_sensors):**
- `pressurePSI` (float) – pressure in PSI
- `temperatureF` (float) – temperature in °F
- `intervalFlow` (float) – gallons added in this ~1-second interval
- `amperage` (float) – pump current draw
- `secondsOn` (float/int) – seconds pump/zone was active this interval
- `gallonsTank` (float) – current tank level in gallons

**Topic patterns:**
- `mwp/json/data/log/log/tank/` – tank data (Controller 5, Zone 0)
- `mwp/json/data/log/log/well3/` – well 3 data (Controller 3, Zone 1)
- `mwp/json/data/log/log/irrigation/` – irrigation zone data (e.g., Controller 1, Zone 13)

**Data key:** `Controller` and `Zone` are the primary keys. Do not mix data from different Controller+Zone combinations. All aggregation tasks preserve these tags—`aggregateWindow()` operates on each table independently, so each series (e.g., Controller 1 Zone 13, Controller 5 Zone 0) is aggregated separately and never combined.

## Buckets

| Bucket Name          | Purpose                          | Retention Policy          | Notes                              |
|----------------------|----------------------------------|---------------------------|------------------------------------|
| MWPWater             | 1-second original data           | 30–90 days                | High-resolution recent detail      |
| MWPWater_Aggregated  | All downsampled data (1m, 1h, 1d, etc.) | Never expire (or 10+ years) | Long-term summaries, fast queries  |

## Setting Up the MWPWater_Aggregated Bucket

The `MWPWater` bucket is created during InfluxDB initial setup. Create `MWPWater_Aggregated` manually before running aggregation tasks.

### Web UI
1. InfluxDB → **Load Data** → **Buckets**
2. **Create Bucket** → Name: `MWPWater_Aggregated`
3. **Delete Data**: Never
4. **Create**

### CLI
```bash
influx bucket create \
  --name MWPWater_Aggregated \
  --org Milano \
  --retention 0 \
  --host http://localhost:8086 \
  -t YOUR_API_TOKEN
```

## Aggregation Levels (Chained, Idempotent, Calendar-Aligned)

All stored in `MWPWater_Aggregated`, differentiated by `_measurement` value. This is the standard pattern for irrigation, energy metering, and pump/well systems in InfluxDB 2.x.

| Level   | Window   | Base From   | Run Every | Overlap Used | Purpose                          | Points after 2 years (per zone+controller) |
|---------|----------|-------------|-----------|--------------|----------------------------------|---------------------------------------------|
| minute  | 1 min    | MWPWater    | 1 min     | -2m          | Recent detail (last 24–48 h)     | ~1 M                                        |
| hourly  | 1 h      | minute      | 15 min    | -2h          | On-the-hour totals               | ~17 k                                       |
| daily   | 1 d      | hourly      | 1 h       | -2d          | Must-have daily water usage      | **730**                                     |
| weekly  | 1 w      | daily       | 6 h       | -14d         | Weekly totals (covers 3-day cycles) | ~104                                     |
| monthly | 1 mo     | daily       | 12 h      | -40d         | Monthly totals                   | ~24                                         |

*Yearly = query `aggregateWindow(every: 1y, fn: sum)` on daily or monthly—no separate task needed.*

**Why overlap is safe (idempotent upsert):** `to()` in Flux is idempotent (upsert). It replaces any point that has the exact same `_time` + tags + `_field`. Since `aggregateWindow()` always outputs the aggregated value at the start of each window, re-running a task with overlap simply overwrites the same hourly/daily total with the identical sum. No skew, no extra addition. `total_gallons` and `total_seconds_on` are never double-counted. Chaining means higher levels (daily/weekly) never touch raw data—they sum the already-correct lower-level totals (additive, zero error).

**Sparse data friendly:** Most windows outside pump runtime are simply skipped (`createEmpty: false`). Boundaries align to calendar time (top-of-hour, midnight, Monday, 1st of month).

**Pi load:** ~25k points/day—barely noticeable.

**Task setup (InfluxDB UI):** Use these exact values when creating each task:

| Task   | Task name                      | Every | Offset |
|--------|--------------------------------|-------|--------|
| Minute | 1-Minute Aggregates | 1m    | 1s     |
| Hourly | Hourly Aggregates   | 15m   | 1m     |
| Daily  | Daily Aggregates    | 1h    | 1h     |
| Weekly  | Weekly Irrigation Aggregates  | 6h    | 1h     |
| Monthly | Monthly Irrigation Aggregates | 12h   | 1h     |

**Derived fields:**
- `total_gallons` = sum(`intervalFlow`)
- `gpm_rate` = `intervalFlow * 60 / elapsed_seconds` (uses actual elapsed time between points; falls back to `intervalFlow * 60` when elapsed is 0)
- Runtime: `total_seconds_on` = sum(`secondsOn`)

## 1-Minute Aggregation Task (Working Script)

**Important:** Use `mwp_sensors` (not `log`), include `org: "Milano"` in `to()`, and use `import "timezone"` with `option location`. The helper function approach can cause "invalid flux script" errors in InfluxDB v2—use the inlined version below.

```flux
import "timezone"

option task = {
  name: "1-Minute Aggregates",
  every: 1m,
  offset: 1s,
}

option location = timezone.location(name: "America/Chicago")

base = from(bucket: "MWPWater")
  |> range(start: -2m, stop: now())
  |> filter(fn: (r) => r._measurement == "mwp_sensors")

// GPM: use actual elapsed time between points instead of fixed 60-second assumption
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
```

## Hourly Aggregation Task

**Note:** Uses `offset: 0s, timeSrc: "_start"` in `aggregateWindow` to ensure hourly boundaries (20:00, 21:00, 22:00) instead of 15-minute-aligned timestamps.

```flux
import "timezone"

option task = {
  name: "Hourly Aggregates",
  every: 15m,
  offset: 1m,
}

option location = timezone.location(name: "America/Chicago")

base = from(bucket: "MWPWater_Aggregated")
  |> range(start: -2h, stop: now())
  |> filter(fn: (r) => r._measurement == "minute")

t1 = base |> filter(fn: (r) => r._field == "total_gallons") |> aggregateWindow(every: 1h, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_gallons" }))
t2 = base |> filter(fn: (r) => r._field == "avg_pressure_psi") |> aggregateWindow(every: 1h, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_pressure_psi" }))
t3 = base |> filter(fn: (r) => r._field == "min_pressure_psi") |> aggregateWindow(every: 1h, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_pressure_psi" }))
t4 = base |> filter(fn: (r) => r._field == "max_pressure_psi") |> aggregateWindow(every: 1h, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_pressure_psi" }))
t5 = base |> filter(fn: (r) => r._field == "avg_gpm") |> aggregateWindow(every: 1h, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gpm" }))
t6 = base |> filter(fn: (r) => r._field == "min_gpm") |> aggregateWindow(every: 1h, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_gpm" }))
t7 = base |> filter(fn: (r) => r._field == "max_gpm") |> aggregateWindow(every: 1h, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_gpm" }))
t8 = base |> filter(fn: (r) => r._field == "avg_temperature_f") |> aggregateWindow(every: 1h, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_temperature_f" }))
t9 = base |> filter(fn: (r) => r._field == "avg_amperage") |> aggregateWindow(every: 1h, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_amperage" }))
t10 = base |> filter(fn: (r) => r._field == "total_seconds_on") |> aggregateWindow(every: 1h, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_seconds_on" }))
t11 = base |> filter(fn: (r) => r._field == "avg_gallons_tank") |> aggregateWindow(every: 1h, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gallons_tank" }))

union(tables: [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11])
  |> set(key: "_measurement", value: "hourly")
  |> to(bucket: "MWPWater_Aggregated", org: "Milano")
```

**Run hourly aggregation in CLI (read-only, for testing):**
```bash
cd /path/to/InFlux
./scripts/run-hourly-cli.sh
```
Or with explicit influx command (from project root):
```bash
influx query --host http://localhost:8086 --org Milano --token "YOUR_TOKEN" -f scripts/hourly-aggregate-cli.flux
```

## Daily Aggregation Task

Runs every 1h with `offset: 1h` so it runs at :01 past each hour. The -2d range ensures overlap; idempotent upsert overwrites with the identical sum—no double counting. Daily `total_gallons` is always the exact sum of the previous 24 hourly values.

```flux
import "timezone"

option task = {
  name: "Daily Aggregates",
  every: 1h,
  offset: 1h,
}

option location = timezone.location(name: "America/Chicago")

base = from(bucket: "MWPWater_Aggregated")
  |> range(start: -2d, stop: now())
  |> filter(fn: (r) => r._measurement == "hourly")

t1 = base |> filter(fn: (r) => r._field == "total_gallons") |> aggregateWindow(every: 1d, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_gallons" }))
t2 = base |> filter(fn: (r) => r._field == "avg_pressure_psi") |> aggregateWindow(every: 1d, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_pressure_psi" }))
t3 = base |> filter(fn: (r) => r._field == "min_pressure_psi") |> aggregateWindow(every: 1d, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_pressure_psi" }))
t4 = base |> filter(fn: (r) => r._field == "max_pressure_psi") |> aggregateWindow(every: 1d, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_pressure_psi" }))
t5 = base |> filter(fn: (r) => r._field == "avg_gpm") |> aggregateWindow(every: 1d, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gpm" }))
t6 = base |> filter(fn: (r) => r._field == "min_gpm") |> aggregateWindow(every: 1d, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_gpm" }))
t7 = base |> filter(fn: (r) => r._field == "max_gpm") |> aggregateWindow(every: 1d, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_gpm" }))
t8 = base |> filter(fn: (r) => r._field == "avg_temperature_f") |> aggregateWindow(every: 1d, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_temperature_f" }))
t9 = base |> filter(fn: (r) => r._field == "avg_amperage") |> aggregateWindow(every: 1d, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_amperage" }))
t10 = base |> filter(fn: (r) => r._field == "total_seconds_on") |> aggregateWindow(every: 1d, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_seconds_on" }))
t11 = base |> filter(fn: (r) => r._field == "avg_gallons_tank") |> aggregateWindow(every: 1d, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gallons_tank" }))

union(tables: [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11])
  |> set(key: "_measurement", value: "daily")
  |> to(bucket: "MWPWater_Aggregated", org: "Milano")
```

## Weekly Aggregation Task

**Note:** Uses `offset: -3d` so weeks start on Monday (Flux default is Thursday).

```flux
import "timezone"

option task = {
  name: "Weekly Irrigation Aggregates",
  every: 6h,
  offset: 1h,
}

option location = timezone.location(name: "America/Chicago")

base = from(bucket: "MWPWater_Aggregated")
  |> range(start: -14d, stop: now())
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
```

## Monthly Aggregation Task

```flux
import "timezone"

option task = {
  name: "Monthly Irrigation Aggregates",
  every: 12h,
  offset: 1h,
}

option location = timezone.location(name: "America/Chicago")

base = from(bucket: "MWPWater_Aggregated")
  |> range(start: -40d, stop: now())
  |> filter(fn: (r) => r._measurement == "daily")

t1 = base |> filter(fn: (r) => r._field == "total_gallons") |> aggregateWindow(every: 1mo, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_gallons" }))
t2 = base |> filter(fn: (r) => r._field == "avg_pressure_psi") |> aggregateWindow(every: 1mo, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_pressure_psi" }))
t3 = base |> filter(fn: (r) => r._field == "min_pressure_psi") |> aggregateWindow(every: 1mo, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_pressure_psi" }))
t4 = base |> filter(fn: (r) => r._field == "max_pressure_psi") |> aggregateWindow(every: 1mo, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_pressure_psi" }))
t5 = base |> filter(fn: (r) => r._field == "avg_gpm") |> aggregateWindow(every: 1mo, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gpm" }))
t6 = base |> filter(fn: (r) => r._field == "min_gpm") |> aggregateWindow(every: 1mo, fn: min, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "min_gpm" }))
t7 = base |> filter(fn: (r) => r._field == "max_gpm") |> aggregateWindow(every: 1mo, fn: max, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "max_gpm" }))
t8 = base |> filter(fn: (r) => r._field == "avg_temperature_f") |> aggregateWindow(every: 1mo, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_temperature_f" }))
t9 = base |> filter(fn: (r) => r._field == "avg_amperage") |> aggregateWindow(every: 1mo, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_amperage" }))
t10 = base |> filter(fn: (r) => r._field == "total_seconds_on") |> aggregateWindow(every: 1mo, fn: sum, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "total_seconds_on" }))
t11 = base |> filter(fn: (r) => r._field == "avg_gallons_tank") |> aggregateWindow(every: 1mo, fn: mean, createEmpty: false, offset: 0s, timeSrc: "_start") |> map(fn: (r) => ({ r with _field: "avg_gallons_tank" }))

union(tables: [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11])
  |> set(key: "_measurement", value: "monthly")
  |> to(bucket: "MWPWater_Aggregated", org: "Milano")
```

## Why This Is 100% Safe for Summation Fields

- **Controller+Zone preserved:** Each series (e.g., Controller 1 Zone 13, Controller 5 Zone 0) is aggregated independently. Flux's `aggregateWindow()` operates on each table separately—data from different Controller/Zone combinations is never mixed.
- The daily `total_gallons` is always the exact sum of the previous 24 hourly `total_gallons` values for that same Controller+Zone.
- If a task runs again 30 minutes later, it recalculates the exact same daily total and overwrites the point at midnight—no addition, no skew.
- Same for `total_seconds_on`.
- Your two summation fields are never double-counted.

## Influx CLI Commands

Use these to verify raw and aggregated data. Replace the token if rotating for security.

**Check raw data (MWPWater):**
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  'from(bucket: "MWPWater") |> range(start: -24h) |> limit(n: 10)'
```

**Check aggregated data (MWPWater_Aggregated):**
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  'from(bucket: "MWPWater_Aggregated") |> range(start: -24h) |> filter(fn: (r) => r._measurement == "minute") |> limit(n: 10)'
```

**List measurements in MWPWater:**
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  'import "influxdata/influxdb/schema"
   schema.measurements(bucket: "MWPWater")'
```

**List field keys in MWPWater:**
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  'import "influxdata/influxdb/schema"
   schema.fieldKeys(bucket: "MWPWater", start: -24h)'
```

**Check raw data for Controller 3 Zone 1 – well3 (GPM validation):**
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  'from(bucket: "MWPWater") |> range(start: -24h) |> filter(fn: (r) => r._measurement == "mwp_sensors" and r.Controller == "3" and r.Zone == "1") |> limit(n: 20)'
```

**Query total gallons by zone (last 24h):**
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  'from(bucket: "MWPWater_Aggregated") |> range(start: -24h) |> filter(fn: (r) => r._measurement == "minute" and r._field == "total_gallons")'
```

## Backfill: Clean MWPWater_Aggregated and Reaggregate (Last 30 Days)

Run these on the Raspberry Pi (where InfluxDB and the influx CLI are installed) via SSH. Replace `~/InFlux` with your project path on the Pi.

**1. Delete all data from the aggregate bucket:**
```bash
influx delete \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  --bucket MWPWater_Aggregated \
  --start 1970-01-01T00:00:00Z \
  --stop 2030-01-01T00:00:00Z
```

**2. Rerun all aggregation tasks on the last 30 days** (run in order; each level depends on the previous):
```bash
cd ~/InFlux

influx query --org Milano --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" -f scripts/backfill-minute-30d.flux

influx query --org Milano --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" -f scripts/backfill-hourly-30d.flux

influx query --org Milano --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" -f scripts/backfill-daily-30d.flux

influx query --org Milano --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" -f scripts/backfill-weekly-30d.flux

influx query --org Milano --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" -f scripts/backfill-monthly-30d.flux
```

Or as a one-liner:
```bash
cd ~/InFlux && for f in scripts/backfill-minute-30d.flux scripts/backfill-hourly-30d.flux scripts/backfill-daily-30d.flux scripts/backfill-weekly-30d.flux scripts/backfill-monthly-30d.flux; do influx query --org Milano --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" -f "$f"; done
```

## Backfilling Historical Data (General)

Run the 1-minute task in Data Explorer with `range(start: -2y)` (chunked if needed—e.g., 90 days at a time). Then run hourly → daily in order. Because of upsert, you can safely re-run any of them later. No risk of duplication.

## GPM Validation (Controller 3 Zone 1 – well3)

**Purpose:** Validate instrumentation against an external measurement source (expected **9.95 GPM**).

**Target:** Controller 3, Zone 1 (`mwp/json/data/log/log/well3/`).

**Formula:** `sum(intervalFlow)` over 1 minute = GPM. Do **not** use `gallonsTank` (different sensor—tank level).

**Expected:** When the pump runs for a full minute, `total_gallons` (or raw sum) ≈ **9.95**.

**From aggregated bucket:**
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  -f scripts/validate-gpm-c3z1.flux
```

**From raw bucket** (if aggregated has no C3Z1 data):
```bash
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  -f scripts/validate-gpm-c3z1-raw.flux
```

**Interpretation:** If values cluster near 9.95 when the pump runs, the instrumentation matches. If not, check raw `intervalFlow` units or Controller/Zone mapping.

## Grafana Table (Phone-App Style)

Replicate the MWP Log table: one row per Zone for the selected Controller, with columns Zone | Gallons | Min | PSI | GPM.

### 1. Dashboard Variables

**Dashboard settings → Variables → Add variable**

| Name | Label | Type | Custom options |
|------|-------|------|----------------|
| controller | Controller | Custom | `0 : 0, 1 : 1, 2 : 2, 3 : 3, 4 : 4, 5 : 5` |
| aggregation | Aggregation | Custom | `minute : minute, hour : hourly, daily : daily, weekly : weekly, monthly : monthly` |

### 2. Panel: Table

**Add visualization → Table** → Select InfluxDB data source.

### 3. Flux Query

```flux
base = from(bucket: "MWPWater_Aggregated")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "${aggregation}")
  |> filter(fn: (r) => r.Controller == "${controller}")
  |> filter(fn: (r) =>
    r._field == "total_gallons" or
    r._field == "total_seconds_on" or
    r._field == "avg_pressure_psi" or
    r._field == "avg_gpm"
  )

// Sum over time range (e.g., 24h of hourly data → one row per zone)
sumFields = base
  |> filter(fn: (r) => r._field == "total_gallons" or r._field == "total_seconds_on")
  |> group(columns: ["Zone", "_field"])
  |> sum()

meanFields = base
  |> filter(fn: (r) => r._field == "avg_pressure_psi" or r._field == "avg_gpm")
  |> group(columns: ["Zone", "_field"])
  |> mean()

union(tables: [sumFields, meanFields])
  |> pivot(rowKey: ["Zone"], columnKey: ["_field"], valueColumn: "_value")
  |> map(fn: (r) => ({
      r with
      Gallons: r.total_gallons,
      Min: r.total_seconds_on / 60.0,
      PSI: r.avg_pressure_psi,
      GPM: r.avg_gpm
  }))
  |> keep(columns: ["Zone", "Gallons", "Min", "PSI", "GPM"])
  |> sort(columns: ["Zone"])
```

### 4. Time Range

Use the dashboard time picker (top right). For a 24h log window like the phone app, select **Last 24 hours**.

### 5. Result

| Zone | Gallons | Min | PSI | GPM |
|------|---------|-----|-----|-----|
| 0 | 0 | 0 | 0 | 0 |
| 1 | 0 | 0 | 0 | 0 |
| 2 | 20.9 | 0.7 | 26.4 | ... |
| ... | ... | ... | ... | ... |

Only zones with data appear. For zones with no data in the range, add a Grafana **Transform → Add field from calculation** or use a Flux `array.from()` + `join` to fill zeros—more complex; start with zones-that-have-data.

### 6. Column Formatting (Optional)

In panel options → **Overrides**:
- Gallons: Unit → `gallons`, Decimals → 1
- Min: Unit → `none`, Decimals → 1, Suffix → `min`
- PSI: Unit → `pressure` (psi), Decimals → 1
- GPM: Unit → `none`, Decimals → 1, Suffix → `gal`

## Notes

- **total_seconds_on anomaly:** The first minute after a gap may show an anomalously high value (e.g., 6700+ seconds) if `secondsOn` is cumulative in the source. Subsequent minutes typically show normal per-minute runtime (0–60 seconds).
- If `intervalFlow` is not gallons per ~1-second interval, adjust the GPM formula in the 1-minute task (elapsed-based calculation).
- Monitor server load during initial backfill—process in smaller time chunks if needed.
- Use Grafana to visualize—query `MWPWater_Aggregated` for speed.
- **Security:** Rotate the API token if this file is shared or committed to version control.
- **Production-grade:** Clean, trustworthy hourly/daily/weekly/monthly/yearly water-usage totals with zero risk of duplication, even if tasks overlap or you restart them.
