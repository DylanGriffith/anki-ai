require "test_helper"

class Ai::Agent::CardAdderTest < ActiveSupport::TestCase
  setup do
    @user = build_user("ai-adder")
    @server = FakeOpenAIServer.start
    Ai::Setting.current.update!(base_url: @server.url, api_key: "fake-key")
    @deck = @user.decks.create!(name: "German Numbers", description: "1-3 in German")
    @note_type = @deck.note_types.create!(name: "Basic", field_names: %w[Front Back],
                                          templates: [ { "name" => "Card 1", "front" => "{{Front}}",
                                                         "back" => "{{FrontSide}}<hr>{{Back}}" } ],
                                          card_requirements: [ [ 0, "any", %w[Front] ] ])
    @existing_note = @deck.notes.create!(note_type: @note_type, fields: %w[eins one], guid: "g1")
    Cards::Generate.call(@existing_note, position: 1)
  end

  teardown do
    @server.stop
  end

  def build_generation(card_limit: 3, insert_mode: :append, prompt: "three more German numbers",
                       deck: @deck)
    Ai::Generation.create!(user: @user, model: "fake-mini", prompt: prompt, deck: deck,
                           mode: :add_cards, card_limit: card_limit, insert_mode: insert_mode)
  end

  test "a full scripted run adds cards to the existing deck and finishes" do
    @server.chat_response(tool_calls: [ { name: "list_notes" } ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[zwei two] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[drei three] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[vier four] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "3 numbers" } } ])

    generation = build_generation
    result = Ai::Agent::CardAdder.new(generation).call

    assert_equal :done, result
    assert generation.reload.done?
    assert_equal @deck, generation.deck
    assert_equal 4, @deck.notes.count

    # The agent's prompt mentions the existing deck and its offered toolbox
    # has no create_deck (the deck already exists).
    first_request = @server.chat_requests.first
    system_message = first_request[:body]["messages"].first["content"]
    assert_includes system_message, "German Numbers"
    assert_includes system_message, "Target about 3 cards"
    tool_names = first_request[:body]["tools"].map { |t| t.dig("function", "name") }
    assert_equal %w[upsert_note_type add_note update_note delete_note list_notes finish], tool_names
  end

  test "the system prompt is seeded with a sample of the deck's existing cards" do
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "x" } } ])

    build_generation(card_limit: 1)
    Ai::Agent::CardAdder.new(Ai::Generation.last).call

    system_message = @server.chat_requests.first[:body]["messages"].first["content"]
    assert_includes system_message, "Examples of the deck's existing cards (1 in total"
    assert_includes system_message, "(Basic) eins | one"
    assert_includes system_message, "do not write cards that duplicate them"
  end

  test "an empty deck seeds no (empty) sample section" do
    empty_deck = @user.decks.create!(name: "Empty")
    @existing_note.destroy!
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "x" } } ])

    build_generation(card_limit: 1, deck: empty_deck)
    Ai::Agent::CardAdder.new(Ai::Generation.last).call

    system_message = @server.chat_requests.first[:body]["messages"].first["content"]
    assert_not_includes system_message, "Examples of the deck's existing cards"
  end

  test "card insert mode append puts new cards at the back of the queue" do
    @server.chat_response(tool_calls: [ { name: "add_note", arguments: { note_type: "Basic", fields: %w[zwei two] } } ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "one" } } ])

    build_generation(card_limit: 1, insert_mode: :append)
    Ai::Agent::CardAdder.new(Ai::Generation.last).call

    # The existing card keeps position 1; the appended card goes behind it.
    assert_equal [ 1, 2 ], @deck.cards.order(:position).pluck(:position)
    assert_equal %w[eins zwei], @deck.cards.order(:position).map { |c| c.note.fields.first }
  end

  test "card insert mode up_next queues the new cards before every existing card" do
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[zwei two] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[drei three] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "two" } } ])

    build_generation(card_limit: 2, insert_mode: :up_next)
    Ai::Agent::CardAdder.new(Ai::Generation.last).call

    # Both new cards sort before the existing one, in the order they were
    # generated (study queue order: zwei, drei, then the old eins).
    ordered = @deck.cards.order(:position, :id).map { |c| c.note.fields.first }
    assert_equal %w[zwei drei eins], ordered
  end

  test "the agent stops automatically when the card limit is reached" do
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[zwei two] } },
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[drei three] } }
    ])
    # More scripted adds, but the run must end at the limit before they run.
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: %w[vier four] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "never reached" } } ])

    generation = build_generation(card_limit: 2)
    result = Ai::Agent::CardAdder.new(generation).call

    assert_equal :done, result
    assert generation.reload.done?
    assert_equal 3, @deck.notes.count # one existing + two generated, not three
    assert generation.journal.any? { |e| e["type"] == "status" && e["text"] == "card limit reached" }
  end

  test "without a deck the add_cards generation is invalid" do
    generation = Ai::Generation.new(user: @user, model: "fake-mini", prompt: "p",
                                    mode: :add_cards, card_limit: 3)
    assert_not generation.valid?
    assert generation.errors[:deck].any?
  end
end
