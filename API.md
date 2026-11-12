# API Reference

Complete reference for the two services. Both are served from the LXC
(`192.168.6.242`). For a quick start and the common pitfalls, see the
[README §4](README.md#4-api-usage).

| Service | Base URL |
|---------|----------|
| VROOM (optimization) | `http://192.168.6.242:3080` |
| OSRM (routing) | `http://192.168.6.242:5000` |

**Coordinate order everywhere is `[lon, lat]`** (longitude first).

---

## 1. VROOM — vehicle routing optimization

`POST /` (root). Content-Type: `application/json`.

**Limits:** max payload 1 MB · max 1000 locations · max 200 vehicles · timeout 300 s.

### Request

```json
{
  "vehicles":  [ /* vehicle objects */ ],
  "jobs":      [ /* job objects */ ],
  "shipments": [ /* shipment objects (optional) */ ],
  "matrices":  { /* optional, only if you omit coordinates */ }
}
```

#### `vehicles[]`

| Field | Type | Required | Notes |
|-------|------|:--------:|-------|
| `id` | int | ✅ | **Must be an integer** (not a string). |
| `start` | `[lon, lat]` | ✅* | Departure. *Omit only if using `start_index` with a custom matrix. |
| `end` | `[lon, lat]` | ✅* | Return point. Same as `start` for a round trip. |
| `capacity` | `[int]` | — | Max load per dimension. Must be ≥ sum of `delivery` for the jobs it serves. |
| `profile` | string | — | Routing profile. Defaults to `car`. |
| `time_window` | `[unix, unix]` | — | Working hours (epoch seconds). |
| `breaks` | `[break]` | — | Driver breaks. |
| `skills` | `[int]` | — | Skills the vehicle has; jobs/shipments require a match. |

#### `jobs[]`

| Field | Type | Required | Notes |
|-------|------|:--------:|-------|
| `id` | int | ✅ | **Must be an integer.** |
| `location` | `[lon, lat]` | ✅* | The stop. *Omit only if using `location_index` with a custom matrix. |
| `delivery` | `[int]` | — | Units delivered here (per dimension). |
| `pickup` | `[int]` | — | Units picked up here (per dimension). |
| `service` | int | — | Service time at the stop, seconds. |
| `setup` | int | — | Setup time before service, seconds. |
| `time_windows` | `[[unix, unix]]` | — | Allowed service windows. |
| `skills` | `[int]` | — | Skills required to serve this job. |
| `priority` | int | — | 0–100; higher served first if capacity is tight. |

#### `shipments[]` (pickup-and-delivery pair, same route)

```json
{
  "amount": [1],
  "skills": [1],
  "pickup":   { "id": 10, "location": [106.81, -6.20], "service": 120 },
  "delivery": { "id": 11, "location": [106.85, -6.19], "service": 120 }
}
```

#### `matrices` (only if you omit coordinates)

```json
{ "car": { "durations": [[0, 182, 532], [182, 0, 350], [532, 350, 0]] } }
```
Use `start_index`/`end_index`/`location_index` to refer into the matrix. When you
provide real coordinates instead, VROOM fetches the matrix from OSRM
automatically — you don't need this.

### Examples

**Single vehicle, 3 jobs:**
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

**Two vehicles, 6 jobs:**
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

### Response

```json
{
  "code": 0,
  "summary": {
    "cost": 1389, "routes": 1, "unassigned": 0,
    "delivery": [100], "amount": [100], "pickup": [0],
    "setup": 0, "service": 360, "duration": 1389, "waiting_time": 0,
    "priority": 0, "violations": [],
    "computing_times": { "loading": 20, "solving": 0, "routing": 0 }
  },
  "routes": [
    {
      "vehicle": 1, "cost": 1389, "delivery": [100], "service": 360,
      "steps": [
        { "type": "start", "location": [106.8456, -6.2088], "arrival": 0, "load": [100] },
        { "type": "job", "id": 2, "location": [106.8555, -6.1975], "arrival": 182, "load": [50], "service": 120 },
        { "type": "job", "id": 3, "location": [106.8427, -6.1690], "arrival": 646, "load": [30], "service": 120 },
        { "type": "job", "id": 1, "location": [106.8217, -6.1853], "arrival": 1274, "load": [0], "service": 120 },
        { "type": "end", "location": [106.8456, -6.2088], "arrival": 1749 }
      ]
    }
  ],
  "unassigned": []
}
```

#### `summary` fields

| Field | Meaning |
|-------|---------|
| `cost` | Total route cost, seconds. |
| `routes` | Number of routes. |
| `unassigned` | Count of unassigned jobs. |
| `delivery` / `pickup` / `amount` | Totals per dimension. |
| `service` / `setup` / `waiting_time` | Total seconds in each. |
| `duration` | Total duration, seconds. |
| `violations` | Constraint violations (empty if none). |

#### `routes[].steps[]`

| Field | Meaning |
|-------|---------|
| `type` | `start` \| `job` \| `pickup` \| `delivery` \| `break` \| `end`. |
| `id` | The job/shipment id (for non start/end). |
| `location` | `[lon, lat]` of the step. |
| `arrival` | Seconds from the vehicle's start. |
| `load` | Remaining load after the step (per dimension). |
| `service` / `setup` / `waiting_time` | Seconds for that step. |

#### `unassigned[]`

Array of `{ "id", "type", "reason" }` for jobs VROOM couldn't fit (empty if all
assigned).

### Error codes

| `code` | Meaning |
|--------|---------|
| `0` | Success. |
| `2` | Bad request (e.g. non-integer id, missing field). See `error`. |
| `3` | Server / timeout error. |

Always check `code` before reading `routes`.

---

## 2. OSRM — point-to-point routing

