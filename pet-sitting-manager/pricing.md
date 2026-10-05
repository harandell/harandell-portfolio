# Pricing rules

The complete pricing engine: how a parsed booking (pet + service + start/end + IOU flag) becomes a
`cost`, `units` and `iouCredit`. Pure function, no I/O. Reimplementing exactly this reproduces the
production numbers.

All names and rates below are demo data (Biscuit, Mochi & Pancake, Waffle), not real
clients.

## 1. The rate table (`pricing` Sheet tab)

One row per rate. Columns are matched by header name, so order doesn't matter.

| Column | Required | Meaning |
|---|---|---|
| `pet` | yes | Exact pet name as it appears in calendar titles (`Mochi & Pancake`), or `*` = any pet |
| `service` | yes | `run` · `walk` · `daycare` · `housesitting` · `dropin` |
| `rate_unit` | yes | `per_session` · `per_night` · `per_day` · `first_weekly` · `additional_weekly` (legacy header `unit` accepted) |
| `rate` | yes | Number in GBP. Text like `£30` is tolerated (non-numeric characters stripped) |
| `client` | no | Owner's name. Builds a pet→owner directory (legacy header `owner` accepted) |
| `effective_from` | no | Date the rate starts. Blank = always effective (epoch) |

Header normalisation: trim, lowercase, spaces/hyphens → `_` (so `Effective From` works).

Row validation: rows with a blank `pet`/`service`, an unknown `rate_unit`, a non-numeric rate or an
unparseable date are **skipped silently**. If no valid rows remain, or a required header is missing,
or the read fails, the app uses a built-in `DEFAULT_PRICING` list instead.

`effective_from` parsing: a Sheets serial number (days since 1899-12-30) → UTC midnight of that date;
a typed string → `new Date(string)`.

Demo rate table used in every example below:

| pet | service | rate_unit | rate | effective_from |
|---|---|---|---|---|
| Biscuit | run | first_weekly | 30 | 2025-01-01 |
| Biscuit | run | additional_weekly | 25 | 2025-01-01 |
| Mochi & Pancake | walk | per_session | 34 | 2025-01-01 |
| Mochi & Pancake | daycare | per_session | 40 | 2025-01-01 |
| Mochi & Pancake | housesitting | per_night | 50 | 2025-01-01 |
| Waffle | walk | per_session | 20 | 2025-01-01 |
| Waffle | dropin | per_session | 15 | 2025-01-01 |
| `*` | housesitting | per_day | 50 | 2025-01-01 |

## 2. Rate lookup: `lookupRate(pet, service, unit, date)`

1. Candidates = rows where `(row.pet == pet OR row.pet == "*")` AND `row.service == service` AND
   `row.unit == unit` AND `row.effective_from <= booking start` (instant comparison).
2. None → `null`.
3. Sort: **exact pet beats `*`**; then **latest `effective_from` wins**.
4. Return the top row's rate.

Note the order: an exact-pet rate from 2025 beats a wildcard rate from 2026.

## 3. Choosing the unit for a booking

Units are tried in a **fixed order**, each looked up independently (so each step already prefers
exact pet over `*`):

```
if lookupRate(..., first_weekly) != null:          # tiered weekly
    unit = (weekPosition == 0) ? first_weekly : additional_weekly
    cost = lookupRate(..., unit) ?? 0
    units = 1
elif per_session found:   cost = rate;              units = 1
elif per_night found:     units = max(1, dayDiff - 1);  cost = rate × units
elif per_day found:       units = max(1, dayDiff);      cost = rate × units
else:                     cost = 0  (needs a manual custom_cost)
```

- `dayDiff` = whole calendar days between start date and end date (times zeroed). All-day calendar
  events have an **exclusive** end date, so a booking covering 17, 18, 19 July has end = 20 July and
  `dayDiff = 3`.
- **Unit precedence beats pet specificity across units.** A wildcard `per_session` would win over an
  exact-pet `per_night`, because `per_session` is checked first. In practice: don't create wildcard
  rows for a unit that ranks above a pet's own unit for the same service.
- If a `first_weekly` rate exists but no `additional_weekly`, the second and later bookings in the
  week cost £0.

### Week position (for `first_weekly` / `additional_weekly`)

- Group **all** parsed bookings (completed, scheduled, IOU and Rover alike) by
  `pet | service | weekKey(start)`.
- `weekKey` = date of the Monday of that booking's week (Monday-based week).
- Within a group, sort by start time; position 0 is "first", everything else "additional".

## 4. IOU bookings

An IOU booking is priced exactly like a normal one (including taking its week position), then:

```
iouCredit = cost
cost      = 0
```

So it earns no delivered revenue, the dashboard shows it in red as `−£iouCredit`, and it never
appears on a statement or in a total. In the Sheet, `cost` is blank and `iou_credit` holds the value,
so `SUM(cost)` over the tab equals delivered revenue.

