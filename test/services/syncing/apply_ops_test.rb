require "test_helper"

class Syncing::ApplyOpsTest < ActiveSupport::TestCase
  setup do
    @user = build_user("syncer")
    @other = build_user("outsider")
    @deck = import_deck(@user)
    @card = @deck.cards.order(:position, :id).first
  end

  def import_deck(user)
    builder = AnkiApkgBuilder.new
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}",
                                back: "{{FrontSide}}<hr id=answer>{{Back}}" } ])
      .add_deck(id: 1650000000001, name: "Sync Test")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001, fields: [ "hello", "bonjour" ])
      .add_note(id: 1600000000102, guid: "g2", mid: 1600000000001, fields: [ "dog", "chien" ])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001, due: 1)
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1650000000001, due: 2)
    with_apkg(builder, "sync-test") { |path| Decks::Import.call(user, path) }
  end

  def review_op(card: @card, rating: 3, op_id: "op-1", reviewed_at: "2026-11-21T10:00:00.000Z")
    { "op_id" => op_id, "kind" => "review",
      "payload" => { "card_id" => card.id, "rating" => rating,
                     "reviewed_at" => reviewed_at, "duration_ms" => 2500 } }
  end

  test "applies a review op and records the ledger" do
    results = Syncing::ApplyOps.call(user: @user, ops: [ review_op ])

    assert_equal [ "applied" ], results.map(&:status)
    log = ReviewLog.find_by(sync_op_id: "op-1")
    assert_not_nil log
    assert_equal "good", log.rating
    assert_equal Time.utc(2026, 11, 21, 10), log.reviewed_at
    assert_equal 2500, log.duration_ms
    assert SyncOp.exists?(op_id: "op-1", user: @user, kind: "review")
    state = @card.state_for(@user)
    assert_equal 1, state.reps
    # scheduled forward from the op's reviewed_at, not from wall-clock now
    assert state.due > Time.utc(2026, 11, 21, 10)
    assert_equal Time.utc(2026, 11, 21, 10), state.last_reviewed_at
  end

  test "replaying an op is a no-op duplicate" do
    Syncing::ApplyOps.call(user: @user, ops: [ review_op ])

    assert_no_difference -> { ReviewLog.count } do
      assert_no_difference -> { SyncOp.count } do
        assert_no_difference -> { @card.state_for(@user).reps } do
          results = Syncing::ApplyOps.call(user: @user, ops: [ review_op ])
          assert_equal [ "duplicate" ], results.map(&:status)
        end
      end
    end
  end

  test "applies the same op for a different user independently" do
    Syncing::ApplyOps.call(user: @user, ops: [ review_op ])
    results = Syncing::ApplyOps.call(user: @other, ops: [ review_op ])

    # Same op_id, different user: not their op. The ledger is global on
    # op_id, so it reports duplicate and does not apply foreign reviews.
    assert_equal [ "duplicate" ], results.map(&:status)
    assert_nil ReviewLog.find_by(user: @other, card: @card)
  end

  test "rejects a private deck card from another user" do
    results = Syncing::ApplyOps.call(user: @other, ops: [
      review_op(op_id: "op-x", card: @deck.cards.last, reviewed_at: "2026-11-21T10:05:00.000Z")
    ])

    assert_equal [ "invalid" ], results.map(&:status)
    assert_equal "unknown card", results.first.error
    assert_equal 0, ReviewLog.count
    assert_equal 0, SyncOp.count
  end

  test "applies another user's public deck card with separate progress" do
    @deck.update!(visibility: :public)

    results = Syncing::ApplyOps.call(user: @other, ops: [ review_op ])
    assert_equal [ "applied" ], results.map(&:status)
    assert_equal 1, @card.state_for(@other).reps
    assert_equal 0, @card.state_for(@user).reps # different user's progress untouched
  end

  test "malformed and invalid ops are reported without blocking the batch" do
    results = Syncing::ApplyOps.call(user: @user, ops: [
      nil,
      "nonsense",
      { "kind" => "review", "payload" => {} },                                  # no op_id
      review_op(op_id: "op-bad-rating", rating: 9),
      review_op(op_id: "op-bad-time", reviewed_at: "not-a-time"),
      review_op(op_id: "op-unknown-card", card: Card.new(id: 999_999)),
      review_op(op_id: "op-unknown-kind", reviewed_at: "2026-11-21T11:00:00.000Z").merge("kind" => "delete"),
      review_op(op_id: "op-good", reviewed_at: "2026-11-21T12:00:00.000Z")
    ])

    statuses = results.map(&:status)
    assert_equal "invalid", statuses[0]
    assert_equal "invalid", statuses[1]
    assert_equal "invalid", statuses[2]
    assert_equal "invalid", statuses[3]
    assert_equal "invalid", statuses[4]
    assert_equal "invalid", statuses[5]
    assert_equal "invalid", statuses[6]
    assert_equal "applied", statuses[7]
    assert_equal 1, ReviewLog.count
    assert_equal 1, SyncOp.count
    assert ReviewLog.exists?(sync_op_id: "op-good")
  end

  test "clamps future reviewed_at to now" do
    future = 1.hour.from_now.utc.iso8601
    Syncing::ApplyOps.call(user: @user, ops: [ review_op(op_id: "op-future", reviewed_at: future) ])

    log = ReviewLog.find_by!(sync_op_id: "op-future")
    assert log.reviewed_at <= Time.now.utc
  end

  test "preserves op order within a batch" do
    second = @deck.cards.order(:position, :id).second
    Syncing::ApplyOps.call(user: @user, ops: [
      review_op(op_id: "op-a", card: @card, rating: 1),
      review_op(op_id: "op-b", card: @card, rating: 3),
      review_op(op_id: "op-c", card: second, rating: 4)
    ])

    times = ReviewLog.where(card: @card).order(:reviewed_at).pluck(:rating)
    assert_equal %w[again good], times
  end

  test "caps batch size" do
    ops = 1001.times.map { |i| review_op(op_id: "op-#{i}") }
    results = Syncing::ApplyOps.call(user: @user, ops: ops)

    assert_equal 1001, results.length
    assert_equal 1, results.count { |r| r.status == "invalid" }
    assert_equal 1000, results.count { |r| r.status == "applied" }
    assert_equal 1000, ReviewLog.count
  end
end
