# Example conversations and exact reply templates

All messages are sent with `parse_mode: "HTML"`. `<b>` renders as bold, and any text from the model or
an error is passed through `escapeHtml`, which replaces `&`, `<` and `>`. The examples below are
real output from running the production `worker.js` locally, with Telegram, OpenRouter and Google mocked
and three fictional earlier fills in the sheet (see `sheet-schema.md`).

## 1. Logging a fill

**User** sends a photo of the pump display (it shows `42.18 L`, `£58.62`) with the caption:

```text
85412
```

**Model returns** (wrapped in a code fence, which the Worker strips):

```json
{"type":"pump","litres":42.18,"cost":58.62,"odometer":85412,"date":"2026-09-12"}
```

**Sheet row appended:** `2026-09-12 | 85412 | 42.18 | 58.62 | 1.390 | 381 | 613.16 | 14.54 | 0.15 | 0.10 | 2026-09-12T08:14:03.000Z`

**Bot replies:**

```text
✅ Logged for Sat 12th Sep 2026

🚗 Odometer: 85,412 miles
⛽ Litres: 42.18 L 🏆
💰 Cost: £58.62 💀
📊 Price/L: £1.390 💀
🌿 Efficiency: 14.54 km/L 💀
🛣️ Trip: 381 miles (613 km)
⏱️ Gap: 17.0 days 🏆

━━━━━━━━━━━━━━━
📈 Running totals

🛣️ Total miles: 1,102
🌍 Total km: 1,773
💸 Total spent: £215.44
🌿 Avg efficiency: 11.33 km/L
📉 Avg cost/mile: £0.20
📉 Avg cost/km: £0.12
```

Reading the emojis against the three earlier fills:

| Line | Value | Earlier min / max | Direction | Badge |
| --- | --- | --- | --- | --- |
| Litres | 42.18 | 35.80 / 40.12 | higher is "better" | 🏆 new max |
| Cost | 58.62 | 49.76 / 54.96 | lower is better | 💀 new max |
| Price/L | 1.390 | 1.357 / 1.390 | lower is better | 💀 equals max (ties count) |
| Efficiency | 14.54 | 14.79 / 15.72 | higher is better | 💀 new min |
| Trip | 381 | 329 / 392 | higher is better | none, it falls inside the range |
| Gap | 17.0 | 14.0 / 15.3 | higher is better | 🏆 new max |

Running totals include this fill. Avg efficiency is total km ÷ total litres, and it comes out *below*
every per-fill efficiency because the first ever fill's 38.40 L count in the litres total while its trip
is 0. This is a known quirk of the weighted totals (see README, Known limits).

The `<b>` tags are in the raw text but don't show above. The raw first line is
`✅ <b>Logged for Sat 12th Sep 2026</b>`.

### Exact template

```text
✅ <b>Logged for {Ddd} {D}{st|nd|rd|th} {Mmm} {YYYY}</b>\n
\n
🚗 Odometer: {odometer.toLocaleString()} miles\n
⛽ Litres: {litres as given} L{emoji}\n
💰 Cost: £{cost.toFixed(2)}{emoji}\n
📊 Price/L: £{pricePerLitre 3dp}{emoji}\n
🌿 Efficiency: {kmPerLitre.toFixed(2)} km/L{emoji}\n
🛣️ Trip: {milesDriven} miles ({kmDriven.toFixed(0)} km){emoji}\n
⏱️ Gap: {days.toFixed(1)} days{emoji}\n        ← only if there is a previous fill and gap > 0
\n
{runningTotalsBlock}
```

`{emoji}` is either an empty string, `" 🏆"` or `" 💀"`, always with a leading space. The ordinal suffix
is `st/nd/rd` for dates ending in 1/2/3, except 11, 12 and 13, which take `th`.

### Running totals block (shared by the fill reply and `stats`)

