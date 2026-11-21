require "application_system_test_case"

# Step 7 E2E: public decks. A second user browses a public deck, studies it
# with their own progress, and the owner's progress stays untouched.
class PublicDecksFlowTest < ApplicationSystemTestCase
  include StudySystemHelpers

  test "browse a public deck and study it with separate progress" do
    # The owner imports a deck and makes it public
    owner = User.create!(name: "owner", password: "password123")
    deck = nil
    sign_in_as("owner", "password123")
    with_apkg(build_study_apkg, "public-deck") do |path|
      click_on "Import .apkg"
      attach_file "file", path
      click_submit("Import")
    end
    deck = owner.decks.find_by!(name: "Study Test")
    visit deck_path(deck)
    # Flip the deck public through the edit form
    click_on "Edit deck"
    select "Public", from: "Visibility"
    click_on "Save deck"
    assert_text "public"
    evidence("step7_owner_deck_public")
    click_on "Sign out"

    # The reader discovers it on the browse page and studies it in one click
    User.create!(name: "reader", password: "password123")
    sign_in_as("reader", "password123")
    visit decks_path
    assert_no_text "Study Test" # not on the reader's own list

    click_on "Browse public decks"
    assert_selector "h1", text: "Public decks"
    assert_text "by owner"
    assert_text "Study Test"
    evidence("step7_browse_public_decks")

    find(".deck-name", text: "Study Test").execute_script("this.click()")
    assert_selector ".study-card"
    assert_text "Show Answer"
    evidence("step7_reading_public_deck")

    # Review one card as the reader — through the real sync path
    click_on "Show Answer"
    find(".answer-bar .btn", text: "Good").execute_script("this.click()")

    # The reader's progress on the deck list and browse page is theirs alone
    visit decks_path
    assert_no_text "Study Test"
    click_on "Browse public decks"
    assert_text "2 new" # one of three cards reviewed

    # The owner's deck is untouched: the owner's cards are still fresh (the
    # import seeds new-state rows) and no reviews were recorded for them
    owner_card = deck.cards.order(:position).first
    assert owner_card.state_for(owner).state_new?
    assert_equal 0, ReviewLog.where(user: owner).count
    assert owner_card.state_for(User.find_by!(name: "reader")).state_learning?
    assert_equal 1, ReviewLog.where(user: User.find_by!(name: "reader")).count
  end

  test "private decks never appear for other users" do
    owner = User.create!(name: "owner", password: "password123")
    owner.decks.create!(name: "Secret deck")

    User.create!(name: "reader", password: "password123")
    sign_in_as("reader", "password123")
    visit browse_decks_path
    assert_text "No public decks yet"
    assert_no_text "Secret deck"

    visit deck_path(owner.decks.first)
    assert_selector "h1", text: "Decks" # 404 page falls back to the deck list
  end
end
