# Coverage algorithm (reference)

The whole product rests on one question: **"has this path been covered?"** This file is the exact answer, written so it can be
reimplemented line for line. Source of truth in the real repo: `lib/geometry.ts` (Turf 7, TypeScript).

## Constants

| Name | Value | Meaning |
|---|---|---|
| `BUFFER_METERS` | **15** | Half-width of the corridor drawn around each GPS track. A path point within 15 m of where you went counts as visited. |
| `COVERED_THRESHOLD` | **0.5** | A way is *covered* when ≥ 50 % of its sample points fall inside the visited corridor. |
| `PASS_THRESHOLD` | **0.1** | One activity counts as a *pass* of a way when ≥ 10 % of the way's sample points fall inside that activity's corridor. |
| Sample spacing | `N = clamp(floor(len_m / 5), 10, 100)` intervals → `N + 1` points | ~5 m apart for ways 50–500 m long; at least 11 points on short ways; at most 101 on long ways. |

Why 15 m: Strava's `summary_polyline` is a simplified, ~1e-5° precision line, not the raw GPS stream. It cuts corners on
bends, and consumer GPS drifts several metres under tree cover. 15 m absorbs both. The cost is that a parallel path
less than 15 m from the one you used is credited as well.

## Coordinate conventions
- Everything stored and computed is GeoJSON `[lon, lat]`. Leaflet wants `[lat, lon]`, so flip only at the drawing call.
- Polygons are stored **open** (first point not repeated). Every Turf polygon is built as `[[...ring, ring[0]]]`.

## Step 1 — `clipToPoly(coords, polygon)` (vertex-run clipping)

```
segments = []; current = []
for c in coords:
    if pointInPolygon(c, polygon): current.push(c)
    else:
        if len(current) >= 2: segments.push(current)
        current = []
if len(current) >= 2: segments.push(current)
return segments
```

It keeps **runs of consecutive vertices that are inside**. It does not compute where an edge crosses the boundary. Consequences
(accepted for simplicity, worth knowing):
- A segment stops at the last inside vertex, so up to one edge's length at each boundary crossing is ignored.
- A way that has only **one** vertex inside the polygon disappears entirely.
- A long straight edge that crosses the AOI with no vertex inside also disappears.

OSM ways in parks are densely noded, so in practice the losses are small.

## Step 2 — the visited corridor (`buildVisitedBuffer`)

```
buffers = []
for track in tracks (all of the user's synced activities):
    for seg in clipToPoly(track.coordinates, inclusion):     # exclusions are NOT applied to tracks
        buffers.push(turf.buffer(lineString(seg), 15, metres))   # skip degenerate segments that throw
visited = pairwiseTreeUnion(buffers)   # union [0,1],[2,3],… then repeat on the results until one remains
```

- Tracks are clipped to the inclusion polygon **before** buffering, so the union only grows inside the AOI. This keeps the
  polygon small however far the activity went.
- Tree (pairwise) union instead of a running fold: each union works on two similar-size shapes, so the work is about
  O(n log n) instead of re-unioning one ever-growing polygon n times. A failed union keeps the left operand.
- No tracks inside the AOI → `visited = null` → every eligible way is *missed*.

## Step 3 — eligible ways (inclusion then exclusions)

```
for way in osm_ways where aoi_id = this AOI:
    if len(way.coordinates) < 2: skip
    raw   = clipToPoly(way.coordinates, inclusion)
    valid = [ [c for c in seg if not any(pointInPolygon(c, ex) for ex in exclusions)] for seg in raw ]
    valid = [seg for seg in valid if len(seg) >= 2]
    if valid is empty: skip            # way is not part of this AOI's denominator at all
    eligible.push({ id, tags, clippedSegments: valid })
```

- **Inclusion** is the outer boundary. **Exclusions** are holes: a lake, a golf course, a private enclosure. Their paths are
  removed from the denominator, so you are not penalised for paths you could not or should not use.
- Exclusion handling **drops vertices**, it does not split the segment. If a path runs through an exclusion and out again, the
  vertices either side are kept in the same array, joined by a straight jump across the excluded area.
- `clippedSegments` is what is drawn on the map and what goes into the GPX export.

