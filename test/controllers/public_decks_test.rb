require "test_helper"

class PublicDecksTest < ActionDispatch::IntegrationTest
  setup do
    @owner = build_user("publisher")
    @owner_deck = @owner.decks.create!(name: "Shared French", description: "public vocab",
                                       visibility: :public)
    note_type = @owner_deck.note_types.create!(
      name: "Basic", field_names: %w[Front Back],
      templates: [ { "name" => "Card 1", "front" => "{{Front}}", "back" => "{{Back}}" } ],
      card_requirements: [ [ 0, "any", %w[Front] ] ], css: ""
    )
    %w[bonjour hello salut].each_with_index do |word, i|
      note = @owner_deck.notes.create!(note_type: note_type, fields: [ word, word.reverse ],
                                       guid: "pub-#{i}")
      Cards::Generate.call(note, position: i + 1)
    end

    @reader = build_user("reader")
    post login_path, params: { name: "reader", password: "password123" }
  end

  test "browse lists others' public decks with the reader's own progress counts" do
    deck = @reader.decks.create!(name: "My own", visibility: :public)
    @owner.decks.create!(name: "Private one", visibility: :private)

    get browse_decks_path
    assert_response :success
    names = css_select(".deck-list .deck-name").map(&:text)
    assert_includes names, "Shared French"
    assert_not_includes names, "My own"      # own decks stay on the main list
    assert_not_includes names, "Private one" # others' private decks are invisible
    assert_includes css_select(".deck-list li").first.inner_text, "by publisher"

    # Review one card as the reader (an hour ago, so it is due now);
    # their browse counts show their progress
    card = @owner_deck.cards.order(:position).first
    Reviewing::Apply.call(user: @reader, card: card, rating: 3, reviewed_at: 1.hour.ago)
    get browse_decks_path
    assert_includes @response.body, "due-count" # reader's due count on the foreign deck
  end

  test "the reader can study someone else's public deck with separate progress" do
    card = @owner_deck.cards.order(:position).first
    Reviewing::Apply.call(user: @reader, card: card, rating: 3)

    get study_deck_path(@owner_deck)
    assert_response :success
    # The client-side session (cards serialized, both sides) is on the page
    assert_select "script#study-session-data"
    assert_match(/Shared French/, @response.body)

    # The owner's progress is untouched by the reader's reviews
    assert_nil @owner_deck.cards.order(:position).first.state_for(@owner)
    assert @owner_deck.cards.order(:position).first.state_for(@reader).state_learning?
  end

  test "public deck details are readable but not editable by others" do
    get deck_path(@owner_deck)
    assert_response :success
    assert_includes @response.body, "by publisher"
    assert_includes @response.body, "Browse cards"
    assert_no_match(/Delete deck/, @response.body)
    assert_no_match(/Add card/, @response.body)
    assert_match(/Export .apkg/, @response.body) # export includes the reader's own progress

    get cards_deck_path(@owner_deck)
    assert_response :success
    assert_no_match(/Add card/, @response.body)

    get new_card_deck_path(@owner_deck)
    assert_response :forbidden

    delete deck_path(@owner_deck)
    assert_response :forbidden
    assert Deck.exists?(@owner_deck.id)
  end

  test "the reader can export a public deck with their own progress" do
    card = @owner_deck.cards.order(:position).first
    Reviewing::Apply.call(user: @reader, card: card, rating: 3)

    get export_deck_path(@owner_deck)
    assert_response :success
    assert_match(/attachment; filename="Shared French.apkg"/, @response.headers["Content-Disposition"])

    # Round-trip: the export carries the reader's (not the owner's) progress
    Tempfile.create([ "reader-export", ".apkg" ]) do |file|
      file.binmode
      file.write(@response.body)
      file.flush
      third = build_user("third")
      copy = Decks::Import.call(third, file.path, name: "From reader")
      # The reviewed card is learning; the other two are still new. In-app
      # cards export under generated anki ids (CARD_ID_BASE + id), so use
      # that to find the reader's reviewed card in the copy.
      learned = copy.cards.find_by!(anki_card_id: Decks::Export::CARD_ID_BASE + card.id)
      assert learned.state_for(third).state_learning?
      assert_equal 1, learned.state_for(third).reps
      assert copy.cards.where.not(id: learned.id).all? { |c| c.state_for(third).state_new? }
    end
  end

  test "others' private decks are 404 everywhere" do
    private_deck = @owner.decks.create!(name: "Hidden")
    get deck_path(private_deck)
    assert_response :not_found
    get study_deck_path(private_deck)
    assert_response :not_found
    get cards_deck_path(private_deck)
    assert_response :not_found
    get export_deck_path(private_deck)
    assert_response :not_found
  end

  test "the owner keeps full control of their public deck" do
    post login_path, params: { name: "publisher", password: "password123" }
    get deck_path(@owner_deck)
    assert_response :success
    assert_match(/Delete deck/, @response.body)
    assert_match(/Add card/, @response.body)
  end
end
