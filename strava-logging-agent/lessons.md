# Design lessons already paid for

This is a running log of failures and the principle each one led to. Every item started as a production bug in
the live agent (July–October 2026). Together they are what "making an LLM agent reliable" actually involved: the
interesting work was never the happy path.

> Incident names use the fictional persona (Sam, Jordan, Morgan, Scout, Poppy & Bear, Circuits, Northgate Common).
> Dates and mechanics are real.

**The pattern behind most of these:** whenever the model was trusted to *remember*, *count*, *copy* or *say it did*
something, it eventually didn't. The fix was almost never better prompting. It was moving that job into code and
leaving the model a smaller task.

---

## Part A: the founding ten (in AGENTS.md from launch week)

### 1. Models pass references, never blobs
Tools take an activity **id** and fetch the polyline themselves. An LLM asked to carry 2,000 characters of encoded
ASCII between tool calls will corrupt a few of them without any sign. Later, fact sheets were cut down to `slim(raw)`
for the same reason (15 Jul): a polyline never belonged in a prompt.

### 2. Tools return answers, not arithmetic
`next_counter` returns `next_number`, never "here's the current max, add one." Once arithmetic is left to the
model, it will sometimes get it wrong under load.

### 3. Machine outputs are verbatim
Weather and hill strings go into descriptions exactly as the tool returned them. The model is explicitly forbidden
from paraphrasing an instrument: "Cold, wet and windy (4°C)" must not drift to "chilly and wet".

### 4. The checklist runs in code, not the prompt
A prompt-level "always check X" gets skipped under pressure (the Northgate Common check was missed on a Scout
run on 7 Jul). The checklist is a function (`runChecklist`) that produces a typed fact sheet. The model receives
the results and doesn't re-derive them.

### 5. Counters commit from the written text, not the model's claim (13 Jul)
This one cost a day. Two different models were filling in a `countersUsed` field as free text, writing
`"Northgate Common #253"` where the code expected a key like `"wc"`. A blind INCR created junk Redis keys while the
real counters stalled, setting up number collisions for the *next* activity. Now counters advance only after a
write: code re-reads the saved name/description against a pattern registry with max-set semantics. The contract
was removed rather than coached.

