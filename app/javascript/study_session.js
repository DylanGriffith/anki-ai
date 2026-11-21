// Client-side study session.
//
// The server pre-renders both sides of every queued card into
// #study-session-data. This module runs the whole session — reveal, rating,
// keyboard shortcuts — with no page loads between cards, sends each review to
// the idempotent POST /sync endpoint, and keeps working offline: when the
// network is unavailable reviews accumulate in an IndexedDB outbox and are
// flushed automatically when the connection returns.
//
// Deliberately framework-free vanilla JS (no Stimulus/Turbo dependencies).

const SYNC_ENDPOINT = "/sync"

// Diagnostics + resilience: surface any boot/async failure instead of a
// silently empty study page, and clear the boot flag so turbo:load can retry.
window.__studyErrors = []
window.addEventListener("error", (event) => window.__studyErrors.push(`error: ${event.message}`))
window.addEventListener("unhandledrejection", (event) => window.__studyErrors.push(`rejection: ${event.reason}`))

function boot() {
  const dataEl = document.getElementById("study-session-data")
  const root = document.getElementById("study-session")
  if (!dataEl || !root || root.dataset.booted) return
  root.dataset.booted = "1"
  try {
    const session = new StudySession(root, JSON.parse(dataEl.textContent))
    session.start().catch((error) => window.__studyErrors.push(`start: ${error && error.message || error}`))
    window.__studySession = session // testing hook
  } catch (error) {
    window.__studyErrors.push(`boot: ${error && error.message || error}`)
    delete root.dataset.booted // allow a retry on the next turbo:load
  }
}

class StudySession {
  constructor(root, data) {
    this.root = root
    this.data = data
    this.cardEl = root.querySelector(".study-card")
    this.barEl = root.querySelector(".answer-bar")
    this.statusEl = root.querySelector(".sync-status")
    this.cards = data.cards
    this.index = 0
    this.revealed = false
    this.completed = false
    this.reviewed = 0
    this.pending = 0
    this.synced = 0
    this.offline = !navigator.onLine
    this.ready = false
    this.mediaWarmed = false
    this.shownAt = 0
    this.flushing = false
    this.outbox = new Outbox()
  }

  async start() {
    await this.outbox.open()
    this.ready = true
    // A cached offline page may contain cards that were already reviewed but
    // not yet synced; skip them so no card is reviewed twice before syncing.
    const queued = await this.outbox.reviewedCardIds()
    this.cards = this.data.cards.filter((card) => !queued.has(card.id))
    this.pending = await this.outbox.count()
    this.updateStatus()
    this.render()
    this.flush() // leftover ops from a previous session
    this.warmCaches()
    window.addEventListener("online", () => { this.offline = false; this.flush() })
    window.addEventListener("offline", () => { this.offline = true; this.updateStatus() })
    document.addEventListener("keydown", (event) => this.onKeydown(event))
  }

  // ---- session flow --------------------------------------------------

  render() {
    if (this.index >= this.cards.length) return this.renderComplete()
    const card = this.cards[this.index]
    this.revealed = false
    this.completed = false
    this.shownAt = performance.now()
    this.cardEl.innerHTML = card.question_html
    const box = this.cardEl.querySelector("input.typebox")
    if (box) box.focus()
    this.autoplay()
    this.barEl.innerHTML = ""
    this.barEl.appendChild(this.button("Show Answer", "btn btn--block", () => this.reveal()))
    this.updateStatus()
  }

  reveal() {
    if (this.revealed || this.completed) return
    this.revealed = true
    const card = this.cards[this.index]
    const typed = this.cardEl.querySelector("input.typebox")?.value ?? ""
    this.cardEl.innerHTML = card.answer_html
    this.applyTypedAnswer(card, typed)
    this.autoplay()
    this.barEl.innerHTML = ""
    const labels = ["Again", "Hard", "Good", "Easy"]
    const styles = ["btn btn--danger", "btn btn--secondary", "btn", "btn btn--easy"]
    labels.forEach((label, i) => {
      const btn = this.button(`${label} <small>${card.intervals[i]}</small>`, styles[i], () => this.rate(i + 1))
      btn.name = "rating"
      btn.value = String(i + 1)
      this.barEl.appendChild(btn)
    })
  }

  async rate(rating) {
    if (!this.revealed || this.completed) return
    const card = this.cards[this.index]
    const op = {
      op_id: newOpId(),
      kind: "review",
      payload: {
        card_id: card.id,
        rating: rating,
        duration_ms: Math.round(performance.now() - this.shownAt),
        reviewed_at: new Date().toISOString()
      }
    }
    this.reviewed += 1
    this.index += 1
    if (this.offline || !navigator.onLine) {
      // Count the op before rendering so the complete screen (if this was the
      // last card) shows the right number instead of the previous pending.
      this.pending += 1
      this.render()
      await this.outbox.add(op)
      this.updateStatus()
    } else {
      this.render()
      try {
        await this.handleResults(await syncOps([op]), [op])
      } catch {
        // Network dropped mid-rating: this review still counts, it just syncs later.
        this.offline = true
        await this.outbox.add(op)
        this.pending += 1
        if (this.completed) this.renderComplete() // replace the "synced, reloading" message
        this.updateStatus()
      }
    }
  }

