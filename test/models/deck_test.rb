require "test_helper"

class DeckTest < ActiveSupport::TestCase
  test "visibility enum" do
    deck = Deck.new(visibility: :public)
    assert deck.is_public?
    assert_not deck.is_private?
  end

  test "name unique per user" do
    user = User.create!(name: "alice", password: "password123")
    user.decks.create!(name: "Kanji")
    deck = user.decks.new(name: "Kanji")
    assert_not deck.valid?
  end

  test "visible_to includes own decks and public decks only" do
    alice = User.create!(name: "alice", password: "password123")
    bob = User.create!(name: "bob", password: "password123")
    own = alice.decks.create!(name: "My private")
    pub = bob.decks.create!(name: "Bob public", visibility: :public)
    bob.decks.create!(name: "Bob private")

    visible = Deck.visible_to(alice).order(:name)
    assert_equal [ pub.name, own.name ].sort, visible.map(&:name)
  end

  test "destroying a deck cascades to everything that references it" do
    user = User.create!(name: "cascade", password: "password123")
    deck = user.decks.create!(name: "Cascade")

    # An AI generation references the deck it built; the deck_id foreign key
    # must not block deck.destroy!.
    Ai::Generation.create!(user: user, model: "fake-mini", prompt: "p", deck: deck)

    note_type = deck.note_types.create!(name: "Basic", field_names: %w[Front Back],
                                        templates: [ { "name" => "Card 1", "front" => "{{Front}}",
                                                       "back" => "{{Back}}" } ],
                                        card_requirements: [ [ 0, "any", %w[Front] ] ])
    note = deck.notes.create!(note_type: note_type, fields: %w[front back], guid: "g1")
    card = note.cards.create!(deck: deck, template_ord: 0)
    user.card_states.create!(card: card, state: :new)
    user.review_logs.create!(card: card, rating: 3, reviewed_at: Time.current)
    deck.media_files.create!(filename: "sound.mp3", content_type: "audio/mpeg")

    deck.destroy!

    assert_empty Ai::Generation.where(deck_id: deck.id)
    assert_empty NoteType.where(deck_id: deck.id)
    assert_empty Note.where(deck_id: deck.id)
    assert_empty Card.where(deck_id: deck.id)
    assert_empty CardState.where(card_id: card.id)
    assert_empty ReviewLog.where(card_id: card.id)
    assert_empty MediaFile.where(deck_id: deck.id)
  end
end
