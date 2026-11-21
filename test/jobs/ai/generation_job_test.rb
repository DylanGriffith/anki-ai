require "test_helper"

class Ai::GenerationJobTest < ActiveSupport::TestCase
  setup do
    @user = build_user("ai-job")
    @server = FakeOpenAIServer.start
    Ai::Setting.current.update!(base_url: @server.url, api_key: "fake-key")
  end

  teardown do
    @server.stop
  end

  test "performs the agent loop and finishes the generation" do
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Job Deck" } } ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Basic", fields: %w[Front Back],
                                               front_template: "{{Front}}", back_template: "{{Back}}" } }
    ])
    @server.chat_response(tool_calls: [ { name: "add_note", arguments: { note_type: "Basic",
                                                                        fields: %w[x y] } } ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
    Ai::GenerationJob.perform_now(generation.id)

    assert generation.reload.done?
    assert_not_nil generation.deck
    assert_equal 1, generation.deck.notes.count
  end

  test "re-running a finished generation is a no-op" do
    @server.chat_response(tool_calls: [ { name: "finish", arguments: {} } ])
    generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
    Ai::GenerationJob.perform_now(generation.id)
    assert generation.reload.done?

    # No scripted responses left: a real re-run would fail the generation,
    # so proving the skip matters.
    Ai::GenerationJob.perform_now(generation.id)
    assert generation.reload.done?
    assert_nil generation.error
  end

  test "API failures mark the generation failed (the job itself succeeds)" do
    generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
    Ai::GenerationJob.perform_now(generation.id) # empty script -> 500

    assert generation.reload.failed?
    assert_match(/API returned 500/, generation.error)
  end
end
