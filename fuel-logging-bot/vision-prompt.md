# Vision prompt and model contract

One model call per fill does two jobs: it **reads the pump display** (litres, cost) and **interprets the
caption** (odometer, optional relative date). The Worker does no caption parsing of its own. Everything
in this file is copied from the running code.

## Request

`POST https://openrouter.ai/api/v1/chat/completions`

Headers: `Authorization: Bearer ${OPENROUTER_API_KEY}`, `Content-Type: application/json`

```json
{
  "model": "<AI_MODEL, e.g. google/gemini-3.5-flash>",
  "messages": [{
    "role": "user",
    "content": [
      { "type": "text", "text": "<PROMPT below>" },
      { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,<photo bytes>" } }
    ]
  }],
  "temperature": 0
}
```

- There is one user message and no system message.
- The image goes in as a base64 data URL with the MIME type fixed as `image/jpeg`. Telegram re-encodes
  every `photo` as a JPEG, so this is always correct.
- `temperature: 0` makes the reading deterministic. There is no `response_format` or JSON mode, so the
  reply is parsed defensively (see below).

## Prompt text (exact)

Two values are inserted: `${caption}` is the trimmed Telegram caption (an empty string if there is none),
and `${dateContext}` is the message date as `YYYY-MM-DD` in **UTC**.

```text
Analyze this fuel pump photo.
Extract: 
1. Litres dispensed (number only)
2. Total Cost in GBP (number only)
3. Odometer from this caption: "${caption}" (the first number)
4. Date from caption relative to today (${dateContext}).

Return ONLY a raw JSON object like this:
{"type":"pump","litres":25.50,"cost":35.20,"odometer":85000,"date":"YYYY-MM-DD"}
If you cannot read it, return: {"type":"unknown","reason":"explanation"}
```

(The line `Extract: ` ends with a trailing space in the source. It makes no difference to the model.)

Rendered for a caption of `85412` sent on 12 Sep 2026:

```text
Analyze this fuel pump photo.
Extract: 
1. Litres dispensed (number only)
2. Total Cost in GBP (number only)
3. Odometer from this caption: "85412" (the first number)
4. Date from caption relative to today (2026-09-12).

Return ONLY a raw JSON object like this:
{"type":"pump","litres":25.50,"cost":35.20,"odometer":85000,"date":"YYYY-MM-DD"}
If you cannot read it, return: {"type":"unknown","reason":"explanation"}
```

## Expected output shapes

**Success** (`type: "pump"`):

```json
{"type":"pump","litres":42.18,"cost":58.62,"odometer":85412,"date":"2026-09-12"}
```

| Field | Type | Meaning | How the Worker uses it |
| --- | --- | --- | --- |
| `type` | `"pump"` | Display was readable | Any value other than `"unknown"` goes down the success path |
| `litres` | number | Litres dispensed, from the display | `parseFloat` |
| `cost` | number | Total sale in £, from the display | `parseFloat` |
| `odometer` | integer | First number in the caption, in miles | `parseInt` |
| `date` | `YYYY-MM-DD` | Fill date: today, or the date resolved from a relative word in the caption | Falls back to the message date if the field is missing or empty |

**Unreadable** (`type: "unknown"`):

```json
{"type":"unknown","reason":"The display is obscured by glare"}
```

This produces the reply `🤔 I couldn't read that pump display.\n\nReason: <reason, HTML-escaped>`. Nothing
is written.

## Caption rules (delegated to the model)

| Caption | Intended result |
| --- | --- |
| `85412` | odometer 85412, date = message date |
| `85412 yesterday` | odometer 85412, date = message date − 1 day |
| `85,412` / `85412 miles` | odometer 85412 ("the first number") |
| `85412 friday` / `85412 3 sept` | date resolved by the model relative to `dateContext` |
| *(no caption)* | Not guarded. The model may return `unknown`, or it may return a pump object with a missing or invented odometer. See Known limits in the README |

The model resolves relative dates, so results like "last Friday" depend on the model. If the date it
returns differs from the message date, the Worker treats the fill as **back-dated** and timestamps it
`<date>T12:00:00Z`.

## Parsing the reply

1. If the response JSON has an `error` field, throw `OpenRouter API Error: <error.message or JSON>`.
2. If there are no `choices[0]`, throw `Unexpected AI response: <whole JSON>`.
3. Take `choices[0].message.content`, trim it, delete every occurrence of `` ```json `` and then `` ``` ``,
   and trim again. Models often wrap JSON in a code fence even when told not to.
4. Run `JSON.parse`. A parse failure throws, and the user sees
   `❌ Error processing fuel log: Unexpected token …`.

The Worker does **not** check the HTTP status, the field types or whether the numbers are plausible.
Validation is entirely up to the model (see the README, "Rules & logic: validation").
