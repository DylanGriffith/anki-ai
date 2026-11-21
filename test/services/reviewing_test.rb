require "test_helper"

class Reviewing::QueueBuilderTest < ActiveSupport::TestCase
  def setup
    @user = build_user
    @deck = @user.decks.create!(name: "Queue deck")
    @note_type = @deck.note_types.create!(
      name: "Basic", field_names: %w[Front Back],
      templates: [ { "name" => "Card 1", "front" => "{{Front}}", "back" => "{{Back}}" } ]
    )
  end

  def add_card(front, position)
    note = @deck.notes.create!(note_type: @note_type, fields: [ front, "back" ],
                               guid: SecureRandom.uuid)
    Cards::Generate.call(note, position: position).sole
  end

  def review(card, rating, at: Time.now.utc)
    Reviewing::Apply.call(user: @user, card: card, rating: rating, reviewed_at: at)
  end

  test "new cards are returned by position order and lazily get no state rows" do
    3.times { |i| add_card("card #{i}", i + 1) }

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal 3, queue[:cards].size
    assert_equal [ "card 0", "card 1", "card 2" ], queue[:cards].map { |c| c.note.fields.first }
    assert_equal 0, @user.card_states.count # still lazy
    assert_equal 3, queue[:counts][:new_remaining]
  end

  test "due review and learning cards come before new cards" do
    due_card = add_card("due", 1)
    new_card = add_card("new", 2)
    review(due_card, 4) # easy graduates: review state, due in ~8 days

    # force the graduated card to be due now
    due_card.state_for(@user).update!(due: Time.now.utc - 1.minute)

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal due_card, queue[:cards].first
    assert_equal new_card, queue[:cards].second
    assert_equal 1, queue[:counts][:due_now]
  end

  test "daily new limit is respected and counts already-introduced cards" do
    @deck.update!(new_per_day: 2)
    4.times { |i| add_card("card #{i}", i + 1) }

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal 2, queue[:cards].size

    # Introduce one (first review moves it out of the new queue)
    review(queue[:cards].first, 3)

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal 1, queue[:cards].size, "1 new budget left after 1 introduced today"
    assert_equal 1, queue[:counts][:new_done_today]
  end

  test "daily review limit counts today's reviews, including introductions" do
    @deck.update!(reviews_per_day: 7, new_per_day: 10)
    5.times { |i| add_card("card #{i}", i + 1) }
    5.times { |i| review(@deck.cards.order(:position)[i], 4) } # all graduate to review
    @deck.cards.each { |c| c.state_for(@user).update!(due: Time.now.utc - 1.minute) }

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal 2, queue[:cards].size, "7 reviews/day budget, 5 done today, 2 left"
    assert_equal 5, queue[:counts][:due_now]
    assert_equal 5, queue[:counts][:reviews_done_today]
  end

  test "learning cards due in the future are not queued but reported" do
    card = add_card("learn", 1)
    review(card, 3) # good: learning, due in 10 minutes

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal [], queue[:cards]
    assert_equal 1, queue[:counts][:due_learning_future]
    assert_not_nil queue[:counts][:next_due_at]
  end

  test "suspended cards are excluded" do
    card = add_card("suspended", 1)
    card.update!(suspended: true)

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal [], queue[:cards]
  end

  test "progress of other users does not affect this queue" do
    other = build_user("other")
    card = add_card("shared", 1)
    Reviewing::Apply.call(user: other, card: card, rating: 4)

    queue = Reviewing::QueueBuilder.call(user: @user, deck: @deck)
    assert_equal [ card ], queue[:cards], "card is still new for this user"
  end
end

