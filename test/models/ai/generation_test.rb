require "test_helper"

# The generation journal: log! appends, and while the model streams,
# log_stream! keeps a single in-progress entry (replaced in place, throttled
# to once per second) until log_assistant! swaps in the final entry — so the
# polling status page shows live progress without entry spam.
class Ai::GenerationTest < ActiveSupport::TestCase
  setup do
    @user = build_user("ai-journal")
    @generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
  end

  test "journal entries append and persist" do
    @generation.log!(type: "tool", name: "add_note", result: { note_id: 1 }, error: false)

    assert_equal 1, @generation.reload.journal.length
    assert_equal "add_note", @generation.journal.first["name"]
    assert_equal 1, @generation.journal.first["result"]["note_id"]
  end

  test "status enum and finished?" do
    assert @generation.pending?
    assert_not @generation.finished?
    @generation.update!(status: :failed)
    assert @generation.failed?
    assert @generation.finished?
  end

  test "log_stream! appends one streaming placeholder" do
    @generation.log_stream!(text: "Buil", tool_calls: [])
    entries = @generation.reload.journal

    assert_equal 1, entries.length
    assert_equal "assistant", entries.last["type"]
    assert_equal "Buil", entries.last["text"]
    assert entries.last["streaming"]
  end

  test "log_stream! is throttled to one write per second" do
    @generation.log_stream!(text: "Buil", tool_calls: [])
    @generation.log_stream!(text: "Building the deck", tool_calls: [ { name: "create_deck" } ])

    assert_equal "Buil", @generation.reload.journal.last["text"]
  end

  test "log_stream! replaces the placeholder in place past the throttle" do
    @generation.log_stream!(text: "Buil", tool_calls: [])
    @generation.instance_variable_set(:@last_stream_at, nil) # skip the 1s window
    @generation.log_stream!(text: "Building the deck",
                            tool_calls: [ { name: "create_deck" }, { name: "add_note" } ])
    entries = @generation.reload.journal

    assert_equal 1, entries.length # replaced, not appended
    assert_equal "Building the deck", entries.last["text"]
    assert_equal %w[create_deck add_note], entries.last["tool_calls"].map { |c| c["name"] }
  end

  test "log_assistant! replaces the streaming placeholder with the final entry" do
    @generation.log!(type: "status", text: "starting")
    @generation.log_stream!(text: "Buil", tool_calls: [ { name: "create_deck" } ])
    @generation.log_assistant!(type: "assistant", text: "Building the deck",
                               tool_calls: [ { name: "create_deck" } ])

    entries = @generation.reload.journal
    assert_equal 2, entries.length
    assert_equal "Building the deck", entries.last["text"]
    assert entries.none? { |e| e["streaming"] } # no placeholder left behind
  end
end