## Step 4 — `coveredFraction(coords, corridor)`

```
line = lineString(coords)
L    = length(line, metres)
N    = max(10, min(100, floor(L / 5)))
hits = count of i in 0..N where pointInPolygon(along(line, i/N * L), corridor)
return hits / (N + 1)
```

For a way, `coords = validSegments.flat()`: all of its clipped segments joined into one line. If a way was cut into two pieces
(it left the AOI or crossed an exclusion), the straight connector between the pieces is sampled too.

This is a **sampled length fraction**, not an exact geometric difference. It is cheap and has no failure cases, unlike
`lineString minus polygon` in Turf. The trade-off is a resolution of 1 / (N + 1) per way.

## Step 5 — classify and score (live analysis, `analyze()`)

```
covered = eligible ways with coveredFraction(way, visited) >= 0.5
missed  = the rest
stats.total      = len(covered) + len(missed)
stats.percentage = round(len(covered) / total * 1000) / 10     # one decimal place; 0 if total = 0
visitsToArea     = count of tracks with at least one clipToPoly segment inside the inclusion polygon
```

**The headline percentage counts ways, not kilometres.** A 25 m set of steps weighs the same as a 1.2 km bridleway. OSM
splits ways wherever tags change, so the count follows how the area was mapped. See the worked example in the README for how
far this can drift from a length-weighted figure.

## Step 6 — the timeline (`buildTimeline()`)

Replays history one day at a time so the slider can show how coverage grew.

```
eligible = Step 3 (each with coveredDate = null, passCount = 0)
byDate   = group tracks by start_date[0:10]          # UTC calendar date (Strava start_date is UTC)
visited  = null
uncovered = all eligible

for date in sorted(byDate):
    dayBuffers = buffer(clipToPoly(t, inclusion), 15 m) for t in that day's tracks
    if none: continue                                 # no activity entered the AOI that day
    dayUnion = sequential union of dayBuffers
    visited  = union(visited, dayUnion)

    # pass counting: per activity, against ALL eligible ways
    for track in that day's tracks:
        act = union of buffers of that track's clipped segments
        for way in eligible:
            if coveredFraction(way, act) >= 0.1: way.passCount += 1

    # first-covered date: only for ways still uncovered
    for way in uncovered:
        if coveredFraction(way, visited) >= 0.5: way.coveredDate = date; remove from uncovered

    report progress (percent of dates processed, date, coverage %)
    if uncovered is empty: break                      # early exit — see limits
return { ways: [{id, tags, clippedSegments, coveredDate, passCount}], dates: sorted(byDate),
         activitiesByDate: {date: number of activities that day, in or out of the AOI} }
```

Properties:
- **Monotonic.** The corridor only grows, so a way never becomes uncovered again. `coveredDate` is the first day the cumulative
  corridor reached 50 %. That can be the day of a second, partial visit that finished off a path started weeks earlier.
- **The final state matches the live analysis.** Same buffers, same threshold, same clipping. Only the union order differs.
- **Different thresholds on purpose.** A *pass* (10 % of the way, one activity) means "I used this path". *Covered* (50 %,
  cumulative) means "I have done this path".
- The client recomputes the slider state with no geometry at all:
  `covered(way, D) = way.coveredDate != null && way.coveredDate <= D`, and the percentage uses the same formula as Step 5.

## Edge cases and their handling

| Case | Behaviour |
|---|---|
| Activity with no GPS (treadmill, indoor) | Not stored at sync time (fewer than 2 polyline points). |
| Activity that never enters the AOI | Contributes nothing to the corridor; not counted in `visitsToArea`; still counted in `activitiesByDate`. |
| Way partly outside the AOI | Only the inside vertex runs are eligible and scored. |
| Way entirely inside an exclusion | Not eligible (removed from the denominator). |
| AOI with no OSM rows yet | Analysis returns `400 No OSM paths loaded yet`; UI shows the seed command. |
| User with no activities | Analysis returns `400 No activities synced yet`. |
| Degenerate geometry (zero-length segment, union exception) | Caught and skipped. One bad track never fails the run. |
| Activity just after midnight local time in summer | Bucketed on the previous UTC date (BST is UTC+1). |
