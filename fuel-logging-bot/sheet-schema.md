# Google Sheet schema

There is one spreadsheet with one tab, named exactly **`Fuel Log - Unleaded 95`**. The Worker reads and
appends to the range `'Fuel Log - Unleaded 95'!A:K`. The tab name is a code constant (`SHEET_TAB`).

- **Row 1 is a header row.** The Worker skips the first row it reads and never looks at what it says, so
  the header text is up to you. The labels below are suggestions.
- **Every row after that is one fill**, in the order it was logged. The Worker assumes the **last row is
  the previous fill**. It does not sort the rows, so do not sort the tab by any column other than date.
- **The sheet has no formulas.** The Worker calculates every derived value and appends plain values with
  `valueInputOption=USER_ENTERED`, so Sheets parses numeric strings such as `"1.390"` into numbers. The
  formulas column below says what each value means. It is not what is stored in the cell.

| Col | Suggested header | Written as | Example | Meaning / equivalent formula |
| --- | --- | --- | --- | --- |
| A | Date | `YYYY-MM-DD` string | `2026-09-12` | Fill date: the model's `date`, or the message date in UTC |
| B | Odometer (mi) | integer | `85412` | Odometer reading from the caption, in miles |
| C | Litres | number | `42.18` | Litres from the pump display |
| D | Cost (£) | number | `58.62` | Total cost from the pump display |
| E | Price/L (£) | string, 3 dp | `"1.390"` | `= D / C` |
| F | Trip (mi) | integer | `381` | `= B − B(previous row)`. The first ever fill gets `0` |
| G | Trip (km) | string, 2 dp | `"613.16"` | `= F × 1.60934` |
| H | km/L | string, 2 dp | `"14.54"` | `= G / C`, or `0.00` if G ≤ 0 or C ≤ 0 |
| I | £/mile | string, 2 dp | `"0.15"` | `= D / F`, or `0.00` if F ≤ 0 |
| J | £/km | string, 2 dp | `"0.10"` | `= D / G`, or `0.00` if G ≤ 0 |
| K | Timestamp | ISO-8601 UTC | `2026-09-12T08:14:03.000Z` | Fill time: the Telegram message time, or `<date>T12:00:00Z` if back-dated |

Column K came later (commit `f9f9154`). Older rows leave it blank, and the code falls back to column A
for them (see below).

## Example rows

```text
A           B       C      D       E      F    G       H      I     J     K
Date        Odo     Litres Cost    £/L    mi   km      km/L   £/mi  £/km  Timestamp
2026-07-28  84310   38.40  52.10   1.357  0    0.00    0.00   0.00  0.00
2026-08-11  84702   40.12  54.96   1.370  392  630.86  15.72  0.14  0.09
2026-08-26  85031   35.80  49.76   1.390  329  529.47  14.79  0.15  0.09  2026-08-26T07:42:10.000Z
2026-09-12  85412   42.18  58.62   1.390  381  613.16  14.54  0.15  0.10  2026-09-12T08:14:03.000Z
```

The last row is the exact payload the Worker appended in a local simulation (the data is fictional):

```json
{"values":[["2026-09-12",85412,42.18,58.62,"1.390",381,"613.16","14.54","0.15","0.10","2026-09-12T08:14:03.000Z"]]}
```

## How the rows are read back

The `GET` uses the default `FORMATTED_VALUE`, so cells come back as display strings such as `"£58.62"` or
`"85,412"`. Every number goes through:

```text
parseSheetNum(v) = parseFloat(String(v || "0").replace(/[^0-9.-]+/g, "")) || 0
```

This strips currency symbols and thousands separators. Blank or garbage cells become `0`. The odometer
uses the same stripping with `parseInt`.

The fill time of a row is:

1. column K through `Date.parse`, if K is present and valid; otherwise
2. column A through `Date.parse`, which gives midnight, so gaps for these rows come out in whole days;
   otherwise
3. `NaN`, and the row is left out of gap calculations.

**Locale caveat:** with `USER_ENTERED`, Sheets turns column A into a real date, which then comes back in
the sheet's display format. Keep column A formatted as `yyyy-mm-dd` (Format → Number → Custom). If you
don't, a UK-locale `12/09/2026` comes back and `Date.parse` reads it US-style. Rows with a column K
timestamp are unaffected.