## 5. Manual overrides (applied after pricing, during reconcile)

- `custom_cost = TRUE` on a Sheet row → that row's existing `cost` is kept instead of the computed
  one, on every future sync.
- `is_rover = TRUE` → booking priced as normal but excluded from statements (the agency bills the
  client directly) and hideable on the dashboard via the ROVER toggle.

## 6. Owner directory

For each pet (excluding `*`), the first row with a non-blank `client` sets `session.client`. It's
metadata only; nothing currently renders it.

---

## Worked examples

### per_session — a walk

`🐕 Mochi & Pancake - Walk`, 12:30–13:30.
No `first_weekly` rate for (Mochi & Pancake, walk) → `per_session` found = 34.
**cost £34, units 1.**

Same for a drop-in: `🐈 Waffle - Drop In`, 18:00–18:30 → **£15**. And day care:
`🐕 Mochi & Pancake - Day Care` (all-day, one day) → `per_session` 40 → **£40** (day care is
deliberately a flat session, not `per_day`).

### first_weekly / additional_weekly — tiered runs

`🐕 Biscuit` (no service in title → Biscuit's default service, `run`) on three days:

| Booking | Week (Mon) | Position | Unit | Cost |
|---|---|---|---|---|
| Mon 3 Aug 08:00 | 2026-08-03 | 0 | first_weekly | £30 |
| Wed 5 Aug 07:30 | 2026-08-03 | 1 | additional_weekly | £25 |
| Thu 6 Aug 08:00 | 2026-08-03 | 2 | additional_weekly | £25 |
| Mon 10 Aug 08:00 | 2026-08-10 | 0 | first_weekly | £30 |

Week of 3 Aug = **£80**; the following Monday resets to the first-of-week rate.

### per_night — housesitting

`🐕 Mochi & Pancake - Housesitting`, all-day, covering Fri 17 – Sun 19 Jul (iCal end = 20 Jul,
exclusive).

- No `first_weekly`, no `per_session` → `per_night` = 50 (exact pet).
- `dayDiff(17 Jul, 20 Jul) = 3` → nights = 3 − 1 = **2** (the departure day isn't a night).
- **cost £100, units 2.**

On the statement it is itemised as two lines (see `expandDaily` in the README): Fri 17 Jul £50 and
Sat 18 Jul £50, each showing the whole stay `17 Jul – 19 Jul` as its duration. This is exactly the
demo statement screenshot.

### per_day via the wildcard

`🐈 Waffle - Housesitting`, all-day, covering 1–3 Sep (end 4 Sep).

- Waffle has no housesitting rows. `first_weekly`, `per_session`, `per_night`: none for Waffle or `*`.
- `per_day`: no exact row, but `*` housesitting per_day = 50 matches.
- `dayDiff = 3` → units = **3** (every covered date is charged).
- **cost £150, units 3**, itemised as three £50 lines.

Contrast with Mochi & Pancake: their exact `per_night` row means the same 3-day stay costs £100, not
£150. The wildcard is only a fallback.

### IOU credit

Week of 3 Aug: `🐕 Biscuit` on Mon, then `🐕 IOU - Biscuit` on Wed.

- Monday: position 0 → £30.
- Wednesday IOU: position 1 → priced at additional_weekly £25 → `iouCredit = 25`, `cost = 0`.
- Dashboard: Wednesday row shows **−£25** in red with an IOU tag. Period total = £30 (IOU
  excluded), session count = 1.
- Sheet row: `cost` blank, `iou_credit` 25.
- Statement: the IOU line is omitted entirely.

Note the IOU still occupies a slot in the week, so a later real run that week is charged at £25,
not £30.

### effective_from — a price rise

Add a row: `Biscuit · run · first_weekly · 32 · 2026-09-01`.

| Booking | Candidates (first_weekly) | Winner | Cost |
|---|---|---|---|
| Mon 31 Aug 2026 08:00 | 30 (2025-01-01) only; the 32 row isn't effective yet | 30 | £30 |
| Mon 7 Sep 2026 08:00 | 30 (2025-01-01), 32 (2026-09-01) | latest → 32 | £32 |

`additional_weekly` stays at £25 because no new row was added for it; each unit is dated
independently. Historic bookings are repriced on every sync, but they keep the old price because the
lookup is by booking date. (Use `custom_cost` to pin anything that must never move.)

### No matching rate

`🐕 Biscuit - Walk` → (Biscuit, walk): no rows for any unit, no wildcard walk rate → **£0**. The row
lands in the Sheet with `cost 0`; set `custom_cost = TRUE` and type the agreed price to freeze it.

### custom_cost

Sheet row for a booking has `custom_cost TRUE`, `cost 45`. Calendar still says it's a £34 walk.
Reconcile keeps **£45** and rewrites everything else (title, times, pet, service) from the calendar.
