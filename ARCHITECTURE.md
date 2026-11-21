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
 │ Study session (offline mode)  │   │  Reviewing:: apply/schedule    │  └──────┬───────┘
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
- Visibility: `Deck.where(visibility: :public).or(Deck.where(user:))` for indexes.
  Public decks are read/study-only for non-owners (no editing others' content).

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

**Writer** (`Anki::Apkg::Writer`): export = build a schema-11 `collection.anki2` in a
temp SQLite DB (notes with guids, cards with the requesting user's progress mapped
FSRS→SM-2 columns: due/ivl/factor/type/queue, revlog with ease 1-4), `zip` it with media
members + `media` manifest, stream via `send_file`, cleanup. Schema 11 is importable by
every Anki in circulation. The guids make export → Anki → re-import idempotent-ish,
and our own round-trip (import → export → import) is a unit test.

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

**[DECISION 6] — Embedded queue + SW cache + IndexedDB outbox.**

- Every study page render embeds the remaining session queue as JSON in the page
  (card fields, template, audio URLs — the session is capped by daily limits, so this
  is small). Online use needs zero JS: answering is a plain form POST; the server
  applies the review via `Reviewing::Apply` and re-renders the next card (and fresh
  embedded queue).
- The service worker (hand-written, ~100 lines) precaches the study page (network-first,
  cache fallback) and media (cache-first, opaque) when a study session starts. It also
  serves the app shell for reloads while offline.
- When `navigator.onLine` is false (or a POST fails), the vanilla study script takes
  over: it renders cards from the embedded queue, records each answer as an
  **op** in IndexedDB: `{op_id: uuid, kind: "review", card_id, rating, reviewed_at,
  duration_ms}`. A tiny outbox module flushes `POST /sync` on `online` event / next
  visit.
- `POST /sync` wraps each op in its own transaction: insert `sync_ops` row keyed on
  `op_id` (unique) — if it already exists, skip (idempotent replay). Apply via the same
  `Reviewing::Apply` service the online path uses. Response returns the authoritative
  card states so the client can reconcile. Sync is safe to call repeatedly/partially.

## AI deck generation — `Ai::*` (isolated)

**[DECISION 7]** The AI subsystem touches the rest of the app only through ordinary
ActiveRecord models and one job enqueue; it has its own namespace, its own tests with a
scripted fake server, and can be deleted without touching study/import code.

- `Ai::Client` — hand-written OpenAI-compatible client over `Net::HTTP`
  (`POST {base_url}/chat/completions` with `tools`; `GET {base_url}/models`). Config
  from `ai_settings` (set by `rake ai:config[base_url,api_key]`; key encrypted at rest).
- `Ai::Agent::DeckBuilder` — the loop: system prompt (deck-builder persona + tool
  schemas) → model responds (assistant text and/or tool calls) → job executes tools →
  tool results appended → repeat until the model calls `finish` or a turn/tool-call
  budget is hit. Each iteration appends to `ai_generations.transcript`, so the UI is a
  simple poll.
- Tools: `create_deck(name, description, public)`, `upsert_note_type(name, fields,
  front_template, back_template, css)`, `add_note(fields, tags)`, `update_note`,
  `delete_note`, `list_notes`, `finish(summary)`. The agent cannot touch existing decks
  or anything outside its own generation.
- `AiDeckGenerationJob` (Solid Queue) runs the loop; the "New AI Deck" form (description
  + model dropdown from cached `/models` list) just enqueues and redirects to the
  generation status page, which polls (Turbo frame refresh, 2s) until done/failed.
- Tests: a fake OpenAI server (small Rack app mounted in tests) serves scripted
  tool-call sequences; the agent runs end-to-end without network. E2E system test uses
  the same fake so the real UI flow is covered.

## Frontend strategy

**[DECISION 8] — Keep Turbo + Stimulus (Rails defaults), everything else vanilla.**
Turbo gives server-rendered polling/updates with no hand-rolled fetch code; Stimulus
(≈4 KB) is just an organizer for the ~5 small behaviors we need (SW registration,
outbox flush button, study keyboard shortcuts, audio autoplay). Removed from the
scaffolded app: `solid_cable` (no websockets), `solid_cache` (default memory store is
enough), `jbuilder` (render JSON with `.to_json`/ERB), `image_processing` + its
mini_magick tree (no image variants), `kamal`/`thruster` (in-place VM deployment, not
container deploy — re-add later if needed). PWA manifest kept (mobile installable);
`transition: none` globally; mobile-first minimal CSS, Anki-like typography.

## Testing strategy

- **Unit**: importer/exporter (synthetic apkg built by test helpers covering revlog,
  cloze, multi-template; **plus** the two real fixtures in a slow `test:fixtures`
  task), template engine, FSRS, sync idempotency, AI agent against the fake server.
- **System/E2E** (headless Chrome, selenium-webdriver — already scaffolded): login,
  import, study session, add card ("add to next"), offline → online sync (Chrome
  DevTools protocol network emulation), export, AI generation (fake server). System
  tests save screenshots to `screenshots/` at key points; committed as evidence.
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
