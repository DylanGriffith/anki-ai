require "application_system_test_case"

# Regression test for the stuck "in progress" bug: the status page must keep
# polling on its own from running until done. The poller lives in
# application.js and re-arms on every turbo:load (inline per-page scripts are
# not re-executed on Turbo renders, which is what previously stopped the
# polling after the first auto-refresh).
class AiGenerationPollingTest < ApplicationSystemTestCase
  test "status page refreshes itself from in progress until done" do
    User.create!(name: "poller", password: "password123")
    sign_in_as("poller", "password123")
    Ai::Setting.current.update!(base_url: "http://127.0.0.1:1", api_key: "k")

    generation = Ai::Generation.create!(user: User.find_by(name: "poller"),
                                        model: "fake-mini", prompt: "polling repro",
                                        status: :running)
    generation.log!(type: "status", text: "starting", model: "fake-mini")

    # The "job" finishes while the user sits on the status page.
    finisher = Thread.new do
      sleep 3
      generation.update!(status: :done, finished_at: Time.now.utc)
      generation.log!(type: "status", text: "finished", summary: "deck built")
    end

    visit ai_generation_path(generation)
    assert_selector ".status-dot--running", wait: 5

    # No manual navigation: the page's own polling must reveal "done".
    assert_selector ".status-dot--done", wait: 15
    assert_text "done"
    finisher.join
  end
end