  renderComplete() {
    this.completed = true
    this.barEl.innerHTML = ""
    const done = document.createElement("a")
    done.href = this.data.done_url
    done.className = "btn btn--secondary btn--block"
    done.textContent = "Back to deck"
    this.barEl.appendChild(done)

    const plural = (n) => `${n} review${n === 1 ? "" : "s"}`
    if (this.reviewed > 0 && (this.pending > 0 || this.offline)) {
      this.cardEl.innerHTML = `
        <div class="card">
          <p><strong>Session complete.</strong> ${this.reviewed} card${this.reviewed === 1 ? "" : "s"} reviewed.</p>
          <p class="muted">${plural(this.pending)} saved offline — they will sync automatically when you are back online.</p>
        </div>`
    } else if (this.reviewed > 0) {
      this.cardEl.innerHTML = `
        <div class="card">
          <p><strong>Session complete.</strong> ${this.reviewed} card${this.reviewed === 1 ? "" : "s"} reviewed and synced. Reloading…</p>
        </div>`
      setTimeout(() => { if (!this.offline && this.pending === 0) location.reload() }, 1200)
    } else {
      this.cardEl.innerHTML = `
        <div class="card">
          <p><strong>All caught up.</strong> Every card in this queue was already reviewed offline and is waiting to sync.</p>
        </div>`
    }
    this.updateStatus()
  }

  // {{type:Field}} cards: build the typed-answer comparison at reveal time
  // from the value the user typed and the expected answer the server sent.
  applyTypedAnswer(card, typed) {
    if (card.typed_answer === undefined) return
    const marks = this.cardEl.querySelectorAll(".typed")
    if (!marks.length) return
    const html = typed === card.typed_answer
      ? `<div class="typed typed--ok">${escapeHtml(typed)}</div>`
      : `<div class="typed typed--bad">${escapeHtml(typed)}</div>` +
        `<div class="typed typed--correct">${escapeHtml(card.typed_answer)}</div>`
    marks[0].outerHTML = html
    marks.forEach((mark, i) => { if (i > 0) mark.remove() })
  }

  // ---- sync ----------------------------------------------------------

  async flush() {
    if (this.flushing) return
    this.flushing = true
    try {
      const ops = await this.outbox.all()
      if (ops.length) {
        try {
          const results = await syncOps(ops)
          this.offline = false
          await this.handleResults(results, ops)
        } catch {
          this.offline = true
        }
      }
    } finally {
      this.flushing = false
      this.pending = await this.outbox.count()
      this.updateStatus()
      // Ops still queued: keep retrying periodically — the online event can be
      // missed (sleeping devices, captive portals), and one cheap failed fetch
      // every few seconds heals it.
      if (this.pending > 0) this.scheduleRetry()
      // Finished offline, connection came back: reload into the server's
      // authoritative queue.
      if (this.completed && this.pending === 0 && !this.offline && this.reviewed > 0) {
        setTimeout(() => location.reload(), 1200)
      }
    }
  }

