require "test_helper"

class Reviewing::SessionSerializerTest < ActiveSupport::TestCase
  setup do
    @user = build_user("serializer")
    @deck = import_deck(@user)
  end

  def import_deck(user)
    builder = AnkiApkgBuilder.new
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back Audio],
                 templates: [ { name: "Card 1", front: "{{Front}}",
                                back: "{{FrontSide}}<hr id=answer>{{Back}}{{Audio}}" } ],
                 css: ".card { color: red; }")
      .add_model(id: 1600000000002, name: "Type Answer", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}<br>{{type:Back}}",
                                back: "{{FrontSide}}<hr id=answer>{{type:Back}}" } ])
      .add_deck(id: 1650000000001, name: "Serializer Test")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001,
                fields: [ "hello", "bonjour", "[sound:word.mp3]" ])
      .add_note(id: 1600000000102, guid: "g2", mid: 1600000000002,
                fields: [ "dog", "chien" ])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001, due: 1)
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1650000000001, due: 2)
      .add_media("word.mp3", "fake-mp3-bytes")
    with_apkg(builder, "serializer-test") { |path| Decks::Import.call(user, path) }
  end

  test "serializes both sides, intervals, css and urls for the queue" do
    cards = @deck.cards.order(:position, :id).to_a
    session = Reviewing::SessionSerializer.call(user: @user, deck: @deck, cards: cards)

    assert_equal @deck.id, session["deck_id"]
    assert_equal "/decks/#{@deck.id}", session["done_url"]
    assert_includes session["css"], "color: red"
    assert_equal 2, session["cards"].length

    first = session["cards"].first
    assert_equal cards.first.id, first["id"]
    assert_includes first["question_html"], "hello"
    assert_not_includes first["question_html"], "bonjour"
    # answer side embeds FrontSide (question repeats) plus the answer
    assert_includes first["answer_html"], "hello"
    assert_includes first["answer_html"], "bonjour"
    # media rewritten to the deck media route
    assert_includes first["answer_html"], %(src="/decks/#{@deck.id}/media/word.mp3")
    # four interval previews like Anki's rating buttons
    assert_equal 4, first["intervals"].length
    assert(first["intervals"].all? { |i| i.match?(/\A\d+[md]\z/) })
  end

  test "type-answer cards embed the expected answer and a typebox" do
    card = @deck.cards.order(:position, :id).second
    session = Reviewing::SessionSerializer.call(user: @user, deck: @deck, cards: [ card ])

    data = session["cards"].first
    assert_includes data["question_html"], "input"
    assert_includes data["question_html"], "typebox"
    assert_equal "chien", data["typed_answer"]
    # pre-rendered comparison is blank; the client replaces it at reveal
    assert_includes data["answer_html"], "typed--correct"
    assert_not_includes data["typed_answer"], "typed"
  end

  test "plain cards have no typed_answer key" do
    card = @deck.cards.order(:position, :id).first
    session = Reviewing::SessionSerializer.call(user: @user, deck: @deck, cards: [ card ])
    assert_not session["cards"].first.key?("typed_answer")
  end
end
