# Architecture

Companion to `README.md`. Records the significant decisions and how the system is put
together. Numbered decisions marked **[DECISION]** were made in Step 0 and should be
challenged now — they get expensive to change later.

## Principles

1. **Server-side first.** All logic lives in Rails. JS is limited to: service worker,
   offline queue, study-session keyboard/audio handling, and the offline/online switch.
   No SPA framework, no animation.
2. **Minimal dependencies.** Nothing is added to the Gemfile without explicit approval.
   Clients (OpenAI-compatible API, ZIP handling, FSRS, Anki formats) are hand-written.
3. **Modular boundaries.** Anki compatibility lives in `lib/anki`. AI lives in `Ai::*`.
   Scheduling lives in `Fsrs::*` + `Reviewing::*` services. Controllers stay thin.
4. **Idempotent sync.** Anything a client can submit while offline is an operation with
   a client-generated unique id; replaying it must be a no-op.

## System overview

```
 Browser (vanilla JS + Service Worker)          Rails (Puma)                 Background
 ┌───────────────────────────────┐   ┌────────────────────────────────┐  ┌──────────────┐
 │ Pages (server-rendered HTML)  │   │ Controllers ──► Services       │  │ Solid Queue  │
 │ SW cache: study page + media  │◄──┤  Sessions (auth)               │  │  Ai:: jobs   │
 │ IndexedDB outbox (sync ops)   │──►│  Decks:: Import/Export/Builder │◄─┤  (agent loop)│
 │ Study session (client-side,   │   │  Reviewing:: apply/schedule    │  └──────┬───────┘
 │  online + offline alike)      │   │  Syncing:: ApplyOps (ledger)   │         │
 └───────────────────────────────┘   │  lib/anki (apkg reader/writer, │         │
        POST /sync (batched ops)     │   template engine)             │         ▼
                                     │  Fsrs (scheduler, pure)        │  Ai::Client ──► OpenAI-compatible API
                                     │  Ai:: (agent, client)          │
                                     └───────┬────────────────────────┘
                                             ▼
                                    SQLite (storage/*.sqlite3)
                                    + media files on disk (Active Storage disk service)
```

## Data model

Rails migrations; SQLite. Central idea **[DECISION 1]**:

> **Content is global, progress is per-user.** A deck's cards are shared content;
> scheduling state (`card_states`) is keyed by `(user_id, card_id)`. This is what makes
> "public decks visible to everyone, no shared progress" fall out of the schema for
> free, and it is also exactly what the offline sync needs to reconcile.

| Table | Purpose / notable columns |
|---|---|
| `users` | `name`, `password_digest` (bcrypt). No registration; rake task creates users. |
| `decks` | `user_id` (owner), `name`, `description`, `visibility` (private/public), `created_at`. |
| `note_types` | `deck_id`, `name`, `kind` (standard/cloze), `fields` (JSON: ordered names), `templates` (JSON: [{name, front, back}]), `css`. Scoped to the deck: an imported deck carries its own note types; keeps import/export self-contained. |
| `notes` | `deck_id`, `note_type_id`, `fields` (JSON array, Anki order), `tags`, `guid` (Anki round-trip identity), `anki_note_id`. |
| `cards` | `note_id`, `deck_id`, `template_ord`, `position` (new-card order; "add to next" manipulates this), `suspended` (bool). One row per note × template, like Anki. |
| `card_states` | UNIQUE `(user_id, card_id)`. FSRS memory: `state` (new/learning/review/relearning), `stability`, `difficulty`, `due` (timestamp), `last_reviewed_at`, `reps`, `lapses`. Created lazily when a user first studies a deck (bulk insert). |
| `review_logs` | `user_id`, `card_id`, `rating` (1-4), `reviewed_at`, `duration_ms`, `sync_op_id` (nullable). Doubles as Anki revlog for export and for re-deriving state. |
| `media_files` | `deck_id`, `filename` (unique per deck — identity used by `[sound:x.mp3]` / `<img src="x.svg">`), Active Storage attachment (disk service). |
| `sync_ops` | UNIQUE `op_id` (client-generated UUID), `user_id`, `kind`, `payload` (JSON), `applied_at`. The idempotency ledger. |
| `ai_settings` | single row: `base_url`, `api_key` (**encrypted** via Rails attribute encryption), `models` (cached JSON), `models_refreshed_at`. |
| `ai_generations` | `user_id`, `description`, `model`, `status` (pending/running/done/failed), `transcript` (JSON: messages + tool calls as the loop progresses), `deck_id` (result). Polled by the UI; updated by the job. |