  scheduleRetry() {
    if (this.retryTimer) return
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      if (this.pending > 0) this.flush()
    }, 5000)
  }

  async handleResults(results, ops) {
    const byId = new Map(results.map((r) => [r.op_id, r.status]))
    const definitive = ["applied", "duplicate", "invalid"]
    const removals = ops
      .filter((op) => definitive.includes(byId.get(op.op_id)))
      .map((op) => this.outbox.remove(op.op_id))
    await Promise.all(removals)
    // Every op that got a definitive answer from the server is fully synced
    // (applied now, or already applied — the ledger makes both equivalent).
    this.synced += removals.length
    const dropped = ops.filter((op) => byId.get(op.op_id) === "invalid")
    if (dropped.length) console.warn("sync dropped invalid ops:", dropped)
  }

  updateStatus() {
    if (!this.statusEl) return
    const plural = (n) => `${n} review${n === 1 ? "" : "s"}`
    if (this.pending > 0) {
      this.statusEl.hidden = false
      this.statusEl.textContent = this.offline
        ? `Offline — ${plural(this.pending)} saved, will sync when back online`
        : `${plural(this.pending)} pending sync…`
    } else if (this.offline) {
      this.statusEl.hidden = false
      this.statusEl.textContent = "Offline — reviews will sync when back online"
    } else {
      this.statusEl.hidden = true
    }
  }

  // ---- offline caches ------------------------------------------------

  // Warm the service worker caches so this session survives going offline:
  // media for every queued card, plus this page and its assets so an offline
  // navigation (new tab, reload) still reaches them.
  async warmCaches() {
    if ("serviceWorker" in navigator) {
      try { await navigator.serviceWorker.ready } catch { /* no SW */ }
    }
    if (!navigator.onLine) return
    await Promise.all([this.warmMedia(), this.warmPage()])
    this.pageWarmed = true
  }

  async warmMedia() {
    const urls = new Set()
    const parser = new DOMParser()
    for (const card of this.data.cards) {
      for (const html of [card.question_html, card.answer_html]) {
        const doc = parser.parseFromString(html, "text/html")
        doc.querySelectorAll("[src]").forEach((el) => {
          const src = el.getAttribute("src")
          if (src && /^\/decks\/\d+\/media\//.test(src)) urls.add(src)
        })
      }
    }
    const queue = [...urls]
    const worker = async () => {
      while (queue.length) {
        const url = queue.shift()
        try { await fetch(url) } catch { /* went offline mid-warm */ }
      }
    }
    await Promise.all([worker(), worker(), worker(), worker()])
    this.mediaWarmed = true
  }

  async warmPage() {
    // The page itself: ask for HTML so the service worker treats it as a
    // navigation and caches it under the current user.
    try { await fetch(location.pathname + location.search, { headers: { accept: "text/html" } }) } catch {}
    // Assets already loaded by this page (propshaft fingerprints them, so
    // they are immutable and safe to cache).
    const assets = new Set()
    document.querySelectorAll('link[rel="stylesheet"]').forEach((link) => {
      if (link.href && link.href.startsWith(location.origin)) assets.add(link.href)
    })
    performance.getEntriesByType("resource").forEach((entry) => {
      if (entry.name.startsWith(location.origin + "/assets/")) assets.add(entry.name)
    })
    for (const url of assets) {
      try { await fetch(url) } catch {}
    }
  }

  // ---- small helpers -------------------------------------------------

  autoplay() {
    this.cardEl.querySelectorAll("audio[data-autoplay]").forEach((audio) => {
      audio.play().catch(() => {}) // autoplay policies; best-effort like Anki
    })
  }

  button(labelHtml, className, onClick) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = className
    btn.innerHTML = labelHtml
    btn.addEventListener("click", onClick)
    return btn
  }

  onKeydown(event) {
    if (this.completed) return
    if (event.key === "Enter" && event.target.classList?.contains("typebox")) {
      event.preventDefault()
      this.reveal()
      return
    }
    if (event.target.closest?.("input, textarea, select")) return
    const ratingKey = event.key.match(/^[1-4]$/)
    if (ratingKey && this.revealed) {
      const btn = this.barEl.querySelector(`button[name="rating"][value="${ratingKey[0]}"]`)
      if (btn) { event.preventDefault(); btn.click() }
      return
    }
    if ((event.key === " " || event.key === "Enter") && !this.revealed) {
      const btn = this.barEl.querySelector("button")
      if (btn) { event.preventDefault(); btn.click() }
    }
  }
}

// POST /sync with CSRF token; resolves to the per-op results array.
async function syncOps(ops) {
  const token = document.querySelector('meta[name="csrf-token"]')?.content || ""
  const response = await fetch(SYNC_ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": token
    },
    body: JSON.stringify({ ops })
  })
  if (!response.ok) throw new Error(`sync failed (${response.status})`)
  const body = await response.json()
  return body.results || []
}

// IndexedDB outbox of ops waiting to sync. Keyed by op_id; rows carry
// queued_at so batches flush in review order.
class Outbox {
  async open() {
    this.db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("anki-offline", 1)
      request.onupgradeneeded = () => {
        const db = request.result
        const store = db.createObjectStore("outbox", { keyPath: "op_id" })
        store.createIndex("queued_at", "queued_at")
      }
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  store(mode) {
    return this.db.transaction("outbox", mode).objectStore("outbox")
  }

  wrap(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
  }

  async add(op) {
    return this.wrap(this.store("readwrite").put({ ...op, queued_at: Date.now() }))
  }

  async remove(opId) {
    return this.wrap(this.store("readwrite").delete(opId))
  }

  async all() {
    const rows = await this.wrap(this.store("readonly").getAll())
    return rows.sort((a, b) => a.queued_at - b.queued_at)
  }

  async count() {
    return this.wrap(this.store("readonly").count())
  }

  async reviewedCardIds() {
    const rows = await this.all()
    return new Set(rows.filter((r) => r.kind === "review").map((r) => r.payload.card_id))
  }
}

function newOpId() {
  return crypto.randomUUID ? crypto.randomUUID() : `op-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
}

// Boot last: class declarations are in the temporal dead zone until the module
// finishes evaluating, so the initial call must come after them.
boot()
document.addEventListener("turbo:load", boot)
