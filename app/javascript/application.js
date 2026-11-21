// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap
import "@hotwired/turbo-rails"
import "controllers"
import "study_session"

// Track turbo's visit lifecycle so tests (and debugging) can wait for a
// turbo visit to finish rendering instead of interacting with a mid-swap DOM.
window.__turboBusy = false
document.addEventListener("turbo:before-visit", () => { window.__turboBusy = true })
document.addEventListener("turbo:load", () => { window.__turboBusy = false })

// Offline study: register the service worker that caches study pages,
// their media and assets (public/service-worker.js).
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/service-worker.js").catch(() => {})
}