Base: `http://192.168.6.242:5000`. All coordinates in the URL are `lon,lat`.

> OSRM has **no `/health` endpoint**. Probe with a `/route` call; `code: "Ok"`
> means it is up.

### `GET /route/v1/car/{coords}` — fastest route

```
GET /route/v1/car/{lon1},{lat1};{lon2},{lat2}?overview=full&geometries=geojson
```

**Query params:**

| Param | Values | Default | Notes |
|-------|--------|---------|-------|
| `overview` | `false` \| `simplified` \| `full` | `simplified` | Geometry detail level. |
| `geometries` | `geojson` \| `polyline` \| `poly6` \| `poly5` \| `poly4` | `polyline` | Output geometry format. |
| `alternatives` | `true` \| `false` | `false` | Return up to 3 alternative routes. |
| `steps` | `true` \| `false` | `false` | Include turn-by-turn steps. |
| `annotations` | `distance`, `duration`, `speed`, … | — | Add per-leg annotations. |

**Example:**
```bash
curl "http://192.168.6.242:5000/route/v1/car/106.8456,-6.2088;106.8063,-6.2573?overview=full&geometries=geojson"
```

**Response (abridged):**
```json
{
  "code": "Ok",
  "routes": [
    {
      "distance": 10680.8,
      "duration": 726.9,
      "geometry": { "type": "LineString", "coordinates": [[106.8456, -6.2088], [ ... ], [106.8063, -6.2573]] },
      "legs": [ { "distance": 10680.8, "duration": 726.9, "steps": [ ... ] } ]
    }
  ]
}
```
`distance` is meters, `duration` is seconds. `geometry.coordinates` is the
`[lon, lat]` polyline.

### `GET /table/v1/car/{coords}` — distance/duration matrix

```
GET /table/v1/car/{lon1},{lat1};{lon2},{lat2};{lon3},{lat3}?annotations=duration,distance
```

Up to 1000 coordinates. Returns N×N matrices.

**Query params:** `annotations` (comma list of `distance`, `duration`, `speed`),
`fail_if_incomplete` (`true`/`false`).

**Example:**
```bash
curl "http://192.168.6.242:5000/table/v1/car/106.8456,-6.2088;106.8217,-6.1853;106.8555,-6.1975?annotations=duration,distance"
```

**Response (abridged):**
```json
{
  "code": "Ok",
  "durations": [[0, 182, 532], [182, 0, 350], [532, 350, 0]],
  "distances": [[0, 2600, 6500], [2600, 0, 3900], [6500, 3900, 0]]
}
```
`durations` in seconds, `distances` in meters. Row `i`, column `j` = from
coordinate `i` to coordinate `j`.

### `GET /nearest/v1/car/{coord}` — nearest routable nodes

```
GET /nearest/v1/car/{lon},{lat}?number=5
```

**Query params:** `number` (how many, default 1), `range` (max search radius,
meters).

**Response (abridged):**
```json
{
  "code": "Ok",
  "coordinates": [[106.8457, -6.2089], [106.8455, -6.2087]],
  "matched": [ { "distance": 12.4, "name": "Jl. ...", "location": [106.8457, -6.2089] } ]
}
```

### `POST /match/v1/car` — map-match a GPS trace

**Body:**
```json
{
  "traces": [[106.8456, -6.2088], [106.8450, -6.2080], [106.8440, -6.2070]],
  "radiuses": [50, 50, 50]
}
```

**Query params:** `interpolate` (`true`/`false`), `annotations` (`distance`,
`duration`, `speed`).

**Response (abridged):**
```json
{
  "code": "Ok",
  "traces": [
    {
      "distance": 120.5,
      "duration": 45.2,
      "geometry": { "type": "LineString", "coordinates": [ ... ] }
    }
  ]
}
```

---

## 3. Displaying the map with the route

The route is **not** a single geometry. VROOM returns the optimized *order*;
OSRM returns the *road geometry* for one leg. To render the full route on a map:

1. **Order** — `POST /` to VROOM; collect `routes[].steps[].location`
   (`[lon, lat]`) in order: start → stops → end.
2. **Per-leg geometry** — for each consecutive pair, call OSRM
   `GET /route/v1/car/{lon},{lat};{lon},{lat}?overview=full&geometries=geojson`
   and read `routes[0].geometry.coordinates`.
3. **Stitch** — concatenate the leg polylines, dropping the first point of each
   leg after the first (it duplicates the shared node).
4. **Render** — plot the polyline + a marker per point.

**Leaflet + OpenStreetMap (no API key):**
```js
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
      const c = j.routes[0].geometry.coordinates;
      if (i > 0) c.shift();
      full.push(...c);
    } else { if (i > 0) full.push(a); full.push(b); }
  }
  L.polyline(full.map(c => [c[1], c[0]]), { color: '#4f8cff', weight: 4 }).addTo(map);
  order.forEach((p, i) => L.circleMarker([p[1], p[0]], { radius: 8, fillOpacity: 1 }).addTo(map));
  map.fitBounds(L.latLngBounds(order.map(p => [p[1], p[0]])), { padding: [40, 40] });
}
```

**Gotchas:**
- OSRM is `[lon, lat]`; Leaflet wants `[lat, lon]` — swap when plotting.
- N stops = N-1 OSRM calls (one per leg).
- OSM tiles need no key; for high volume use a keyed tile provider (only the
  tile URL changes).
- The full tested implementation is `route-optimizer.html` → `drawRoute()`.

---

## 4. Quick error reference

| Service | Success | Failure signals |
|---------|---------|-----------------|
| VROOM | `code: 0` | `code: 2` (bad request, see `error`), `code: 3` (timeout) |
| OSRM | `code: "Ok"` | `code: "NoRoute"`, `code: "NotFound"`, `code: "InvalidNv"` |