## Auth & multi-user

- `has_secure_password` + Rails cookie session; `login`/`logout` routes; every page
  behind `authenticate`.
- `user:create[name,password]` rake task (no registration flow).
- Visibility: every read path resolves decks through `Deck.visible_to(user)`
  (`public OR owned`). Public decks are studyable, browsable (the "Browse public
  decks" page lists everyone else's public decks with **your own** due/new counts)
  and exportable **with the requester's own progress**; writes (add card, edit
  deck, delete) are owner-only. Studying someone else's deck creates progress rows
  for *you* only — the schema was per-user from day one, so nothing leaks between
  users (verified E2E: reader reviews never appear for the owner, and vice versa).

## Anki compatibility layer — `lib/anki`

**[DECISION 2] — Container handling via system `zip`/`unzip` binaries, no rubyzip.**
`.apkg`/`.colpkg` are ZIP files. We shell out (`unzip -p` streams members, important for
the 77 MB fixture) and write exports with `zip`. A boot-time capability check fails fast
with a clear message if the binaries are missing. *Alternative rejected:* rubyzip gem
(pure Ruby, works everywhere) — add it only if the VM can't guarantee the binaries.

**[DECISION 3] — Import flattens subdecks.** An `.apkg` import becomes **one `Deck`**.
Each card stores its originating Anki subdeck path (`anki_subdeck`) for browsing/filtering
later. The French fixture has 62 subdecks; 62 Rails decks would clutter the UI and
Anki's own model (review the parent, subdecks included) doesn't map to a flat deck list.
Full hierarchy can be layered on later without schema change (`anki_subdeck` keeps the path).

**Reader** (`Anki::Apkg::Reader`): unzip to a temp dir; pick the newest collection
(`collection.anki21` > `collection.anki2`; schema-11 only — both fixtures, and any deck
exported with "support older Anki versions"). Read via the sqlite3 gem, read-only:

- `col.models` / `col.decks` JSON → note types (fields, templates, css) and subdeck paths
- `notes.flds` (split on `\x1f`), `guid`, tags
- `cards` → cards + template ord; `queue/type/due/ivl/factor/reps/lapses` → **initial
  FSRS state for the importing user** using Anki's own SM-2→FSRS migration heuristic
  (stability ≈ ivl, difficulty derived from ease factor; new/learning states from
  queue/type/due)
- `revlog` → `review_logs` (ease 1-4 maps to Again/Hard/Good/Easy)
- `media` manifest + numbered members → `media_files`
- Whole import in one transaction; `insert_all` batching for the 15k-note fixture.

**Template engine** (`Anki::Template`): hand-written renderer for the subset of Anki's
Mustache-like syntax the fixtures (and mainstream decks) use: `{{Field}}`,
`{{#Field}}…{{/Field}}`, `{{^Field}}`, `{{cloze:Field}}`, `{{hint:Field}}`,
`{{type:Field}}`, `{{Tags}}`, `{{Deck}}`, plus HTML-escaped vs raw handling. Note-type
`css` is emitted in a scoped `<style>`. Cloze cards: question masks the current cloze,
answer reveals it; other cloze numbers stay masked per Anki semantics.

