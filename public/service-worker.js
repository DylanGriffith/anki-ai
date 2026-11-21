// Service worker for offline study.
//
// - HTML navigations: network-first with cache fallback, cached per user
//   (keyed by the X-Anki-User-Id header the app sets), so an offline tab can
//   still reach the deck list and study pages. Only the most recent user's
//   pages are kept, so shared browsers never leak one user's queue to another.
// - Deck media: cache-first. Media is immutable in practice (a re-import
//   recreates the deck); a cached full response legally answers Range
//   requests, so audio seeking keeps working offline.
// - Fingerprinted assets (/assets/...): cache-first, filled on demand and by
//   the study page's cache warm-up.

const VERSION = "v1"
const ASSET_CACHE = `anki-assets-${VERSION}`
const MEDIA_CACHE = `anki-media-${VERSION}`
const PAGE_PREFIX = "anki-pages-u"

self.addEventListener("install", () => self.skipWaiting())

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keep = [ASSET_CACHE, MEDIA_CACHE]
    const names = await caches.keys()
    await Promise.all(
      names.filter((name) => !keep.includes(name) && !name.startsWith(PAGE_PREFIX))
           .map((name) => caches.delete(name))
    )
    await clients.claim()
  })())
})

// TEST HOOK (no production sender): CDP network emulation does not reach
// service-worker-context fetches, so E2E tests ask the worker itself to
// behave as if the network were down — serving only from cache and failing
// everything else, exactly the branches real offline exercises.
self.__testOffline = false
self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "test-offline") {
    self.__testOffline = !!event.data.offline
    if (event.source) event.source.postMessage({ type: "test-offline-ack", offline: self.__testOffline })
  }
})

function offline() { return self.__testOffline === true }

self.addEventListener("fetch", (event) => {
  const request = event.request
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return // remote images/audio: passthrough

  if (offline()) {
    // Serve what is cached; fail everything else like a dead network would.
    if (request.method !== "GET") { event.respondWith(Promise.reject(new TypeError("offline"))); return }
    if (isHtmlRequest(request)) { event.respondWith(servePageFromCache(request)); return }
    event.respondWith(serveAssetFromCache(request, isMediaRequest(url) ? MEDIA_CACHE : ASSET_CACHE))
    return
  }

  if (request.method !== "GET") return // POST /sync, form submits: network only

  if (isHtmlRequest(request)) {
    event.respondWith(handlePage(request))
  } else if (isMediaRequest(url)) {
    event.respondWith(handleMedia(request))
  } else if (isAssetRequest(url)) {
    event.respondWith(handleAsset(request))
  }
})

function isHtmlRequest(request) {
  if (request.mode === "navigate") return true
  return (request.headers.get("accept") || "").includes("text/html")
}

function isMediaRequest(url) {
  return /^\/decks\/\d+\/media\//.test(url.pathname)
}

function isAssetRequest(url) {
  return url.pathname.startsWith("/assets/") ||
         /\.(?:css|mjs|js|woff2?|png|jpe?g|gif|svg|webp|ico)$/i.test(url.pathname)
}

// Offline mode (test hook): pages come from the cache or the fallback page.
async function servePageFromCache(request) {
  const cached = await matchPage(request)
  return cached || offlinePage()
}

// Offline mode (test hook): cached assets/media, or a network-style failure.
async function serveAssetFromCache(request, cacheName) {
  const cache = await caches.open(cacheName)
  const cached = await cache.match(request, { ignoreVary: true })
  if (cached) return cached
  throw new TypeError("offline")
}

async function handlePage(request) {
  try {
    const fresh = await fetch(request)
    if (fresh && fresh.status === 200) await cachePage(request, fresh)
    return fresh
  } catch {
    const cached = await matchPage(request)
    if (cached) return cached
    return offlinePage()
  }
}

async function cachePage(request, response) {
  // Never cache a redirect: session-expired navigations land on /login and
  // would otherwise be replayed for the study URL offline.
  if (new URL(response.url).pathname !== new URL(request.url).pathname) return
  const user = response.headers.get("X-Anki-User-Id") || "anon"
  const cache = await caches.open(PAGE_PREFIX + user)
  await cache.put(request, response.clone())
  // Single-user-at-a-time pages, so offline navigations can never serve
  // another user's cached queue.
  const names = await caches.keys()
  await Promise.all(
    names.filter((name) => name.startsWith(PAGE_PREFIX) && name !== PAGE_PREFIX + user)
         .map((name) => caches.delete(name))
  )
}

async function matchPage(request) {
  const names = await caches.keys()
  for (const name of names) {
    if (!name.startsWith(PAGE_PREFIX)) continue
    const cached = await caches.open(name).then((cache) => cache.match(request, { ignoreVary: true }))
    if (cached) return cached
  }
  return null
}

async function handleMedia(request) {
  const cache = await caches.open(MEDIA_CACHE)
  const cached = await cache.match(request, { ignoreVary: true })
  if (cached) return cached // full 200 responses may answer Range requests
  const fresh = await fetch(request)
  // Only cache complete responses, never 206 partial content.
  if (fresh && fresh.status === 200 && !request.headers.has("range")) {
    await cache.put(request, fresh.clone())
  }
  return fresh
}

async function handleAsset(request) {
  const cache = await caches.open(ASSET_CACHE)
  const cached = await cache.match(request, { ignoreVary: true })
  if (cached) return cached
  const fresh = await fetch(request)
  if (fresh && fresh.status === 200) await cache.put(request, fresh.clone())
  return fresh
}

function offlinePage() {
  return new Response(
    `<!DOCTYPE html><html><head><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Offline</title></head>` +
      `<body style="font-family:system-ui;padding:2rem;max-width:34rem;margin:auto">` +
      `<h1>You're offline</h1>` +
      `<p>This page wasn't cached for offline use. Cached study pages still work — go back and open your deck from the deck list.</p>` +
      `</body></html>`,
    { status: 503, headers: { "Content-Type": "text/html; charset=utf-8" } }
  )
}
