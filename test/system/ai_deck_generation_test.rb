require "application_system_test_case"

# End-to-end AI deck generation: the real UI flow (button → form → status
# page → deck) against the scripted fake OpenAI server — the agent's real
# HTTP client calls a real local server, no network, no API key.
class AiDeckGenerationTest < ApplicationSystemTestCase
  setup do
    @server = FakeOpenAIServer.start
    Ai::Setting.current.update!(base_url: @server.url, api_key: "fake-key")
  end

  teardown do
    @server.stop
  end

  test "generate a deck from a description and study it" do
    User.create!(name: "ai-student", password: "password123")
    sign_in_as("ai-student", "password123")

    # What "the model" does: build a tiny German numbers deck — as a
    # thinking model (reasoning streams as array content parts, the dialect
    # that previously corrupted the content buffer)
    @server.chat_response(thinking: "Planning a German numbers deck",
                          tool_calls: [
      { name: "create_deck", arguments: { name: "German Numbers", description: "1-3 in German" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Basic", fields: %w[Front Back],
                                               front_template: "{{Front}}",
                                               back_template: "{{FrontSide}}<hr>{{Back}}" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: [ "one (English)", "eins" ] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: [ "two (English)", "zwei" ] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: [ "three (English)", "drei" ] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish",
                                          arguments: { summary: "3 number cards" } } ])

    visit decks_path
    assert_text "New AI deck"
    evidence("step6_new_ai_deck_button")

    click_on "New AI deck"
    assert_selector "h1", text: "New AI deck"
    assert_selector "option[value=fake-mini]", text: "fake-mini"
    fill_in "What should the deck cover?", with: "German numbers one to three"
    evidence("step6_ai_form")
    click_submit("Generate deck")

    # The job runs inline in tests, so the status page already shows the
    # finished transcript.
    assert_selector "h1", text: "AI deck generation"
    assert_text "done"
    assert_text "German numbers one to three"
    assert_text "create_deck"
    assert_text "add_note"
    # The model's reasoning is journaled (collapsed inside the entry)
    assert_match(/Planning a German numbers deck/, page.body)
    evidence("step6_ai_done")

    # The deck the agent built is one click away and studyable
    click_on "Open deck"
    assert_selector "h1", text: "German Numbers"
    assert_text "3 cards"
    evidence("step6_generated_deck")

    click_on "Study"
    assert_selector ".study-card"
    assert_text "Show Answer"
    assert_text "one (English)" # first generated card, front side
    evidence("step6_generated_deck_study")

    # Reveal and rate the whole queue — the generated deck studies like any
    # other deck (same client session, same sync path)
    3.times do
      click_on "Show Answer"
      find(".answer-bar .btn", text: "Good").execute_script("this.click()")
    end
    assert_text "3 cards reviewed and synced"

    # And the AI button is gone when the API is not configured
    Ai::Setting.current.destroy
    visit decks_path
    assert_no_text "New AI deck"
  end

  test "API failures surface as a failed generation the user can see" do
    User.create!(name: "ai-student", password: "password123")
    sign_in_as("ai-student", "password123")

    # No scripted responses: the fake answers 500 "script exhausted"
    visit decks_path
    click_on "New AI deck"
    fill_in "What should the deck cover?", with: "Anything"
    click_submit("Generate deck")

    assert_selector "h1", text: "AI deck generation"
    assert_text "failed"
    assert_text "Generation failed"
    evidence("step6_ai_failed")
    assert_text "Back to decks"
  end

  test "a model stuck streaming the same segment forever is aborted, not hung" do
    User.create!(name: "ai-student", password: "password123")
    sign_in_as("ai-student", "password123")

    # The failure seen in the wild: a thinking model emitting one identical
    # segment forever — no [DONE] until the (huge) script is exhausted, and
    # per-chunk read timeouts never fire. The client's char cap must abort
    # it and the generation must end as a clear failure.
    @server.chat_response(loop: 40_000)

    visit decks_path
    click_on "New AI deck"
    fill_in "What should the deck cover?", with: "Anything"
    click_submit("Generate deck")

    assert_selector "h1", text: "AI deck generation"
    assert_text "failed"
    assert_text "stuck in a loop"
    assert_no_text "thinking…" # the in-progress placeholder was cleared
    evidence("step8_ai_loop_aborted")
  end

  test "unconfigured AI hides the button and direct URLs explain why" do
    User.create!(name: "ai-student", password: "password123")
    sign_in_as("ai-student", "password123")

    Ai::Setting.current.destroy # undo this test's setup configuration
    visit decks_path
    assert_no_text "New AI deck"

    visit new_ai_generation_path
    assert_selector "h1", text: "Decks"
    assert_text "AI is not configured yet"
  end
end