**Sanitization** [DECISION 4]: Anki field HTML is rendered via Rails' built-in
`sanitize` (allowlist; already a Rails transitive dep — no new gem) because public decks
mean rendering HTML authored by other users. `[sound:...]` tags are rewritten to
`<audio>` elements pointing at our media route; `<img src="…">` is rewritten to the
per-deck media route.

**Writer** (`Anki::Apkg::Schema11Writer` + `Decks::Export`): export = build a schema-11
`collection.anki2` in a temp SQLite DB (notes with guids, cards with the requesting
user's progress mapped FSRS→SM-2 columns — the exact inverse of Import's mappings: due
day numbers are counted from the deck's `crt`, learning dues are epoch seconds, `left`
reconstructs learning steps, difficulty maps back to an ease factor — plus revlog with
ease 1-4), `zip -j` it with numbered media members + JSON `media` manifest, stream the
download, delete the tempfile. Subdecks are rebuilt from the cards' `anki_subdeck`
names (first `::` component dropped, so they nest under the deck's current name and
survive renames and repeated round-trips). In-app-created objects get generated ids in
Anki's real id spaces; imported ones keep their original Anki ids, so round-trips are
stable. Schema 11 is importable by every Anki in circulation. The guids make
export → Anki → re-import idempotent-ish, and our own round-trip
(import → export → import) is a unit test plus a system test (download via the UI,
inspect the archive, re-import it).

## Scheduling — `Fsrs`

**[DECISION 5] — Hand-written FSRS-5** (the version shipped in current stable Anki;
19 default parameters, well-published). Pure module: `Fsrs.schedule(card_state, rating,
now) -> next card_state + interval`, no ActiveRecord knowledge. Tests assert
determinism, monotonicity (higher rating ⇒ longer interval), correct state transitions
(new→learning→review, lapse→relearning), and spot values derived from the reference
implementation. The scheduler is version-isolated (`Fsrs::V5`) so a later bump to
FSRS-6 is contained.

Queue building per `(deck, user)`: due reviews (due ≤ now) ordered by due; learning
steps interleaved; new cards ordered by `position`, up to a daily new-card limit and
review limit (deck settings columns: `new_per_day`, `reviews_per_day`, defaults
Anki-like). "Add to next" = create card with `position` below the current minimum.

## Offline review & sync

**[DECISION 6] — Client-side session + SW cache + IndexedDB outbox (one code path
for online and offline).**

- The study page serializes the remaining queue **once** as JSON in the page (both
  sides of every card pre-rendered, per-rating interval previews, note-type CSS,
  typed-answer expectations for `{{type:Field}}` cards; the queue is capped by daily
  limits, so this stays small). A framework-free vanilla module
  (`app/javascript/study_session.js`) runs the whole session client-side: reveal,
  rating, keyboard shortcuts, audio autoplay, typed-answer comparison. Online and
  offline behavior is identical except **where each review goes**: straight to
  `POST /sync` when the network is up, or into an IndexedDB outbox when it isn't.
  This replaces the server round-trip-per-card form flow — reviews become instant
  and there is no separate "offline mode" to keep visually in sync.
- Reviews are **ops**: `{op_id: uuid, kind: "review", payload: {card_id, rating,
  reviewed_at, duration_ms}}`. The outbox flushes on the `online` event, on the next
  session start, and on a small periodic retry (the `online` event can be missed —
  sleeping devices, captive portals). A sync failure of any kind (including a
  mid-rating drop) routes the op to the outbox instead of losing it.
- `POST /sync` applies each op in its own transaction: insert a `sync_ops` ledger
  row keyed on unique `op_id` first, then apply via the same `Reviewing::Apply`
  service the rating buttons use (`reviewed_at` comes from the client so offline
  reviews land at the time they actually happened; future timestamps are clamped).
  Already-seen `op_id` → reported as `duplicate` and skipped; `review_logs.sync_op_id`
  has a unique partial index as a second guard. Per-op statuses let the client drop
  anything the server definitively handled (`applied`/`duplicate`/`invalid`) and keep
  the rest for retry. Ops referencing cards the user cannot see are rejected, so a
  stale cached page from another user can never write foreign progress.
