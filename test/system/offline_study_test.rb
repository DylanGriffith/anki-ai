require "application_system_test_case"

# Step 4 E2E: offline review + idempotent sync.
#
# Chrome DevTools network emulation takes the page offline; the client-side
# session keeps reviewing from the pre-rendered queue, ops pile up in the
# IndexedDB outbox, the service worker serves cached pages and media for
# offline navigations, and going back online flushes the outbox through the
# idempotent POST /sync ledger.
class OfflineStudyTest < ApplicationSystemTestCase
  include StudySystemHelpers

  def go_offline
    # CDP emulation blocks page-context requests, but NOT service-worker
    # fetches — so also flip the worker's test hook (see
    # public/service-worker.js) to make the SW itself behave offline.
    page.driver.browser.network_conditions = {
      offline: true, latency: 0, download_throughput: 0, upload_throughput: 0
    }
    set_service_worker_offline(true)
  end

  def go_online
    page.driver.browser.network_conditions = {
      offline: false, latency: 0, download_throughput: 0, upload_throughput: 0
    }
    set_service_worker_offline(false)
  end

  # Asks the controlling service worker to enter/leave its offline behavior
  # and waits for the ack so the state change has definitely landed.
  def set_service_worker_offline(state)
    ack = page.evaluate_async_script(<<~JS, state)
      const state = arguments[0]
      const done = arguments[arguments.length - 1]
      const worker = navigator.serviceWorker.controller
      if (!worker) { done("no-controller"); return }
      navigator.serviceWorker.addEventListener("message", (event) => {
        if (event.data && event.data.type === "test-offline-ack") done("acked")
      }, { once: true })
      worker.postMessage({ type: "test-offline", offline: state })
    JS
    assert_equal "acked", ack, "service worker should acknowledge offline mode"
  end

  teardown do
    # CDP network emulation is browser state; reset it so it cannot leak
    # into the next test.
    page.driver.browser.delete_network_conditions
  rescue StandardError
    nil
  end

  test "study offline, queue reviews in the outbox, sync on reconnect" do
    deck = login_and_import

    # --- online: load the study page and warm the offline caches ---------
    visit study_deck_path(deck)
    assert_text "hello"
    wait_until_js("window.__studySession && window.__studySession.ready")
    wait_until_js("window.__studySession && window.__studySession.mediaWarmed")
    wait_until_js("window.__studySession && window.__studySession.pageWarmed")
    evidence("step4_online_session_ready")

    # Visit the deck list while online so the service worker caches it too;
    # the study page's warm-up has already cached the page, assets and media.
    visit decks_path
    assert_text "Study Test"
    visit study_deck_path(deck)
    assert_text "hello"
    wait_until_js("window.__studySession && window.__studySession.ready")
    wait_until_js("window.__studySession && window.__studySession.mediaWarmed")
    wait_until_js("window.__studySession && window.__studySession.pageWarmed")

    # --- offline: the session keeps running from the embedded queue ------
    go_offline
    settle

    # Reveal works with no server round-trip
    click_submit("Show Answer")
    assert_text "bonjour"
    assert_selector "button[name='rating'][value='3']", text: /Good/
    evidence("step4_offline_reveal")

    # Rate all three cards; every review lands in the outbox
    click_rating(3)
    assert_text "dog"
    click_submit("Show Answer")
    click_rating(4)
    assert_text "water"
    click_submit("Show Answer")
    assert_text "l'eau"
    click_rating(3)

    # The session ends with a clear offline state, not a network error
    assert_text "Session complete"
    assert_text "3 reviews saved offline"
    assert_equal 3, page.evaluate_script("window.__studySession.pending")
    assert_equal true, page.evaluate_script("window.__studySession.offline")
    evidence("step4_offline_complete")

    # Media is served from the service worker cache while offline
    media_from_cache = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      fetch("/decks/" + window.__studySession.data.deck_id + "/media/water.mp3")
        .then((response) => done(response.ok))
        .catch(() => done(false))
    JS
    assert media_from_cache, "deck media should be served from the cache offline"

    # --- offline navigation: cached pages still reach the deck list and study
    visit decks_path
    assert_text "Study Test"
    visit study_deck_path(deck)
    assert_text "Study Test" # page header from the cached study page
    # The cached queue knows these cards were already reviewed offline
    wait_until_js("window.__studySession && window.__studySession.ready")
    assert_equal 3, page.evaluate_script("window.__studySession.pending")
    assert_text "All caught up"
    evidence("step4_offline_navigation")

    # --- back online: the outbox flushes through the idempotent ledger ---
    go_online
    settle
    wait_until_js("window.__studySession && window.__studySession.pending === 0")

    assert_equal 3, SyncOp.count
    assert_equal 3, ReviewLog.count
    assert_equal 3, ReviewLog.where.not(sync_op_id: nil).pluck(:sync_op_id).uniq.length
    assert CardState.exists?(state: :review) # Easy rating graduated a card
    assert_equal 3, ReviewLog.where(card_id: deck.cards.pluck(:id)).count
    evidence("step4_synced")

    # Nothing double-applies when the page reloads with the outbox empty
    visit study_deck_path(deck)
    assert_text "No cards ready right now"
    assert_text "3 reviews, 3 new cards"
    assert_equal 3, SyncOp.count
    assert_equal 3, ReviewLog.count
    evidence("step4_synced_waiting_screen")
  end

  test "replayed sync ops are duplicates, not double reviews" do
    deck = login_and_import
    card = deck.cards.order(:position, :id).first

    visit study_deck_path(deck)
    wait_until_js("window.__studySession && window.__studySession.ready")

    # Rate one card online: it syncs immediately
    click_submit("Show Answer")
    click_rating(3)
    wait_until_js("window.__studySession && window.__studySession.synced >= 1")
    assert_equal 1, ReviewLog.count
    op_id = ReviewLog.last.sync_op_id
    assert_not_nil op_id

    # Replay the exact op the server already applied: it is rejected as a
    # duplicate and no second review is recorded.
    replayed = page.evaluate_async_script(<<~JS, op_id, card.id)
      const opId = arguments[0];
      const cardId = arguments[1];
      const done = arguments[arguments.length - 1];
      const meta = document.querySelector('meta[name="csrf-token"]');
      const token = meta ? meta.content : "";
      fetch("/sync", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": token
        },
        body: JSON.stringify({ ops: [ {
          op_id: opId,
          kind: "review",
          payload: { card_id: cardId, rating: 3,
                     reviewed_at: new Date().toISOString(), duration_ms: 100 }
        } ] })
      })
        .then((response) => response.json())
        .then((body) => done(JSON.stringify(body)))
        .catch((error) => done("error: " + error.message))
    JS
    assert_equal 1, ReviewLog.count
    assert_equal 1, SyncOp.count
    result = JSON.parse(replayed)
    assert_equal 1, result["duplicates"]
    assert_equal 0, result["applied"]
    evidence("step4_idempotent_replay")
  end
end
