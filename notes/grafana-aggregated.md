# Grafana Dashboards – Aggregated Water Data

**Purpose**  
Visualize water usage and sensor data from the `MWPWater_Aggregated` bucket. For InfluxDB aggregation tasks, bucket setup, and backfill, see [influxdb-aggregation.md](influxdb-aggregation.md).

**Data source:** InfluxDB with Flux. Query `MWPWater_Aggregated` for fast results (minute, hourly, daily, weekly, monthly measurements).

## Dashboard Variables

Create these variables for all panels. **Dashboard settings → Variables → Add variable**

| Name | Label | Type | Custom options |
|------|-------|------|----------------|
| controller | Controller | Custom | `0 : 0, 1 : 1, 2 : 2, 3 : 3, 4 : 4, 5 : 5` |
| aggregation | Aggregation | Custom | `minute : minute, hour : hourly, daily : daily, weekly : weekly, monthly : monthly` |

## Table: Zone Summary (Phone-App Style)

Replicate the MWP Log table: one row per Zone for the selected Controller, with columns Zone | Gallons | Min | PSI | GPM.

**Important:** Do **not** add a Zone variable to the dashboard for this panel. The table shows all zones at once. Remove any Zone variable if it causes a per-zone dropdown.

### Panel: Table

**Add visualization → Table** → Select InfluxDB data source.

### Flux Query

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
      GPM: r.avg_gpm,
      _zoneNum: int(v: r.Zone)
  }))
  |> keep(columns: ["Zone", "Gallons", "Min", "PSI", "GPM", "_zoneNum"])
  |> group()
  |> sort(columns: ["_zoneNum"])
  |> drop(columns: ["_zoneNum"])
```

**Critical:** `|> group()` merges the stream of tables (one per zone) into a single table. Without it, Grafana shows a dropdown to pick one zone at a time. **Sort after group** so zones appear in numerical order (0, 1, 2, … 16).

### Time Range

Use the dashboard time picker (top right). For a 24h log window like the phone app, select **Last 24 hours**.

**Note:** For "Last 7 days", the first day's midnight (Chicago) can fall just outside the range, so one day's daily data may be excluded. Use **Last 8 days** if you need a full week of daily totals to match your app.

### Result

| Zone | Gallons | Min | PSI | GPM |
|------|---------|-----|-----|-----|
| 0 | 0 | 0 | 0 | 0 |
| 1 | 0 | 0 | 0 | 0 |
| 2 | 20.9 | 0.7 | 26.4 | ... |
| ... | ... | ... | ... | ... |

Only zones with data appear. For zones with no data in the range, add a Grafana **Transform → Add field from calculation** or use a Flux `array.from()` + `join` to fill zeros—more complex; start with zones-that-have-data.

### Column Order and Formatting

**Column order (Zone first):** In the panel editor, go to **Transform** tab → **Add transformation** → **Organize fields**. Drag and drop to put `Zone` first, then `Gallons`, `Min`, `PSI`, `GPM`.

**Overrides:**
- Gallons: Unit → `gallons`, Decimals → 1
- Min: Unit → `none`, Decimals → 1, Suffix → `min`
- PSI: Unit → `pressure` (psi), Decimals → 1
- GPM: Unit → `none`, Decimals → 1, Suffix → `gal`

## Bar Chart: Gallons by Zone

Vertical bar chart: zones on the x-axis, total gallons on the y-axis for the selected controller and time range.

### Panel: Bar Chart

**Add visualization → Bar chart** → Select InfluxDB data source.

### Flux Query

```flux
from(bucket: "MWPWater_Aggregated")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "${aggregation}")
  |> filter(fn: (r) => r.Controller == "${controller}")
  |> filter(fn: (r) => r._field == "total_gallons")
  |> group(columns: ["Zone"])
  |> sum()
  |> map(fn: (r) => ({ r with _zoneNum: int(v: r.Zone) }))
  |> sort(columns: ["_zoneNum"])
```

### Panel Configuration

**Try first without Transform:** The Flux query returns one series per zone. The Bar chart may show them as grouped bars at a single time point—each zone a different color in the legend. If that looks good, you're done.

**If you need Zone labels on the x-axis:** In the panel editor, look at the **bottom pane** (below the chart preview). Next to the **Query** tab there should be a **Transform** tab (sometimes labeled **Transform data**). Click it, then **Add transformation** → **Series to rows**. That turns each zone into a row so Zone can be used as the x-axis category.

- **X-axis:** Field containing Zone (e.g. `Zone` or `name` after transform).
- **Y-axis:** `_value` (gallons).
- **Orientation:** Vertical.
- **Format:** Override `_value` → Unit: `gallons`, Decimals: 1.

### Result

One vertical bar per zone (0, 1, 2, …) with height = total gallons in the selected time range. Zones with no data won't appear unless you add a zero-fill step in Flux.

## Time Series: Well GPM (Controller 3 Zone 1)

Monitor well output (C3Z1) with avg, min, and max GPM over time. Use the dashboard time picker for different spans (Last 24h, 7d, 30d, etc.) and the aggregation variable for resolution.

### Panel: Time Series

**Add visualization → Time series** → Select InfluxDB data source.

### Flux Queries

**Query A – Aggregated (avg, min, max):**
```flux
from(bucket: "MWPWater_Aggregated")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "${aggregation}")
  |> filter(fn: (r) => r.Controller == "3")
  |> filter(fn: (r) => r.Zone == "1")
  |> filter(fn: (r) => r._field == "avg_gpm" or r._field == "min_gpm" or r._field == "max_gpm")
  |> yield(name: "aggregated")
```

**Query B – Raw GPM (1‑min from MWPWater):**
```flux
from(bucket: "MWPWater")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mwp_sensors")
  |> filter(fn: (r) => r.Controller == "3" and r.Zone == "1")
  |> filter(fn: (r) => r._field == "intervalFlow")
  |> aggregateWindow(every: 1m, fn: sum, createEmpty: false)
  |> map(fn: (r) => ({ r with _field: "raw_gpm" }))
  |> yield(name: "raw")
```

Raw GPM = sum(intervalFlow) per minute (gallons per minute). Always 1‑min resolution; overlays with aggregated series for comparison.

### Panel Configuration

- **Title:** e.g. "Well 3 GPM (C3Z1)"
- **Legend:** Show series names (avg_gpm, min_gpm, max_gpm, raw_gpm)
- **Overrides:** `_value` → Unit: `none`, Decimals: 1, Suffix: ` gal/min`
- **Stacking:** None (lines overlay for comparison)
- **Thresholds (optional):** Add a reference line at 9.95 GPM (expected output) to spot degradation

### Aggregation by Time Span

| Time span | Aggregation | Use |
|-----------|-------------|-----|
| Last 24–48h | minute | High-resolution, pump cycles |
| Last 7 days | hourly | Daily patterns, short-term trends |
| Last 30 days | daily | Weekly/monthly trends |
| Months | daily or weekly | Long-term degradation |

Use the dashboard **aggregation** variable to switch resolution. Raw GPM is always 1‑min; when viewing hourly/daily, it appears as a finer line for comparison. For true 1‑second detail (last few hours only), you’d need a separate raw query without `aggregateWindow`—heavier.
