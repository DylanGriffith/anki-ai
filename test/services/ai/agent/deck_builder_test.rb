require "test_helper"

class Ai::Agent::DeckBuilderTest < ActiveSupport::TestCase
  setup do
    @user = build_user("ai-user")
    @server = FakeOpenAIServer.start
    Ai::Setting.current.update!(base_url: @server.url, api_key: "fake-key")
  end

  teardown do
    @server.stop
  end

  def build_generation(prompt: "French A1 verbs, 3 cards")
    Ai::Generation.create!(user: @user, model: "fake-mini", prompt: prompt)
  end

  test "a full scripted run builds a studyable deck and finishes" do
    @server.chat_response(tool_calls: [
      { name: "create_deck", arguments: { name: "French A1 Verbs", description: "Core verbs" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Basic", fields: %w[Front Back],
                                               front_template: "{{Front}}",
                                               back_template: "{{FrontSide}}<hr>{{Back}}" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[aller to\ go] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[être to\ be] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: [ "faire", "to do", "extra" ] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "3 core verbs" } } ])

    generation = build_generation
    result = Ai::Agent::DeckBuilder.new(generation).call

    assert_equal :done, result
    assert generation.reload.done?
    deck = generation.deck
    assert_not_nil deck
    assert_equal "French A1 Verbs", deck.name
    assert_equal "Core verbs", deck.description
    assert deck.is_private?

    type = deck.note_types.find_by!(name: "Basic")
    assert_equal %w[Front Back], type.field_names
    assert_equal "{{Front}}", type.templates.first["front"]
    assert_equal [ [ 0, "any", %w[Front] ] ], type.card_requirements

    assert_equal 3, deck.notes.count
    assert_equal 3, deck.cards.count
    assert_equal %w[aller être faire], deck.notes.order(:id).pluck(:fields).map(&:first)
    assert_equal [ 1, 2, 3 ], deck.cards.order(:position).pluck(:position)

    # The model actually saw every tool result so far (tool role messages
    # accumulate across turns) and the finish result last
    last_request = @server.last_chat_request
    tool_messages = last_request[:body]["messages"].select { |m| m["role"] == "tool" }
    assert_equal 5, tool_messages.length
    # The model saw its own add_note results before calling finish
    assert_includes tool_messages.last["content"], '"faire"'

    # The agent sent its system prompt, the user prompt, and the tool schemas
    first_request = @server.chat_requests.first
    roles = first_request[:body]["messages"].map { |m| m["role"] }
    assert_equal %w[system user], roles
    assert_includes first_request[:body]["messages"].first["content"], "flashcard deck builder"
    assert_includes first_request[:auth], "Bearer fake-key"
    tool_names = first_request[:body]["tools"].map { |t| t.dig("function", "name") }
    assert_equal %w[create_deck upsert_note_type add_note update_note delete_note list_notes search_notes finish],
                 tool_names
  end

  test "the Mistral/GLM blank-name-echo dialect builds a deck end to end" do
    # The provider dialect confirmed against api.mistral.ai: continuation
    # tool fragments echo `"name": ""`. Before the fix every argumented
    # tool call arrived nameless and failed as "unknown tool ", while
    # argument-less calls (list_notes, bare finish) worked.
    [ { name: "create_deck",
        arguments: { name: "French History", description: "key facts" } },
      { name: "upsert_note_type",
        arguments: { name: "Basic", fields: %w[Front Back],
                     front_template: "{{Front}}", back_template: "{{Back}}" } },
      { name: "add_note",
        arguments: { note_type: "Basic", fields: [ "Verdun", "843 treaty" ] } },
      { name: "finish", arguments: { summary: "1 card" } }
    ].each do |call|
      @server.chat_response(thinking: "planning", tool_dialect: :blank_name_echo,
                            tool_calls: [ call ])
    end

    generation = build_generation
    assert_equal :done, Ai::Agent::DeckBuilder.new(generation).call

    deck = generation.reload.deck
    assert_equal "French History", deck.name
    assert_equal 1, deck.notes.count

    tool_entries = generation.journal.select { |e| e["type"] == "tool" }
    assert_equal %w[create_deck upsert_note_type add_note finish], tool_entries.map { |e| e["name"] }
    assert tool_entries.none? { |e| e["error"] }
  end

  test "tool errors are surfaced as recoverable results, not failures" do
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[x y] } }, # no deck yet
      { name: "create_deck", arguments: { name: "Deck" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Basic", fields: %w[Front Back],
                                               front_template: "{{Front}}", back_template: "{{Back}}" } }
    ])
    @server.chat_response(tool_calls: [ { name: "add_note", arguments: { note_type: "Basic",
                                                                        fields: %w[a b] } } ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: {} } ])

    generation = build_generation(prompt: "tiny deck")
    result = Ai::Agent::DeckBuilder.new(generation).call

    assert_equal :done, result
    # The first turn's tool error is in the transcript with error: true
    tool_entries = generation.reload.journal.select { |e| e["type"] == "tool" }
    assert tool_entries.first["error"]
    assert_includes tool_entries.first["result"]["error"], "create the deck first"
    assert_equal 1, generation.deck.notes.count
  end

  test "list_notes, update_note and delete_note work as tools" do
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "D" } } ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Basic", fields: %w[Front Back],
                                               front_template: "{{Front}}", back_template: "{{Back}}" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[one 1] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[two 2] } }
    ])
    @server.chat_response(tool_calls: [ { name: "list_notes", arguments: {} } ])
    # Scripted from what the model would have just seen: the add_note results
    @server.chat_response do |srv|
      added = srv.tool_results.select { |r| r.key?("note_id") }.last(2)
      { tool_calls: [
        { name: "update_note", arguments: { note_id: added.first["note_id"], fields: %w[uno 1] } },
        { name: "delete_note", arguments: { note_id: added.second["note_id"] } }
      ] }
    end
    @server.chat_response(tool_calls: [ { name: "finish", arguments: {} } ])

    generation = build_generation(prompt: "list test")
    Ai::Agent::DeckBuilder.new(generation).call

    # list_notes returned the actual note ids and payloads
    list_entry = generation.reload.journal.select { |e| e["type"] == "tool" && e["name"] == "list_notes" }.first
    listed = list_entry["result"]["notes"]
    assert_equal 2, listed.size
    assert_equal %w[one 1], listed.first["fields"]

    deck = generation.deck
    assert_equal 1, deck.notes.count # delete_note removed one
    assert_equal %w[uno 1], deck.notes.first.fields # update_note fixed the other
  end

  test "exhausting the turn budget fails the generation" do
    (Ai::Agent::DeckBuilder::MAX_TURNS + 1).times do
      @server.chat_response(content: "I am thinking...")
    end

    generation = build_generation
    result = Ai::Agent::DeckBuilder.new(generation).call

    assert_equal :failed, result
    assert generation.reload.failed?
    assert_match(/did not call finish/i, generation.error)
    assert_equal Ai::Agent::DeckBuilder::MAX_TURNS, generation.turn_count
  end

  test "API errors fail the generation with the message" do
    # No scripted responses: the fake answers 500 "script exhausted"

    generation = build_generation
    result = Ai::Agent::DeckBuilder.new(generation).call

    assert_equal :failed, result
    assert generation.reload.failed?
    assert_includes generation.error, "500"
    # The transcript journals the failure for the status page
    assert generation.journal.any? { |e| e["type"] == "status" && e["error"].present? }
  end

  test "the agent cannot touch other users' decks" do
    other_deck = build_user("other").decks.create!(name: "Not Yours")

    @server.chat_response(tool_calls: [ { name: "create_deck",
                                          arguments: { name: "French A1 Verbs" } } ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Basic", fields: %w[Front Back],
                                               front_template: "{{Front}}", back_template: "{{Back}}" } }
    ])
    @server.chat_response(tool_calls: [ { name: "update_note",
                                          arguments: { note_id: other_deck.notes.first&.id || 999_999,
                                                       fields: %w[hacked] } } ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: {} } ])

    generation = build_generation
    Ai::Agent::DeckBuilder.new(generation).call

    # update_note against a foreign deck is a tool error (id not in this deck)
    tool_entries = generation.reload.journal.select { |e| e["type"] == "tool" }
    assert tool_entries.third["error"]
    assert_equal 0, other_deck.notes.count
  end

  test "streaming progress is journaled with thinking and a char counter" do
    generation = build_generation
    replies = [
      { content: nil, thinking: "pondering",
        tool_calls: [ { id: "c1", name: "create_deck", arguments: { "name" => "T" } } ] },
      { content: nil, thinking: nil,
        tool_calls: [ { id: "c2", name: "finish", arguments: { "summary" => "s" } } ] }
    ]
    snapshots = []
    spy = Class.new do
      def initialize(generation, replies, snapshots)
        @generation = generation
        @replies = replies
        @snapshots = snapshots
      end

      def chat(model:, messages:, tools:, on_delta:, **_)
        on_delta.call(content: "partial text", thinking: "partial thought", tool_calls: [])
        # The agent's on_delta wrapper writes the journal synchronously —
        # capture what the status page would poll right now.
        @snapshots << @generation.reload.journal.last.dup
        @replies.shift
      end
    end.new(generation, replies, snapshots)

    assert_equal :done, Ai::Agent::DeckBuilder.new(generation, client: spy).call

    stream_entry = snapshots.first
    assert stream_entry["streaming"]
    assert_equal "partial text", stream_entry["text"]
    assert_equal "partial thought", stream_entry["thinking"]
    assert_equal "partial text".length + "partial thought".length, stream_entry["chars"]
    # the finished transcript no longer carries the placeholder
    assert generation.reload.journal.none? { |e| e["streaming"] }
  end

  test "runaway monologues are capped in the journal and not replayed in full" do
    # A model that answers a tool call with a giant text blob plus reasoning:
    # the blob must not bloat the journal, and must not go back into the
    # chat history at full size (the next request carries it).
    @server.chat_response(thinking: "p" * 5_000, content: "y" * 20_000, tool_calls: [
      { name: "create_deck", arguments: { name: "Big" } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "ok" } } ])

    generation = build_generation
    assert_equal :done, Ai::Agent::DeckBuilder.new(generation).call

    assistant_entry = generation.reload.journal.select { |e| e["type"] == "assistant" }.first
    assert_equal Ai::Generation::ENTRY_TAIL + 1, assistant_entry["text"].length
    assert_equal Ai::Generation::ENTRY_TAIL + 1, assistant_entry["thinking"].length

    second_request = @server.chat_requests.second
    replayed = second_request[:body]["messages"].find { |m| m["role"] == "assistant" }
    assert replayed["content"].length < 20_000
    assert_includes replayed["content"], "truncated"
  end
end
