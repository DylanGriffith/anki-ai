# Anki AI

A self-hosted, multi-user Anki-compatible flashcard web app written in Ruby on Rails.

Study decks (including your own imported from Anki `.apkg` files with progress preserved),
review them with an FSRS scheduler, review **offline** with a service worker and an
idempotent sync queue, export decks back to `.apkg`, and generate brand-new decks with an
AI agent that has tools to build a deck from a description.

- **Stack**: Rails 8.1, SQLite, Solid Queue, propshaft, import maps. Minimal JS (vanilla
  modules + service worker; no SPA framework, no animation).
- **Scheduling**: hand-written FSRS (see `ARCHITECTURE.md`).
- **Anki compatibility**: hand-written `.apkg` import/export (schema 11), template
  renderer, and media/audio support. Modern Anki 23.10+ exports (zstd-compressed
  `collection.anki21b`, schema 18) import too — via a Fiddle binding to the system
  libzstd, no gem.

## Requirements

- Ruby (see `.ruby-version`), Bundler
- SQLite 3
- `zip` / `unzip` binaries on PATH (used for `.apkg` containers — no ZIP gem)
- Google Chrome (for system/E2E tests; headless)

## Setup

```bash
bin/setup                # bundle, db create/migrate
bin/rails "user:create[name=me,password=secret]"   # create a login
bin/rails server         # add SOLID_QUEUE_IN_PUMA=true (or run bin/jobs) for AI deck generation
```

### AI configuration (OpenAI-compatible endpoint)

```bash
bin/rails "ai:config[base_url=https://api.openai.com/v1,api_key=sk-...]"
bin/rails ai:models   # fetch + cache the model list for the UI dropdown
```

The base URL and API key are stored in the database (key encrypted at rest with a key
derived from the app's `secret_key_base` — keep the same secret if you restore a
database backup, or the stored key becomes unreadable). Any OpenAI-compatible server
works: OpenAI, OpenRouter, LM Studio, Ollama's compatibility layer, …
AI deck generation runs as a Solid Queue job — run the worker with
`SOLID_QUEUE_IN_PUMA=true bin/rails server` (single process) or `bin/jobs`.

## Test suite

```bash
bin/rails test             # unit tests (fast, synthetic fixtures)
bin/rails test:fixtures    # full .apkg fixture import verification (slow, real decks)
bin/rails test:system      # E2E against headless Chrome (writes screenshots/)
```

- `fixtures/` contains two real decks that must import cleanly:
  `Ultimate_Geography_v53.apkg` (images, 4 card templates) and
  `5000_most_frequently_used_French_words_v_60.apkg` (15k notes, deep subdecks, audio).
- `screenshots/` stores screenshots taken during system tests and manual verification,
  committed to the repo as evidence of each completed step.

## Iterative plan

Each step ends with: working code, tests, screenshots where there is UI, a git commit,
and a check-in for approval before the next step.

- [x] **Step 0 — Plan & architecture.** This README plan + `ARCHITECTURE.md`. No code.
      *(awaiting plan approval)*
- [x] **Step 1 — Foundation.** Trim dependencies to the approved set. Core schema
      (users, decks, note types, notes, cards, media files). Username/password login
      (bcrypt, session cookie), `user:create` rake task. Minimal app shell: deck list,
      new deck, login screen. System test for login + deck creation; screenshots.
- [x] **Step 2 — Anki `.apkg` import.** Hand-written reader (`lib/anki`): unzip, read
      schema-11 collection (models/decks/notes/cards/revlog/media manifest), import with
      progress, stream media to storage. Hand-written Anki template renderer
      (`{{Field}}`, conditionals, cloze, hints, type-in-answer). Media serving controller
      with correct content types + HTTP Range for audio. Import UI (file upload).
      Unit tests against both real fixtures + synthetic edge-case fixtures.
      Screenshots of imported decks.
- [x] **Step 3 — Study flow + FSRS.** Hand-written FSRS scheduler — **FSRS-6** (see
      ARCHITECTURE.md decision 5): new/learning/review/relearning queues, same-day
      short-term stability, interval fuzz, daily limits. Study session page
      (server-rendered, minimal JS), answer buttons (Again/Hard/Good/Easy), audio
      autoplay, card templates rendered.
      Add-card form with **"add to next"** checkbox (jumps the queue instead of
      appending). Unit tests for FSRS + system tests for a full study session.
      Screenshots.
