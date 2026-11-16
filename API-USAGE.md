# API Usage Guide

How to call the route optimization API from your own application. This guide is
written for an integrator: endpoints, request/response formats, working examples
in several languages, and the map-rendering workflow.

> **The full field-by-field reference is in [`API.md`](API.md).** This guide is
> the "how do I actually use it" walkthrough.

---

## 1. The two services

| Service | Base URL | What it does |
|---------|----------|--------------|
| **VROOM** | `http://192.168.6.242:3080` | Optimizes the visit order (VRP) |
| **OSRM** | `http://192.168.6.242:5000` | Point-to-point routing + matrices |

**Coordinate order everywhere is `[lon, lat]`** (longitude first). This is the
#1 mistake — `[lat, lon]` routes across the ocean.

**Rule of thumb:**
- One vehicle, one destination → call **OSRM** `/route` directly.
- Multiple stops that need reordering, or multiple vehicles → call **VROOM**.

---

## 2. VROOM — optimize a set of deliveries

`POST http://192.168.6.242:3080/` · Content-Type: `application/json`

**Limits:** max payload 1 MB · max 1000 locations · max 200 vehicles · timeout 300 s.

### Request shape
```json
{
  "vehicles": [
    { "id": 1, "start": [106.8456, -6.2088], "end": [106.8456, -6.2088], "capacity": [100] }
  ],
  "jobs": [
    { "id": 1, "location": [106.8217, -6.1853], "delivery": [30], "service": 120 },
    { "id": 2, "location": [106.8555, -6.1975], "delivery": [50], "service": 120 },
    { "id": 3, "location": [106.8427, -6.1690], "delivery": [20], "service": 120 }
  ]
}
```

**The integration mistakes that actually happen:**
- **IDs must be integers.** `"id": "van-1"` fails with `Invalid or missing id for vehicle.`
- **Coordinates are `[lon, lat]`.**
- The endpoint is `POST /` (root), **not** `/api/v1/optimization`.
- With `location`/`start`/`end` coordinates, VROOM asks OSRM for real travel
  times automatically — no `matrices` block needed.
- `capacity` must be ≥ the sum of `delivery`, or jobs come back `unassigned`.

### Response (abridged)
```json
{
  "code": 0,
  "summary": { "cost": 1389, "routes": 1, "unassigned": 0 },
  "routes": [
    { "vehicle": 1,
      "steps": [
        { "type": "start", "location": [106.8456, -6.2088], "arrival": 0 },
        { "type": "job", "id": 2, "location": [106.8555, -6.1975], "arrival": 182 },
        { "type": "job", "id": 3, "location": [106.8427, -6.1690], "arrival": 646 },
        { "type": "job", "id": 1, "location": [106.8217, -6.1853], "arrival": 1274 },
        { "type": "end", "location": [106.8456, -6.2088], "arrival": 1749 }
      ] }
  ],
  "unassigned": []
}
```

**Read these:**
- `code` — `0` success · `2` bad request (see `error`) · `3` timeout. **Check this first.**
- `routes[].steps[]` — the optimized visit order. `type` is
  `start`/`job`/`pickup`/`delivery`/`break`/`end`; `arrival` is seconds from start.
- `summary.cost` — total seconds. `summary.unassigned` — count of unassigned jobs.

### Multi-vehicle example
```json
{
  "vehicles": [
    { "id": 1, "start": [106.8456, -6.2088], "end": [106.8456, -6.2088], "capacity": [200] },
    { "id": 2, "start": [106.8456, -6.2088], "end": [106.8456, -6.2088], "capacity": [200] }
  ],
  "jobs": [
    { "id": 1, "location": [106.8217, -6.1853], "delivery": [40], "service": 120 },
    { "id": 2, "location": [106.8555, -6.1975], "delivery": [60], "service": 120 },
    { "id": 3, "location": [106.8427, -6.1690], "delivery": [30], "service": 120 },
    { "id": 4, "location": [106.8063, -6.2573], "delivery": [50], "service": 120 },
    { "id": 5, "location": [106.8750, -6.2000], "delivery": [45], "service": 120 },
    { "id": 6, "location": [106.8100, -6.1900], "delivery": [25], "service": 120 }
  ]
}
```
→ returns 2 routes; VROOM splits the 6 jobs across both vans.

### Pickup-and-delivery (shipments)
```json
{
  "vehicles": [
    { "id": 1, "start": [106.8456, -6.2088], "end": [106.8456, -6.2088], "capacity": [10] }
  ],
  "shipments": [
    {
      "amount": [1],
      "pickup":   { "id": 10, "location": [106.8217, -6.1853], "service": 120 },
      "delivery": { "id": 11, "location": [106.8555, -6.1975], "service": 120 }
    }
  ]
}
```
→ steps come back as `start` → `pickup` → `delivery` → `end`.