class Reviewing::ApplyTest < ActiveSupport::TestCase
  def setup
    @user = build_user
    @deck = @user.decks.create!(name: "Apply deck")
    @note_type = @deck.note_types.create!(
      name: "Basic", field_names: %w[Front Back],
      templates: [ { "name" => "Card 1", "front" => "{{Front}}", "back" => "{{Back}}" } ]
    )
    @note = @deck.notes.create!(note_type: @note_type, fields: %w[q a], guid: "g1")
    @card = Cards::Generate.call(@note, position: 1).sole
  end

  test "first good rating creates state, log and advances learning" do
    state = Reviewing::Apply.call(user: @user, card: @card, rating: 3)

    assert state.state_learning?
    assert_equal 1, state.reps
    assert_equal 0, state.lapses
    assert_in_delta 2.3065, state.stability, 1e-4
    assert state.due > Time.now.utc
    assert_equal 1, @user.review_logs.count
    log = @user.review_logs.sole
    assert log.rated_good?
    assert_in_delta Time.now.utc.to_f, log.reviewed_at.to_f, 5
  end

  test "second good rating graduates to review" do
    Reviewing::Apply.call(user: @user, card: @card, rating: 3)
    state = Reviewing::Apply.call(user: @user, card: @card, rating: 3)

    assert state.state_review?
    assert_equal 2, state.reps
    assert state.due > Time.now.utc + 1.day
  end

  test "again on a review card lapses and relearns" do
    Reviewing::Apply.call(user: @user, card: @card, rating: 4) # graduate to review
    state = Reviewing::Apply.call(user: @user, card: @card, rating: 1)

    assert state.state_relearning?
    assert_equal 1, state.lapses
    assert_equal 2, state.reps
  end

  test "sync_op_id is stored for idempotency bookkeeping" do
    Reviewing::Apply.call(user: @user, card: @card, rating: 3, sync_op_id: "op-123")
    assert_equal "op-123", @user.review_logs.sole.sync_op_id
  end

  test "backdated offline reviews schedule from their own timestamp" do
    yesterday = Time.now.utc - 1.day
    state = Reviewing::Apply.call(user: @user, card: @card, rating: 3, reviewed_at: yesterday)
    assert state.state_learning?
    assert_in_delta yesterday.to_f, state.last_reviewed_at.to_f, 5
    assert_in_delta yesterday.to_f, @user.review_logs.sole.reviewed_at.to_f, 5
  end
end

class Cards::GenerateTest < ActiveSupport::TestCase
  def setup
    @user = build_user
    @deck = @user.decks.create!(name: "Generate deck")
  end

  test "generates cards per card_requirements (UG-style)" do
    type = @deck.note_types.create!(
      name: "UG", field_names: %w[Country Capital Flag Map],
      templates: [
        { "name" => "C-Cap", "front" => "{{Country}}", "back" => "{{Capital}}" },
        { "name" => "Cap-C", "front" => "{{Capital}}", "back" => "{{Country}}" },
        { "name" => "Flag", "front" => "{{Flag}}", "back" => "{{Country}}" },
        { "name" => "Map", "front" => "{{Map}}", "back" => "{{Country}}" }
      ],
      card_requirements: [ [ 0, "any", %w[Capital] ], [ 1, "any", %w[Country] ],
                           [ 2, "any", %w[Flag] ], [ 3, "any", %w[Map] ] ]
    )

    full = @deck.notes.create!(note_type: type,
                               fields: [ "England", "London", "flag.svg", "map.png" ], guid: "g1")
    assert_equal [ 0, 1, 2, 3 ], Cards::Generate.card_ords(full)

    no_flag = @deck.notes.create!(note_type: type,
                                  fields: [ "England", "London", "", "map.png" ], guid: "g2")
    assert_equal [ 0, 1, 3 ], Cards::Generate.card_ords(no_flag)

    cards = Cards::Generate.call(no_flag, position: 5)
    assert_equal 3, cards.size
    assert_equal [ 0, 1, 3 ], cards.map(&:template_ord).sort
  end

  test "without requirements every template gets a card" do
    type = @deck.note_types.create!(
      name: "NoReq", field_names: %w[Front Back],
      templates: [
        { "name" => "A", "front" => "{{Front}}", "back" => "{{Back}}" },
        { "name" => "B", "front" => "{{Back}}", "back" => "{{Front}}" }
      ],
      card_requirements: []
    )
    note = @deck.notes.create!(note_type: type, fields: [ "x", "" ], guid: "g3")
    assert_equal [ 0, 1 ], Cards::Generate.card_ords(note)
  end

  test "cloze notes generate one card per distinct cloze number, capped by templates" do
    type = @deck.note_types.create!(
      name: "Cloze", kind: :cloze, field_names: %w[Text],
      templates: [ { "name" => "Cloze 1", "front" => "{{cloze:Text}}", "back" => "{{cloze:Text}}" },
                   { "name" => "Cloze 2", "front" => "{{cloze:Text}}", "back" => "{{cloze:Text}}" } ],
      card_requirements: []
    )

    note = @deck.notes.create!(note_type: type,
                               fields: [ "un {{c1::chat}} et {{c2::chien}} et {{c1::encore}}" ], guid: "g4")
    assert_equal [ 1, 2 ], Cards::Generate.card_ords(note)
    assert_equal 2, Cards::Generate.call(note, position: 1).size

    many = @deck.notes.create!(note_type: type,
                               fields: [ "{{c1::a}} {{c2::b}} {{c3::c}} {{c4::d}} {{c5::e}}" ], guid: "g5")
    assert_equal [ 1, 2 ], Cards::Generate.card_ords(many), "capped by template count"
  end
end