- The hand-written service worker (`public/service-worker.js`, no Workbox): HTML
  navigations network-first with cache fallback, cached **per user** (keyed by an
  `X-Anki-User-Id` response header — shared browsers never serve one user's cached
  queue to another; only the most recent user's pages are kept); deck media and
  fingerprinted assets cache-first (a cached full 200 response legally answers
  Range requests, so audio seeking works offline; 206 partials are never cached).
  The study page warms the caches when a session starts: media for every queued
  card, the page itself, and its assets — so offline navigation (new tab, reload)
  still reaches the deck list and study pages, and a cached study page filters out
  cards whose ops are still in the outbox (no double-review before syncing).
- **E2E testing note:** CDP `Network.emulateNetworkConditions` (Selenium
  `network_conditions=`) does **not** block service-worker-context fetches — the
  worker kept hitting the server during "offline" emulation. The tests therefore
  also flip a small test hook in the worker (`test-offline` postMessage, ack'd)
  that forces its offline branches (cache-only pages/assets, network-style
  failures for everything else). No production code sends that message.

## AI deck generation — `Ai::*` (isolated)

**[DECISION 7]** The AI subsystem touches the rest of the app only through ordinary
ActiveRecord models and one job enqueue; it has its own namespace, its own tests with a
scripted fake server, and can be deleted without touching study/import code.

- `Ai::Client` — hand-written OpenAI-compatible client over `Net::HTTP`
  (`POST {base_url}/chat/completions` with `tools`; `GET {base_url}/models`); streaming
  chat (`stream: true`) parses SSE over chunked `read_body` with line buffering — plain
  `Net::HTTP`, no new dependency — and falls back to a plain completion if the server
  ignores `stream`. Config from `ai_settings` (set by `rake ai:config[base_url,api_key]`;
  key encrypted at rest).
- `Ai::Agent::DeckBuilder` — the loop: system prompt (deck-builder persona + tool
  schemas) → model responds (assistant text and/or tool calls) → job executes tools →
  tool results appended → repeat until the model calls `finish` or a turn/tool-call
  budget is hit. Each iteration appends to `ai_generations.transcript`, so the UI is a
  simple poll.
- Tools: `create_deck(name, description)`, `upsert_note_type(name, kind, fields,
  front_template, back_template, css)`, `add_note(note_type, fields, tags)`, `update_note`,
  `delete_note`, `list_notes`, `finish(summary)`. The agent cannot touch existing decks
  or anything outside its own generation — tools are scoped to the deck this one
  generation created. Tool errors are returned as results the model can see and correct
  (only infrastructure errors fail a generation), and the loop is bounded (24 turns).
- `Ai::GenerationJob` (Solid Queue) runs the loop and is safe to re-run; the
  "New AI deck" form (description + model dropdown from the cached `/models` list —
  free-text fallback when the API is unreachable) just enqueues and redirects to the
  generation status page. While pending/running that page polls itself every 2s with a
  plain `Turbo.visit(…, { action: "replace" })` — no framework, no websocket. Progress
  is incremental: the agent streams each turn (`on_delta`) into the transcript via
  `Ai::Generation#log_stream!` — a single in-progress entry replaced in place, throttled
  to one write per second — and `log_assistant!` swaps in the final entry, so polling
  shows live text/tool-call progress instead of one burst at the end. The transcript
  renders as collapsed `<details>` rows (role/tool name in the summary, text or JSON
  inside), auto-scrolled to the bottom, with a status dot: orange while pending/running,
  green when done, red when failed.
- The API key is encrypted at rest with `ActiveSupport::MessageEncryptor` keyed from
  `secret_key_base` (no Rails AR-encryption credentials setup to juggle).
- Tests: a fake OpenAI server (`test/support/fake_openai_server.rb`) — a real local
  HTTP server (Puma hosting a Rack app, no new dependency) serving scripted
  tool-call sequences; when the request asks for `stream: true` it serves real SSE
  (events split mid-line into two chunks to exercise the client's line buffering,
  content/arguments sliced so accumulation is observable). The agent's real Net::HTTP
  path runs end-to-end without
  network; scripted responses can be computed from earlier tool results (exactly what
  a real model does). System tests cover generate → study the deck, API-failure UX
  and unconfigured UX. In tests the queue adapter is :inline (the system-test app
  server runs in a separate process, so the :test adapter's in-memory queue would
  never see its enqueues).

## Frontend strategy

**[DECISION 8] — Keep Turbo (Rails default), everything else vanilla.**
Turbo gives server-rendered pages and link navigation with no hand-rolled fetch code.
The study session itself (`app/javascript/study_session.js`) is deliberately a plain
ES module — no Stimulus, no framework — since it owns reveal/rating/keyboard/audio/
outbox/offline-switch as one cohesive unit and is the piece users depend on most.
Stimulus stayed in the importmap for any future small controllers (none currently).
Removed from the scaffolded app: `solid_cable` (no websockets), `solid_cache`
(default memory store is enough), `jbuilder` (render JSON with `.to_json`/ERB),
`image_processing` + its mini_magick tree (no image variants), `kamal`/`thruster`
(in-place VM deployment, not container deploy — re-add later if needed). PWA manifest
kept (mobile installable); `transition: none` globally; mobile-first minimal CSS,
Anki-like typography.

## Testing strategy

- **Unit**: importer/exporter (synthetic apkg built by test helpers covering revlog,
  cloze, multi-template; **plus** the two real fixtures in a slow `test:fixtures`
  task), template engine, FSRS, sync idempotency, AI agent against the fake server.
- **System/E2E** (headless Chrome, selenium-webdriver — already scaffolded): login,
  import, study session, add card ("add to next"), offline → online sync (Chrome
  DevTools network emulation + the service-worker offline test hook — CDP emulation
  alone does not reach SW-context fetches), export, AI generation (fake server).
  System tests save screenshots to `screenshots/` at key points; committed as evidence.
- CI (`.github/workflows/ci.yml`) keeps brakeman/bundler-audit; test jobs added when
  the suite is real.

## Dependency policy — proposed Gemfile (post-trim)

| Gem | Status | Why |
|---|---|---|
| rails, sqlite3, puma, propshaft, importmap-rails, bootsnap | keep | core stack |
| turbo-rails, stimulus-rails | keep (decision 8) | minimal JS with server rendering |
| solid_queue | keep | background jobs for the AI agent loop |
| bcrypt | **enable** (scaffolded, commented) | password auth |
| tzinfo-data | keep | portability (windows/jruby only) |
| debug, web-console | keep (dev) | debugging |
| rubocop-rails-omakase, brakeman, bundler-audit | keep (dev/test) | quality/security |
| capybara, selenium-webdriver | keep (test) | headless-Chrome E2E |
| solid_cable, solid_cache, jbuilder, image_processing, kamal, thruster | **remove** | unused (see decision 8) |
| anything else | **add nothing** | ZIP via system binaries; AI client via Net::HTTP; FSRS hand-written |

## Key risks / accepted trade-offs

- Schema-11 only for import (covers both fixtures; modern Anki can still export it;
  `.anki21b`/zstd would need a zstd binding — deferred).
- FSRS parameters ship as defaults (no optimizer/training in v1); per-user tuning later.
- Offline sessions resume from the last rendered page; ops always sync. No multi-device
  conflict resolution beyond last-write-wins per card + idempotent op ledger.
- Export maps FSRS→SM-2 columns lossily (as Anki itself does in reverse); re-import into
  Anki re-derives fine, but FSRS parameters don't round-trip.