---

## 3. OSRM — point-to-point routing

Base: `http://192.168.6.242:5000`. URL coordinates are `lon,lat`.

> OSRM has **no `/health` endpoint**. Probe with a `/route` call; `code: "Ok"`
> means it's up.

| Endpoint | Purpose |
|----------|---------|
| `GET /route/v1/car/{coords}` | Fastest car route (+ geometry, alternatives, steps) |
| `GET /table/v1/car/{coords}` | N×N distance/duration matrix (up to 1000 coords) |
| `GET /nearest/v1/car/{coord}` | Nearest routable nodes |
| `POST /match/v1/car` | Map-match a GPS trace |

### Fastest route
```bash
curl "http://192.168.6.242:5000/route/v1/car/106.8456,-6.2088;106.8063,-6.2573?overview=full&geometries=geojson"
```
```json
{
  "code": "Ok",
  "routes": [
    {
      "distance": 10680.8,
      "duration": 726.9,
      "geometry": { "type": "LineString", "coordinates": [[106.8456, -6.2088], [ ... ]] }
    }
  ]
}
```
`distance` is meters, `duration` is seconds, `geometry.coordinates` is the
`[lon, lat]` polyline.

**Query params:** `overview` (`false`/`simplified`/`full`), `geometries`
(`geojson`/`polyline`/`poly6`/`poly5`/`poly4`), `alternatives` (`true`/`false`),
`steps` (`true`/`false`), `annotations` (`distance`, `duration`, `speed`, …).

### Distance matrix
```bash
curl "http://192.168.6.242:5000/table/v1/car/106.8456,-6.2088;106.8217,-6.1853;106.8555,-6.1975?annotations=duration,distance"
```
```json
{
  "code": "Ok",
  "durations": [[0, 182, 532], [182, 0, 350], [532, 350, 0]],
  "distances": [[0, 2600, 6500], [2600, 0, 3900], [6500, 3900, 0]]
}
```
Row `i`, column `j` = from coordinate `i` to coordinate `j`.

---

## 4. Working examples

### cURL (VROOM)
```bash
curl "http://192.168.6.242:3080/" -X POST -H "Content-Type: application/json" -d '{
  "vehicles":[{"id":1,"start":[106.8456,-6.2088],"end":[106.8456,-6.2088],"capacity":[100]}],
  "jobs":[
    {"id":1,"location":[106.8217,-6.1853],"delivery":[30],"service":120},
    {"id":2,"location":[106.8555,-6.1975],"delivery":[50],"service":120}
  ]
}'
```

### JavaScript (browser / Node 18+)
```js
const VROOM = "http://192.168.6.242:3080";
const OSRM  = "http://192.168.6.242:5000";

async function optimize(start, end, capacity, service, stops) {
  const body = {
    vehicles: [{ id: 1, start, end, capacity: [capacity] }],
    jobs: stops.map((loc, i) => ({ id: i + 1, location: loc, delivery: [1], service }))
  };
  const res = await fetch(VROOM + "/", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  const d = await res.json();
  if (d.code !== 0) throw new Error(d.error || ("VROOM error " + d.code));
  return d; // d.routes[0].steps[] is the optimized order
}

// Example:
// const result = await optimize(
//   [106.8456, -6.2088], [106.8456, -6.2088], 1000, 120,
//   [[106.8217, -6.1853], [106.8555, -6.1975], [106.8427, -6.1690]]
// );
```

### Python
```python
import requests

VROOM = "http://192.168.6.242:3080"
OSRM  = "http://192.168.6.242:5000"

def optimize(start, end, capacity, service, stops):
    body = {
        "vehicles": [{"id": 1, "start": start, "end": end, "capacity": [capacity]}],
        "jobs": [{"id": i + 1, "location": loc, "delivery": [1], "service": service}
                 for i, loc in enumerate(stops)]
    }
    r = requests.post(VROOM + "/", json=body, timeout=60)
    d = r.json()
    if d["code"] != 0:
        raise RuntimeError(d.get("error", f"VROOM error {d['code']}"))
    return d  # d["routes"][0]["steps"] is the optimized order

# Fastest route:
def route(a, b):
    url = f"{OSRM}/route/v1/car/{a[0]},{a[1]};{b[0]},{b[1]}?overview=full&geometries=geojson"
    return requests.get(url, timeout=30).json()
```

