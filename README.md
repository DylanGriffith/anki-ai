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
  renderer, and media/audio support.

## Requirements

- Ruby (see `.ruby-version`), Bundler
- SQLite 3
- `zip` / `unzip` binaries on PATH (used for `.apkg` containers — no ZIP gem)
- Google Chrome (for system/E2E tests; headless)

## Setup

```bash
bin/setup                # bundle, db create/migrate
bin/rails "user:create[name=me,password=secret]"   # create a login
bin/dev                  # or: bin/rails server + bin/jobs (Solid Queue worker)
```

### AI configuration (OpenAI-compatible endpoint)

```bash
bin/rails "ai:config[base_url=https://api.openai.com/v1,api_key=sk-...]"
bin/rails ai:refresh_models   # fetch + cache the model list for the UI dropdown
```

The base URL and API key are stored in the database (key encrypted at rest). Any
OpenAI-compatible server works.

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
- [ ] **Step 4 — Offline review + idempotent sync.** Service worker caches the study
      page + media; study page embeds the remaining queue as JSON; vanilla JS runs the
      session when offline and appends rating ops to an IndexedDB outbox. `POST /sync`
      applies ops idempotently (unique op id; replay is a no-op) and returns
      authoritative state. E2E test that goes offline via Chrome DevTools protocol,
      reviews, comes back online, and syncs. Screenshots (incl. offline state).
- [ ] **Step 5 — `.apkg` export.** Hand-written writer: builds a schema-11
      `collection.anki2` in a temp SQLite DB with the requesting user's progress mapped
      back to Anki's SM-2 columns + revlog, zips with media, streams the download.
      Import → export → re-import round-trip unit test. System test with a real Anki
      importable artifact. Screenshots.
- [ ] **Step 6 — AI deck generation.** `rake ai:config` (DB-stored, encrypted key) and
      model list fetch. "New AI Deck" button → description + model select → background
      job (Solid Queue) runs an agent loop against the OpenAI-compatible API with tools
      (create deck, define note type, add/update/delete/list notes, finish). Live
      transcript/status page. Fully isolated in an `Ai::` namespace; tested against a
      scripted fake OpenAI server (no real API in tests). System test + screenshots.
- [ ] **Step 7 — Public decks & polish.** Public/private visibility; browse public
      decks; study someone else's public deck with **your own separate progress**
      (progress rows are per-user from day one, this step exposes the UI). Final E2E
      pass over all flows, full screenshot set, README runbook finalization.

## Non-goals (for now)

- No registration flow (users created via rake task).
- No Anki add-on ecosystem, no note-type sharing across decks, no nested deck management
  UI (subdeck info is preserved on cards; see ARCHITECTURE.md).
- No zstd-compressed `collection.anki21b` import (schema 11 covers both fixtures and any
  deck exported with "support older Anki versions"; can be added later with a zstd dep).
- No deployment automation (app will be upgraded in place on a VM later).