- [x] **Step 4 — Offline review + idempotent sync.** The study page serializes the
      whole queue (both sides pre-rendered, per-rating intervals, typed-answer
      expectations) as JSON and a vanilla-JS session runs it entirely client-side —
      the same code path online and offline. Reviews go to `POST /sync` immediately
      when online; offline they queue in an IndexedDB outbox that flushes on
      reconnect. `sync_ops` is a unique-op-id ledger so replays are no-ops (double
      flushes, retries, duplicated submissions all collapse). A service worker
      caches study pages (per-user), deck media and assets so offline tabs still
      reach the deck list and study pages. E2E: Chrome DevTools offline emulation +
      a service-worker test hook (CDP emulation doesn't reach SW-context fetches),
      review offline, offline navigation, reconnect, idempotent replay. Screenshots
      (incl. offline state).
- [x] **Step 5 — `.apkg` export.** Hand-written writer: builds a schema-11
      `collection.anki2` in a temp SQLite DB with the requesting user's progress mapped
      back to Anki's SM-2 columns + revlog, zips with media, streams the download.
      Import → export → re-import round-trip unit test. System test with a real Anki
      importable artifact. Screenshots.
      Done: `lib/anki/apkg/schema11_writer.rb` (full schema-11 tables/indexes, csum via
      crc32, JSON media manifest) + `Decks::Export` (inverse of Import's SM-2↔FSRS
      mappings: difficulty↔factor, due day numbers from the deck's `crt`, learning
      steps as epoch-seconds dues, revlog ids from review timestamps with same-ms
      collision guard; subdecks rebuilt from `anki_subdeck` names under the deck's
      current name, stable across renames/round-trips; in-app-created objects get ids
      in Anki's real id spaces, imported ones keep their original ids). Streaming
      download with tempfile cleanup; the export button on the deck page. Round-trip
      unit tests (content, progress, media, double round-trip stability) + system
      test (download → inspect archive → re-import through the UI). Screenshots:
      `step5_export_button`, `step5_reimported`.
- [x] **Step 6 — AI deck generation.** `rake ai:config` (DB-stored, encrypted key) and
      model list fetch. "New AI Deck" button → description + model select → background
      job (Solid Queue) runs an agent loop against the OpenAI-compatible API with tools
      (create deck, define note type, add/update/delete/list notes, finish). Live
      transcript/status page. Fully isolated in an `Ai::` namespace; tested against a
      scripted fake OpenAI server (no real API in tests). System test + screenshots.
      Done: `Ai::Client` (hand-written Net::HTTP chat/models client), `Ai::Agent::DeckBuilder`
      (bounded agent loop with 7 tools, tool errors are recoverable results, transcript
      journaled per step), `Ai::GenerationJob` (Solid Queue; idempotent re-runs), models
      dropdown cached in `ai_settings` with live refresh + fallback. The fake server
      (`test/support/fake_openai_server.rb`) is a real local HTTP server (Puma) serving
      scripted responses — the agent's real HTTP path is exercised. System test covers
      generate → study the deck, API failure UX, and unconfigured UX. Screenshots:
      `step6_new_ai_deck_button`, `step6_ai_form`, `step6_ai_done`, `step6_generated_deck`,
      `step6_generated_deck_study`, `step6_ai_failed`.
- [x] **Step 7 — Public decks & polish.** Public/private visibility; browse public
      decks; study someone else's public deck with **your own separate progress**
      (progress rows are per-user from day one, this step exposes the UI). Final E2E
      pass over all flows, full screenshot set, README runbook finalization.
      Done: "Browse public decks" page (everyone's public decks, owner attribution,
      your own due/new counts on them), one-click study straight from it. Deck edit
      form (name/description/visibility/daily limits) with owner-only write guards on
      details, cards, add-card, edit, delete. Public decks are readable, studyable,
      browsable and **exportable with the requester's own progress** everywhere
      (study/media/cards/controllers all resolve through `Deck.visible_to`);
      private decks 404 for everyone else. Full suite green: 152 runs
      (unit + integration + system incl. two-user public-deck E2E). Screenshots:
      `step7_owner_deck_public`, `step7_browse_public_decks`, `step7_reading_public_deck`.

## Non-goals (for now)

- No registration flow (users created via rake task).
- No Anki add-on ecosystem, no note-type sharing across decks, no nested deck management
  UI (subdeck info is preserved on cards; see ARCHITECTURE.md).
- No deployment automation (app will be upgraded in place on a VM later).