### Go
```go
package main

import (
	"bytes"
	"encoding/json"
	"net/http"
)

const (
	vroom = "http://192.168.6.242:3080"
	osrm  = "http://192.168.6.242:5000"
)

type job struct {
	ID       int     `json:"id"`
	Location [2]float64 `json:"location"`
	Delivery []int   `json:"delivery"`
	Service  int     `json:"service"`
}
type vehicle struct {
	ID       int     `json:"id"`
	Start    [2]float64 `json:"start"`
	End      [2]float64 `json:"end"`
	Capacity []int   `json:"capacity"`
}
type req struct {
	Vehicles []vehicle `json:"vehicles"`
	Jobs     []job     `json:"jobs"`
}

func optimize(start, end [2]float64, capacity, service int, stops [][2]float64) (map[string]any, error) {
	body := req{
		Vehicles: []vehicle{{1, start, end, []int{capacity}}},
		Jobs:     []job{},
	}
	for i, loc := range stops {
		body.Jobs = append(body.Jobs, job{i + 1, loc, []int{1}, service})
	}
	b, _ := json.Marshal(body)
	resp, err := http.Post(vroom+"/", "application/json", bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var d map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&d); err != nil {
		return nil, err
	}
	if code, _ := d["code"].(float64); code != 0 {
		return nil, &VroomError{d}
	}
	return d, nil
}
```

---

## 5. Displaying the map with the route

**The API does not stitch or render.** VROOM returns the optimized *order*
(no geometry); OSRM returns the *road geometry for one leg* only. **Both the
leg-stitching and the map rendering happen on the frontend (your client).**

### The 4-step workflow
1. **Get the order** — `POST /` to VROOM; collect `routes[0].steps[].location`
   (`[lon, lat]`) in order (start → stops → end).
2. **Fetch road geometry per leg** — for each consecutive pair, call OSRM
   `GET /route/v1/car/{lon},{lat};{lon},{lat}?overview=full&geometries=geojson`
   and read `routes[0].geometry.coordinates`.
3. **Stitch the legs** — concatenate the polylines; after the first leg, `shift()`
   off the first point of each leg (it duplicates the shared node). Fall back to
   a straight line for any leg that fails.
4. **Render** — plot the stitched polyline + a marker per point. **Swap
   `[lon, lat]` → `[lat, lon]`** for Leaflet.

### Minimal Leaflet + OpenStreetMap (no API key)
```html
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<div id="map" style="height:420px"></div>
<script>
const map = L.map('map').setView([-6.2, 106.84], 12);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19, attribution: '&copy; OpenStreetMap contributors'
}).addTo(map);

async function drawRoute(order, osrmBase) {
  const full = [];
  for (let i = 0; i < order.length - 1; i++) {
    const [a, b] = [order[i], order[i + 1]];
    const url = `${osrmBase}/route/v1/car/${a[0]},${a[1]};${b[0]},${b[1]}?overview=full&geometries=geojson`;
    const j = await (await fetch(url)).json();
    if (j.code === 'Ok' && j.routes[0].geometry) {
      const coords = j.routes[0].geometry.coordinates;
      if (i > 0) coords.shift();          // drop the duplicated shared node
      full.push(...coords);
    } else {
      if (i > 0) full.push(a);            // fallback: straight line
      full.push(b);
    }
  }
  L.polyline(full.map(c => [c[1], c[0]]), { color: '#4f8cff', weight: 4 }).addTo(map);
  order.forEach((p, i) => {
    L.circleMarker([p[1], p[0]], { radius: 8, color: i === 0 ? '#4f8cff' : i === order.length - 1 ? '#34d17b' : '#ffb347', fillOpacity: 1 }).addTo(map);
  });
  map.fitBounds(L.latLngBounds(order.map(p => [p[1], p[0]])), { padding: [40, 40] });
}
</script>
```

**Gotchas:**
- `[lon, lat]` → `[lat, lon]` for Leaflet.
- N stops = N−1 OSRM calls (one per leg). Batch or cache for many vehicles.
- OSM tiles need no key; for high volume use a keyed tile provider (only the
  tile URL changes).
- **Complete runnable example:** [`frontend-map-example.html`](frontend-map-example.html)
  (open it and it works end-to-end). Full UI: [`route-optimizer.html`](route-optimizer.html).

---

## 6. Quick error reference

| Service | Success | Failure signals |
|---------|---------|-----------------|
| VROOM | `code: 0` | `code: 2` (bad request, see `error`), `code: 3` (timeout) |
| OSRM | `code: "Ok"` | `code: "NoRoute"`, `code: "NotFound"`, `code: "InvalidNv"` |

**Always check the success field before reading the result.**
