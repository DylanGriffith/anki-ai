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
end