```text
━━━━━━━━━━━━━━━\n                                          (15 × U+2501)
📈 <b>Running totals</b>\n
\n
🛣️ Total miles: {totalMiles.toLocaleString()}\n
🌍 Total km: {totalKm, 0 dp, grouped}\n
💸 Total spent: £{totalSpent, exactly 2 dp, grouped}\n
🌿 Avg efficiency: {totalKm/totalLitres, 2 dp} km/L\n
📉 Avg cost/mile: £{totalSpent/totalMiles, 2 dp}\n
📉 Avg cost/km: £{totalSpent/totalKm, 2 dp}
```

Any division by zero shows as `0.00`.

## 2. Back-dated fill

**Caption:** `85412 yesterday`, sent on 12 Sep. The model returns `"date":"2026-09-11"`. That differs from
the message date, so the fill is back-dated:

- Column A is `2026-09-11`.
- Column K is `2026-09-11T12:00:00.000Z` (assumed midday, because the real time of day is unknown).
- The reply heading is `✅ Logged for Fri 11th Sep 2026`, and Gap is measured from midday on the 11th.

## 3. Stats

**User:** `stats` (or `/stats`, in any case, with surrounding whitespace ignored)

**Bot replies** (the same fictional three-fill log, before example 1):

```text
📊 All-time stats
3 fills · 28 Jul 2026 – 26 Aug 2026

              avg    min    max
Litres      38.11  35.80  40.12
Cost £      52.27  49.76  54.96
Price/L £   1.372  1.357  1.390
Eff km/L    15.25  14.79  15.72
Trip mi       361    329    392
Gap days     14.7   14.0   15.3
£/mile       0.15   0.14   0.15
£/km         0.09   0.09   0.09

━━━━━━━━━━━━━━━
📈 Running totals

🛣️ Total miles: 721
🌍 Total km: 1,160
💸 Total spent: £156.82
🌿 Avg efficiency: 10.15 km/L
📉 Avg cost/mile: £0.22
📉 Avg cost/km: £0.14
```

- The table is inside `<pre>…</pre>` so it renders in a monospace font. Each label is padded right to 10
  characters and each number is padded left to 7.
- Metric rows and decimal places, in order: Litres 2, Cost £ 2, Price/L £ 3, Eff km/L 2, Trip mi 0,
  Gap days 1, £/mile 2, £/km 2.
- A metric with no positive values yet is left out of the table.
- `avg` is the **mean of the per-fill values**, and those values (zeros skipped) are the same ones min
  and max come from. That means avg always falls between min and max.
- The header line is `{n} fill{s}` followed by ` · {D Mmm YYYY} – {D Mmm YYYY}` (first to last fill
  time), with an en dash. The date range is omitted if either end can't be parsed.
- The running totals cover the log as it stands. Nothing is added for a current fill.

With an empty log the reply is:

```text
📊 Nothing logged yet — send a photo of a pump display to get started.
```

## 4. Unreadable photo

The model returns `{"type":"unknown","reason":"Display is blurred <glare>"}`, and the bot replies:

```text
🤔 I couldn't read that pump display.

Reason: Display is blurred &lt;glare&gt;
```

(Telegram renders this as `<glare>`.) If `reason` is missing, the reply says `Unknown`. Nothing is
written.

## 5. Errors

Any exception in the fill pipeline (Telegram file fetch, OpenRouter, JSON parse, Sheets read/append)
produces:

```text
❌ Error processing fuel log: {escaped error.message}
```

For example, if the model replies with something that isn't JSON:

```text
❌ Error processing fuel log: Unexpected token 'o', "not json" is not valid JSON
```

Error messages that come from the Worker itself:

- `OpenRouter API Error: …`
- `Unexpected AI response: …`
- `Sheets GET Error: <body>`
- `Sheets POST Error: <body>`

A failure in the stats pipeline gives `❌ Couldn't build stats: {escaped error.message}`.

## 6. Ignored input (no reply)

The bot does not reply to:

- text other than `stats` or `/stats`
- stickers, voice notes or locations
- images sent **as a file** (`message.document`) rather than as a photo
- updates that have neither `message` nor `edited_message` (such as `callback_query` or `channel_post`)
- any `GET` request (the reply is the plain text `OK`, which works as a health check)
