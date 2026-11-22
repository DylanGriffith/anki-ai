require "test_helper"

class Ai::ClientTest < ActiveSupport::TestCase
  setup do
    @server = FakeOpenAIServer.start
    @client = Ai::Client.new(base_url: @server.url, api_key: "fake-key")
  end

  teardown do
    @server.stop
  end

  test "chat parses content and tool calls (arguments as JSON string)" do
    @server.chat_response(content: "Building your deck", tool_calls: [
      { name: "create_deck", arguments: { name: "French", description: "verbs" } }
    ])

    reply = @client.chat(model: "fake-mini", messages: [ { role: "user", content: "hi" } ],
                         tools: [ { type: "function", function: { name: "create_deck" } } ])

    assert_equal "Building your deck", reply[:content]
    assert_equal 1, reply[:tool_calls].length
    call = reply[:tool_calls].first
    assert_equal "create_deck", call[:name]
    assert_not_nil call[:id]
    assert_equal({ "name" => "French", "description" => "verbs" }, call[:arguments])

    # The request went out with the API key and JSON body
    request = @server.last_chat_request
    assert_equal "Bearer fake-key", request[:auth]
    assert_equal "fake-mini", request[:body]["model"]
    assert_equal "hi", request[:body]["messages"].first["content"]
    assert request[:body]["tools"]
  end

  test "chat without tool calls returns just content" do
    @server.chat_response(content: "hello")

    reply = @client.chat(model: "fake-mini", messages: [ { role: "user", content: "hi" } ])

    assert_equal "hello", reply[:content]
    assert_equal [], reply[:tool_calls]
    # tools are omitted entirely when none are given
    assert_nil @server.last_chat_request[:body]["tools"]
  end

  test "malformed tool-call arguments become empty arguments instead of raising" do
    # The wire format carries arguments as a JSON *string*; a model emitting
    # garbage must not break the loop — the agent answers with a tool error
    # the model can fix on its next turn.
    assert_equal({ "a" => 1 }, @client.send(:parse_arguments, %({"a":1})))
    assert_equal({}, @client.send(:parse_arguments, "{invalid"))
  end

  test "models returns the id list" do
    assert_equal %w[fake-mini fake-pro], @client.models
    assert_equal "GET", @server.requests.first[:method]
  end

  test "HTTP errors raise Ai::Error with status and body" do
    # An empty script: the fake answers 500 "script exhausted"
    error = assert_raises(Ai::Error) do
      @client.chat(model: "fake-mini", messages: [])
    end
    assert_match(/API returned 500/, error.message)
  end

  test "unreachable servers raise Ai::Error" do
    client = Ai::Client.new(base_url: "http://127.0.0.1:1", api_key: "k")
    error = assert_raises(Ai::Error) { client.models }
    assert_match(/could not reach the API/, error.message)
  end

  test "chat with on_delta streams content and tool calls as they accumulate" do
    @server.chat_response(content: "Building your deck", tool_calls: [
      { name: "create_deck", arguments: { name: "French", description: "verbs" } }
    ])
    states = []
    reply = @client.chat(model: "fake-mini", messages: [], tools: [ { type: "function", function: { name: "x" } } ],
                         on_delta: ->(state) { states << state })

    # Deltas arrived incrementally: the last accumulated state is the full text
    assert states.length > 1
    assert_equal "Building your deck", states.last[:content]
    assert states.first[:content].length < "Building your deck".length
    # Tool call names appear in the accumulated state once the header delta lands
    assert_includes states.map { |s| s.dig(:tool_calls, 0, :name) }.compact, "create_deck"

    # The final result matches the non-streaming shape
    assert_equal "Building your deck", reply[:content]
    call = reply[:tool_calls].first
    assert_equal "create_deck", call[:name]
    assert_equal({ "name" => "French", "description" => "verbs" }, call[:arguments])

    # The request actually asked to stream
    assert_equal true, @server.last_chat_request[:body]["stream"]
  end

  test "streaming falls back to a plain completion when the server ignores stream" do
    @server.instance_variable_set(:@streaming, false)
    @server.chat_response(content: "hello", tool_calls: [
      { name: "finish", arguments: { summary: "x" } }
    ])

    reply = @client.chat(model: "fake-mini", messages: [], on_delta: ->(state) { flunk("no deltas expected") })

    assert_equal "hello", reply[:content]
    assert_equal "finish", reply[:tool_calls].first[:name]
  end

  test "base urls tolerate trailing slashes and require a scheme" do
    client = Ai::Client.new(base_url: @server.url + "/", api_key: "k")
    assert_equal %w[fake-mini fake-pro], client.models

    assert_raises(Ai::Error) { Ai::Client.new(base_url: "api.openai.com", api_key: "k") }
  end
end
