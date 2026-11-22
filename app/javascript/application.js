// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap
import "@hotwired/turbo-rails"
import "controllers"
import "study_session"

// Track turbo's visit lifecycle so tests (and debugging) can wait for a
// turbo visit to finish rendering instead of interacting with a mid-swap DOM.
window.__turboBusy = false
document.addEventListener("turbo:before-visit", () => { window.__turboBusy = true })
document.addEventListener("turbo:load", () => { window.__turboBusy = false })

// AI generation status page: poll while the generation is in progress.
// Inline per-page <script> blocks are not re-executed on Turbo renders, so
// the poller lives here and re-arms on every turbo:load while the page
// carries an in-progress status marker. A plain Turbo replace-visit — no
// frameworks, no websocket.
let generationPollTimer = null
document.addEventListener("turbo:load", () => {
  // Keep the newest transcript entry in view while it grows.
  const box = document.querySelector(".transcript")
  if (box) box.scrollTop = box.scrollHeight

  const status = document.querySelector(".generation-status")?.dataset.generationStatus
  if (status !== "pending" && status !== "running") return

  if (generationPollTimer) clearTimeout(generationPollTimer)
  generationPollTimer = setTimeout(() => {
    if (window.Turbo) { Turbo.visit(window.location.href, { action: "replace" }) }
    else { window.location.reload() }
  }, 2000)
})

// Offline study: register the service worker that caches study pages,
// their media and assets (public/service-worker.js).
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/service-worker.js").catch(() => {})
}