### 6. The staged proposal *is* the proposal (11 Jul)
It happened twice in one day. The model described the *right* plan in chat ("this was a Poppy & Bear walk → P&B
#53"), Sam 👍'd, and the stale webhook pending applied instead, because the 👍 executes `chat:pending`, not the
message text. The conversation and the approval shortcut had two different ideas of "the proposal". The fix was a
`stage_proposal` tool: a corrected plan must be **restaged** before asking for confirmation.

### 7. Never inherit a limitation from chat history (9 Jul)
A limitation ("I can't set that field") may only be reported from a tool call made *this* turn. Otherwise the
agent repeats an old "I can't" long after the capability was added. Tools improve between turns.

### 8. One memory for all doors (11 Jul, "the tennis incident")
A webhook proposal was sent but never written to chat history. Sam's reply ("this was a Circuits workout") landed
in a conversation whose last memory was a question about a tennis match days earlier, and the agent took "this"
to mean the tennis. Now every outbound message (proposal, digest, apply report, delete note, refusal) is written to
the same history, and the open pending rides in the chat system prompt as the default referent.
The same proposal had missed an obvious Saturday Circuits session, which led to the second half of the fix: series
with no GPS trigger need **pattern evidence** in the fact sheet (recent same-sport and same-weekday lines with start
time and duration). The athlete's weeks have a rhythm. The no-GPS home-timezone flag also became the verbatim
*answer* instead of a hint (🇬🇧 had been written where 🏴󠁧󠁢󠁥󠁮󠁧󠁿 was correct).

### 9. Stories are sacred
Descriptions carry the athlete's own prose. Any transform machine-checks that every hand-written line survives
byte-for-byte, and **skips rather than writes** on a mismatch. Bulk edits (more than one activity) need a rendered
dry run and explicit consent before anything is applied. That rule binds coding agents working on the repo as
much as the runtime agent.

### 10. Verify before every write
Each write re-reads the activity's current name and refuses if it has drifted from what was proposed, and logs the
full before-state to an undo log first. Nothing is unrecoverable.

---

## Part B: lessons from running it (July → October 2026)

### 11. Format belongs in code, at the write chokepoint (17 Jul)
The model put descriptions together as free text. The *contents* were right every time, but the layout slipped: a
Scout run lost the blank line between counters and companion, and a Friday ☕️ put the companion after the weather.
`normalizeDescription` now re-lays out every description in `updateActivity`, the one function every write
passes through. It's idempotent and does nothing if it finds prose it doesn't recognise.

### 12. Identity comes from code, never the model (17 Jul)
A casual walk only needed a flag added, so proposed and current names differed by one emoji. The model staged the
*proposed* name ("🏴󠁧󠁢󠁥󠁮󠁧󠁿 Morning Walk") as `expect_current_name`, and verify-before-write correctly refused a valid
change. Now `activityId` and `expectName` come from the fact sheet or the cache, and the parameter was removed from
the tool. The follow-up (18 Jul) made staging read the name from the Redis cache first, so it doesn't depend on a
live Strava call.

### 13. Give real numbers in negative results too (17 Jul)
On a series non-match, the same walk's checklist claimed it was "~120 m from Scout's" when the start was ~1.1 km
away. If the fact sheet only says "no match", the model invents a plausible figure. The reason string now contains
the real distances to both triggers.

### 14. Read rules off the right instrument (17 Jul)
A Friday ☕️ passed within 75 m of a summit named after the Common without entering the Common polygon. The agent
reached the right outcome (no counter) but explained it with an invented "rituals don't get counters" rule and
reported the boundary as entered. The rulebook now says that boundary counters ignore series and rituals, and that
the Hills line is **not** the boundary.

### 15. Never let a fall-through reach the model (18 Jul)
A Circuits session was never staged, so Sam's 👍 found no pending and fell through to a conversational turn, where
the model **made up "✅ Applied"** for a write that never happened (the activity stayed "Morning Run" and the
counter stalled). Fix: a 👍 with nothing staged gets a fixed, honest reply with no model involved, and only code
ever says "Applied".

### 16. Corrections are deltas, and stale approvals are refused (21 Jul)
Asked to re-send the whole proposal object for a correction, the model dropped "w/ Jordan", and the stale
pre-correction pending applied. Two fixes: (a) `amend_pending` takes only the delta, and companions are a list that
code formats into the single alphabetical `w/` line; (b) a **staleness guard**: a 👍 on a pending staged *before*
Sam's last message is not applied ("predates your last message — restate or say apply as-is"). Accepted cost: an
unrelated message in between means one extra confirmation.

### 17. Guardrails make a cheaper model *safe*, not *good* (21–22 Jul)
With the write path now controlled by code, the default model was switched to a model ~3× cheaper. The guardrails
did their job (a slip led to an honest re-stage prompt rather than a wrong journal entry), but the cheaper model
kept *claiming* "staged with Jordan" without amending, and stalled against the staleness guard so a walk couldn't
be applied at all. Reverted the next day for ~$4/month. The model default is set in code (visible in git), because
the hosting env var was write-only and couldn't be checked.

### 18. Bursts must be one chronological batch (15 Jul)
A post-holiday watch sync fires N create events at once. Handled separately, they raced (two Scout runs both
proposed as #64), were numbered in arrival order, and overwrote one pending slot so only the last could be 👍'd.
Now: queue, a 90 s quiet window, the last arrival drains under a lock, sort by start time, batch-local counter
claims, add each activity to the cache before checking the next, and send **one** digest.

### 19. A dangling pending is a loaded gun (15 Jul)
When the Apply/Skip buttons were removed in favour of 👍-as-consent, "Skip" went with them, and a declined
proposal would sit armed for 48 h waiting for a stray 👍. Added `clear_proposal`. Legacy button taps on old
messages still get an honest answer instead of a dead spinner.

### 20. Tools must say what they cover (15 Jul, 2 Aug)
Asked "how many Circuits this year?", the agent subtracted series numbers and invented a start date: it said 22
when the answer was 43. Later, asked for the "last ride over 100 km", it looked through the 12-item `sample`, found
nothing, and offered to "keep paging". The answer was in `latest` all along. Fixes: date, sport and distance
filters, AND-ed terms for cross-referencing, aggregates over all matches, and tool descriptions that say outright
*the results are exhaustive; never reason from the sample; never subtract series numbers*.

### 21. Judgement calls that keep being missed belong in the fact sheet (2 Aug)
The July 21k was missed because "is this the monthly half?" was left to the model, and the earlier check was
name-based and fragile. It is now a distance rule in code (the first ≥21.1 km run of the month), consistent with
the counters. Commute legs moved into code at the same time (numbered by order in the day, not direction). The
model still decides *whether* a ride is a commute. Only the numbering moved.

### 22. Formatting can lose a whole message (31 Jul)
Telegram's HTML mode rejects the **entire** message over one stray `<`. A long proposal was lost this way: the
webhook reported an error, and its pending was left with no message attached. `sendMessage` now retries as plain
text when it gets a parse error. A bad format should produce an unformatted message, not a lost one.

### 23. Wrong reference data looks like model failure (2 Aug)
Asked to "use the Aero", the agent had no gear ID to offer, because the registry listed the main road bike as
"retired". The model behaved correctly given bad data. Fixed the registry and added a rule: if the athlete names
gear that isn't listed, ask rather than guess (it's probably new).

### 24. Post-apply corrections need an anchor (26 Aug)
Sam 👍'd, it applied, and then he said "that was also with Jordan". A pending clears when applied, so
`amend_pending` had nothing to amend and returned an error. The model didn't recover and wrote "👍 to apply" in
prose, so the correction was lost. Now `applyPending` records `last-applied` (6 h, single-item only), and
`amend_pending` restages against that activity's **live** state when nothing is pending.

### 25. A multi-item correction is one call (8 Sep)
Sam corrected all three items of a digest and only item 3 was staged, so 👍 applied items 1 and 2 with their old
names. Added `amend_batch`, which restages every corrected item together. Same release: when a companion is
itself a pair ("Poppy & Bear"), the Oxford "& last" read as "w/ Jordan & Poppy & Bear", so code now uses commas
throughout in that case.

### 26. If code can derive it, code assembles it (4 Oct)
A Scout run was applied with no flag. The model had worked out 🏴󠁧󠁢󠁥󠁮󠁧󠁿 correctly in its checklist and then left it
out of the name string (it's a 7-codepoint emoji and easy to drop). Now the model returns `flag` as a separate
field and a flagless name, and code joins them. The write chokepoint also carries an existing flag over on any
rename that lacks one.

### 27. Check the claim against the state (4 Oct)
"Please mute that last Scout run." The model replied "Staged: … 👍 to apply" and called **no tool** (one step). The
👍 hit an empty pending and the mute was lost. This kept happening around corrections that conflict with a rule
(muting a run is an exception). After every chat turn, code now checks: *does the reply invite a 👍 or say
"staged" while nothing is staged?* If so, it runs one forced corrective pass telling the model to call the right
staging tool. If that fails too, it sends an honest "it didn't take — tell me once more", never an empty promise.

---

## Meta-lessons

- **Lessons 6 → 16 → 24 → 25 → 27 are one family:** *the user's approval must point at a real staged object.*
  Each fix closed one more way for "the model said it" and "the system holds it" to diverge. A rebuild should
  include all five guards from day one.
- **Prefer deleting a contract to coaching it.** `countersUsed`, `expect_current_name` and model-assembled
  flags were all removed rather than reworded.
- **Guardrails should turn a slip into friction, not into a wrong entry.** An honest "I haven't applied it" costs
  one message. A wrong counter costs every later number.
- **Write the incident into the code comment.** Every guard in the source names the incident that caused it, so
  the next agent working on the repo doesn't remove it as "unnecessary".
