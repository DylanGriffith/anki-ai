require "test_helper"

# Headless Chrome sometimes throttles renderers it considers backgrounded
# or occluded, which makes synthesized input (and even script execution)
# lossy for whole browser sessions. These flags disable that class of
# interference.
Capybara.register_driver :headless_chrome_e2e do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--window-size=1280,900")
  options.add_argument("--disable-gpu")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--disable-background-timer-throttling")
  options.add_argument("--disable-backgrounding-occluded-windows")
  options.add_argument("--disable-renderer-backgrounding")
  options.add_argument("--disable-features=Translate,BackForwardCache")
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :headless_chrome_e2e

  # Offline study keeps state in the browser (service worker, its caches and
  # the IndexedDB outbox) that Capybara's reset does not touch, and test
  # databases roll back to reused ids — stale outbox ops would filter away a
  # later test's whole queue. Clear all of it after every test.
  teardown do
    clear_offline_storage
  end

  def clear_offline_storage
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      (async () => {
        try {
          const dbs = await indexedDB.databases();
          await Promise.all(dbs.map((db) => new Promise((resolve) => {
            const request = indexedDB.deleteDatabase(db.name);
            request.onsuccess = request.onerror = request.onblocked = () => resolve();
          })));
        } catch (e) {}
        try {
          const keys = await caches.keys();
          await Promise.all(keys.map((key) => caches.delete(key)));
        } catch (e) {}
        try {
          const regs = await navigator.serviceWorker.getRegistrations();
          await Promise.all(regs.map((reg) => reg.unregister()));
        } catch (e) {}
        done(true);
      })()
    JS
  rescue StandardError
    nil
  end

  # Saves a screenshot as feature evidence in screenshots/.
  def evidence(name)
    path = Rails.root.join("screenshots", "#{name}.png")
    FileUtils.mkdir_p(File.dirname(path))
    page.save_screenshot(path.to_s)
    Rails.logger.info("Screenshot: #{path}")
  end

  # Guarantee the current document finished loading and that the JS
  # execution context is live for it. Chrome swaps documents during
  # navigation; a script executed against a context that is being torn
  # down (or input dispatched while the new document is still
  # committing) is silently dropped. Real users cannot hit this window
  # because the old page stays visible until the new one commits —
  # synthesized test input can, so every interaction settles first.
  def settle
    deadline = Time.now + Capybara.default_max_wait_time
    while page.evaluate_script("document.readyState") != "complete"
      raise "page never finished loading" if Time.now > deadline
      sleep 0.05
    end
    # Turbo visits keep readyState "complete" the whole time; wait for the
    # visit lifecycle to finish so interactions hit the final DOM, not one
    # that is about to be swapped (Selenium can type into a body that turbo
    # then replaces, silently losing the input).
    while page.evaluate_script("window.__turboBusy !== false")
      raise "turbo visit never finished" if Time.now > deadline
      sleep 0.05
    end
  end

  # Chrome can silently drop synthesized keystrokes when they land in the
  # same instant as a turbo render swapping the body (observed roughly one in
  # five runs): fill_in reports success but the field stays empty, and the
  # form then fails HTML validation. Verify the value landed and retry —
  # ending with a direct value set if the input pipeline keeps dropping keys.
  def fill_in(locator, with:)
    settle
    super
    field = find(:field, locator)
    return if field.value == with

    field.set(with)
    return if field.value == with

    field.execute_script("this.value = arguments[0]; this.dispatchEvent(new Event('input', { bubbles: true }))", with)
    return if field.value == with

    raise "fill_in lost its input for #{locator}"
  end

  # Click a submit button via a DOM click(), after settling. Exercises the
  # same browser code path as the keyboard shortcuts (which click the
  # rating buttons from JS) and avoids input-pipeline drops: synthesized
  # mouse events and scripts dispatched while a document swap is in
  # flight can be dropped by Chrome entirely.
  def click_submit(text)
    settle
    find_button(text).execute_script("this.click()")
  end

  # DOM click for the study rating buttons (value 1..4).
  def click_rating(value)
    settle
    find("button[name='rating'][value='#{value}']").execute_script("this.click()")
  end

  # All link/button clicks go through a DOM click for the same reason —
  # including link navigations, which otherwise lose the click entirely.
  def click_on(locator, **options)
    settle
    find(:link_or_button, locator, **options).execute_script("this.click()")
    # The click may have started a turbo visit, which keeps readyState
    # "complete" while it fetches and swaps the body. Wait for the visit to
    # finish so the next interaction (fill, click, assert) targets the final
    # DOM instead of a body that is about to be replaced.
    settle
  end

  # Sign in through the UI. Signing in is the first interaction after the
  # browser's between-test reset, which is the one spot where a submit
  # can still be dropped (see click_submit). Logging in is idempotent, so
  # the whole flow simply retries; if an earlier attempt actually signed
  # in, /login redirects to the deck list and we are done.
  def sign_in_as(name, password)
    3.times do
      visit login_path
      if page.has_field?("Username")
        fill_in "Username", with: name
        fill_in "Password", with: password
        click_submit("Sign in")
      end
      return assert_text("Signed in as #{name}") if page.has_text?("Signed in as #{name}", wait: 3)
      # An earlier attempt may have signed in while its flash was missed.
      return assert_equal(name, first(".who")&.text.to_s) if page.has_text?("Sign out", wait: 1)
    end
    flunk "could not sign in as #{name}"
  end
end
