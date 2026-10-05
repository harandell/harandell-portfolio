# Tool contracts

These are the tools the model can call in `chatTurn` (Vercel AI SDK `tool()` with Zod `inputSchema`, capped by
`stopWhen: stepCountIs(16)`). `composeProposal` / `composeBatchProposal` use **no tools**: they get a finished
FactSheet and must reply with strict JSON.

## Design principles (each one came from a real failure; see [lessons.md](lessons.md))

1. **References, not blobs.** Geo tools take an activity **id** and fetch the polyline themselves.
2. **Answers, not arithmetic.** `next_counter` returns `next_number`. Search returns aggregates (`total`,
   `latest`, `longest`), so the model never counts.
3. **Machine lines are verbatim.** `get_weather` / `get_peaks` return `line`, which goes into descriptions exactly as
   returned.
4. **Code owns identity and format.** Staging tools capture the live name themselves, and companion edits take a
   *list* while code builds the `w/` line.
5. **Deltas, not rewrites.** Corrections pass only what changed, and code merges it into what is staged.
6. **Descriptions are part of the contract.** Tool descriptions spell out *when* to use each tool and what not to
   infer ("results are exhaustive", "never subtract series numbers"). Several of the fixes below were wording fixes.
7. **No tool can report a write as done to the user.** Only `applyPending` emits `✅ Applied`.

## Read tools

| Tool | Input | Returns | Notes |
|---|---|---|---|
| `get_activity` | `{id}` | slim activity (name, description, sport, distance, times, timezone, latlng, gear, commute, mute, HR, photos, device…) | Live Strava GET |
| `list_recent` | `{count: 1–30 = 10}` | slim activities | Live |
| `search_history` | `{terms?: string[], sport?, min_km?, max_km?, order: asc\|desc, year?, from?, to?}` | `{total, by_sport, earliest, latest, longest, sample[≤12], echo of filters}` | Searches the **whole journal** from cache (one `HGETALL` each for summaries and descriptions, rather than ~1,600 single reads). `terms` are AND-matched, case-insensitive, over `name + "\n" + description` (the `\n` stops a match across the join). Dates are the athlete's **local** dates. The description says: results are EXHAUSTIVE, `sample` is a preview not a page, read last/first/longest/counts from aggregates, never offer to "keep digging", never work out counts by subtracting series numbers |
| `next_counter` | `{key}` (`scout, pb, circuits, hq-commute-day, pepper, striders, hq-run, hq-workout, hm, wc, rp, marathon`) | `{key, next_number, highest_existing}` | Peek only. "Counters commit automatically when a write contains the number. Never track them yourself" |
| `check_boundaries` | `{id}` | `{northgate_common: {enters, next_number\|null}, kingsway_park: {…}}` | Polygon test only. Unrelated to the Hills line |
| `get_weather` | `{lat, lon, start_date_local}` | `{line: "Weather: …"}` | Use verbatim |
| `get_peaks` | `{id}` | `{line: "Hills: …" \| null}` | GB/IE catalogue. Use verbatim |
| `get_spend` | `{}` | `{total, today}` turns and tokens | From `usage-log` |

## Staging tools (the only way a change reaches Strava via 👍)

| Tool | Input | Behaviour |
|---|---|---|
| `stage_proposal` | `{activity_id, name?, description?, sport_type?, gear_id?, commute?, hide_from_home?, summary}` | Creates or **replaces** a proposal. `expectName` is taken from the Redis cache (falling back to live Strava), **never from the model**. **Batch-aware:** if a digest is pending, it replaces or appends that one item and keeps the others. Returns `{staged, batch_size, note: "👍 now executes …"}` |
| `amend_pending` | `{activity_id?, companions?: string[], name?, description?, sport_type?, gear_id?, commute?, hide_from_home?, summary?}` | **Delta merge** into the staged item (`{...staged.updates, ...defined fields}`). `companions` is the **full list**, and code runs `setCompanions` on the staged description. **Recovers on its own:** if nothing is staged, it re-stages the delta against `activity_id ?? last-applied`, using that activity's **live** name and description. Errors only if there's no anchor |
| `amend_batch` | `{corrections: [{activity_id, companions?, name?, …}, …] (min 1)}` | Corrects several digest items in **one** call. Each item is merged as in `amend_pending`. Missing ids are reported per item. Items not mentioned are kept unchanged |
| `clear_proposal` | `{}` | Deletes the whole pending set (use it when Sam declines) |

## Write & memory tools

| Tool | Input | Behaviour |
|---|---|---|
| `update_activity` | `{id, expect_current_name, name?, description?, …}` | Direct write via the `updateActivity` chokepoint (verify → normalise → flag carry → PUT → undo → cache → counters). Only for a single activity Sam explicitly named with a clear instruction. Bulk edits need the dry-run contract |
| `record_rule` | `{rule}` | Appends `- [date] rule` to Redis `learned` (loaded into every system prompt). Only after the model has quoted the rule and Sam has explicitly said yes to "make that permanent?" |

## Compose contracts (no tools, strict JSON)

`composeProposal(facts)` prompt → reply **only**:

```json
{
  "message": "Telegram text: every checklist outcome incl. negatives, proposed name/description/metadata, duplicate warning + delete link, ends asking for confirmation",
  "pending": {
    "flag": "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
    "updates": { "name": "Scout #65", "description": "…", "sport_type": "TrailRun", "gear_id": "g10000001", "hide_from_home": false }
  }
}
```

Code then strips any ```json fences and parses. It sets `activityId` and `expectName` from `facts.activity` (ignoring the
model's values), assembles `name = flag + " " + name` unless a flag is already there, and sets
`summary = message[0..200]`. If parsing fails, the message is sent as-is with **no pending**, so no change can be
applied.

`composeBatchProposal(factsList)` → `{"message": "one numbered digest … 👍 applies ALL", "items": [{activityId, flag,
updates}, …]}`. `expectName` is looked up by id from the fact sheets (a missing id gives `''`, so that write refuses).

## System prompt structure

1. Persona and format: concise, warm, concrete. Telegram HTML `<b>`/`<i>` only, never markdown.
2. Core conduct (in code, so it can't be edited away with the rulebook): use facts verbatim, no arithmetic,
   propose before acting, bulk needs confirmation, **always stage before inviting 👍**, use `amend_pending` for
   post-apply corrections, use `amend_batch` for corrections to several items, **never say applied/done/saved**, say so
   when context is missing, **never conclude a limitation from an earlier failure (re-try tools this turn)**, can't
   delete or upload photos, offer `record_rule` for lasting preferences.
3. `THE RULEBOOK:` + the full `RULES.md`.
4. `LEARNED AMENDMENTS (same force as rules):` + the `learned` list.
5. (`chatTurn` only) `OPEN PROPOSAL: <pending JSON>` + "if Sam's message plausibly responds to it, it refers to THIS
   activity, never to older chat topics."
