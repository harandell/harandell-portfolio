# Example interaction (synthetic)

> Illustrative and synthetic. Not a real customer exchange, not production prompts. It shows the
> agent's decision flow: pick the highest-leverage question, resolve in bulk, remember the answer, and
> escalate when it can't resolve.

---

### 1. The agent scans unverified data and finds a cluster of gaps

```
entity: fuel_purchase
unresolved rows: 40
gap: fuel_type is blank
observation: all 40 rows show the raw term "gas oil" on the source documents
```

The agent groups these as one question, not forty.

### 2. It asks the customer, in-product

> **Agent:** Your March fuel deliveries are recorded as "gas oil". Should these be logged as
> **red diesel**? (This affects 40 records.)
>
> **Customer:** Yes, that's our red diesel.

### 3. It resolves the rows and stores the fact

```
action: resolved 40 rows -> fuel_type = red_diesel
memory written: { customer: "example-farm", alias: { "gas oil": "red_diesel" } }
effect: this question will not be asked again for this customer
```

### 4. A second gap, this time it can't resolve

```
entity: yield
unresolved rows: 3
gap: harvest_date missing, not present on the source document
```

> **Agent:** I couldn't find a harvest date for 3 of your wheat yield records. Can you confirm the
> harvest date for block N4?
>
> **Customer:** Not sure off the top of my head.
>
> **Agent (follow-up 1 of 2):** No problem, roughly which month was it harvested?
>
> **Customer:** I'd have to check the paperwork.

### 5. It escalates rather than guessing

```
attempts: 2 (cap reached)
action: escalate to human teammate with full context
reason: value is genuinely not available; a guess would be worse than an open gap
```

The record stays flagged, not filled with a fabricated date. The human takes it from here.
