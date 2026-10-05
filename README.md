# Harry Randell — portfolio

A specs-first portfolio. AI writes most of my implementation code. What I own is the system design and
business logic (what to build, the rules it follows, the data model, the architecture), followed by
rigorous testing, and the lessons from when it broke. So each project here is a **folder with its spec,
not its code**.

There are two kinds: **personal projects** I built end to end, and **work case studies** describing what
I did on proprietary systems at my job.

## Personal projects

| Project | In one line | Stack |
|---|---|---|
| [**Strava Logging Agent**](strava-logging-agent/) | An LLM agent that keeps a six-year Strava journal in order. Code works out every fact, the model adds judgement and wording, and nothing is written without a 👍 | TypeScript · Next.js · Upstash Redis · AI SDK · Telegram |
| [**Pet Sitting Manager**](pet-sitting-manager/) | Turns a pet sitter's Google Calendar into priced booking history and printable client statements | Next.js · Google Calendar + Sheets |
| [**Fuel Logging Bot**](fuel-logging-bot/) | Photo of a fuel pump → vision model → row in a spreadsheet, plus trip and efficiency stats | Cloudflare Workers · OpenRouter · Sheets |
| [**Personal Map Coverage**](personal-map-coverage/) | Draw an area; see which of its OpenStreetMap paths your Strava runs have covered, and how that grew | Next.js · Supabase · Leaflet · Turf |

These specs go all the way down: data models, exact rules, prompts, schemas and a rebuild plan. Each is
meant to be complete enough for an agent with only that folder to rebuild the project. **This has been
tested once so far:** a fresh agent given only [`fuel-logging-bot/`](fuel-logging-bot/) built a working bot that
matched all 48 acceptance checks byte for byte in about 20 minutes. The points it had to guess at were
then added to the spec.

The working repos are private because they hold real people's data.

## Work case studies

Work I did as a data engineer at BX, an agricultural intelligence startup. The systems, their code
and their data are proprietary, so these stay at the level of architecture and decisions, and every
example is synthetic. Several were team efforts; each one says exactly what was mine.

| Case study | In one line | My part |
|---|---|---|
| [**Data Review Agent**](data-review-agent/) | An LLM agent that finds gaps in ingested data and resolves them with customers in-product, escalating to a human when it can't | Designed and built end to end |
| [**Unstructured Data Pipeline**](unstructured-data-pipeline/) | Unstructured farm documents → validated, decision-ready data: what to automate, what to keep as rules, where a human stays in the loop | Data models; own and operate it in production |
| [**Farm Sustainability Score**](farm-sustainability-score/) | A crop-agnostic 0–1000 sustainability score from a rubric of regenerative and farm-management practices, built by hand in a spreadsheet in 2023 | Designed and built the original model |
| [**Carbon Footprint Workspace**](carbon-footprint-workspace/) | A product-carbon-footprint project workspace and the reproducible allocation model underneath it | The workspace (UI + backend) and the allocation model |
| [**Farm Admin Manager**](farm-admin-manager/) | A geospatial editor for attaching and validating field boundaries and keeping track of which crops are on which fields | The boundary editor and crop tooling |

## Walking through a project

Every folder follows the same order, so you can jump to any section:

1. **At a glance** and **The problem**
2. **What it does**, with worked examples
3. **Architecture** (diagram) and **Data model**
4. **Rules & logic**
5. **Key decisions**: what I chose, why, and what I rejected
6. **Failure modes & lessons**
7. **Rebuild spec** (full for personal projects, high-level for work case studies)
