require "test_helper"

class SyncControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = build_user("syncui")
    @deck = import_deck(@user)
    @card = @deck.cards.order(:position, :id).first
    post login_path, params: { name: "syncui", password: "password123" }
    assert_redirected_to root_path
  end

  def import_deck(user)
    builder = AnkiApkgBuilder.new
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}",
                                back: "{{FrontSide}}<hr id=answer>{{Back}}" } ])
      .add_deck(id: 1650000000001, name: "Sync UI Test")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001, fields: [ "hello", "bonjour" ])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001, due: 1)
    with_apkg(builder, "sync-ui") { |path| Decks::Import.call(user, path) }
  end

  def review_op(op_id:, rating: 3)
    { op_id: op_id, kind: "review",
      payload: { card_id: @card.id, rating: rating,
                 reviewed_at: "2026-11-21T10:00:00.000Z", duration_ms: 1200 } }
  end

  test "applies ops and returns per-op statuses" do
    post "/sync", params: { ops: [ review_op(op_id: "op-1") ] }, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["applied"]
    assert_equal 0, body["duplicates"]
    assert_equal [ { "op_id" => "op-1", "status" => "applied" } ], body["results"]
    assert ReviewLog.exists?(sync_op_id: "op-1")
  end

  test "replayed ops come back as duplicates without applying again" do
    post "/sync", params: { ops: [ review_op(op_id: "op-1") ] }, as: :json
    assert_response :success

    assert_no_difference -> { ReviewLog.count } do
      post "/sync", params: { ops: [ review_op(op_id: "op-1") ] }, as: :json
      assert_response :success
      assert_equal 1, response.parsed_body["duplicates"]
    end
  end

  test "mixed batches report each op" do
    post "/sync", params: { ops: [
      review_op(op_id: "op-good"),
      review_op(op_id: "op-bad", rating: 9)
    ] }, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["applied"]
    assert_equal 1, body["invalid"]
    assert_equal "applied", body["results"].first["status"]
    assert_equal "invalid", body["results"].second["status"]
  end

  test "requires login" do
    delete logout_path
    post "/sync", params: { ops: [] }, as: :json

    assert_response :unauthorized
  end

  test "rejects invalid JSON bodies" do
    post "/sync", params: "not json", as: :json,
                  headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request
  end

  test "rejects a body without ops" do
    post "/sync", params: { hello: "world" }, as: :json

    assert_response :bad_request
  end
end
