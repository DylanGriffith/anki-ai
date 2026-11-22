require "test_helper"

class Ai::Agent::GenerateImageTest < ActiveSupport::TestCase
  setup do
    @user = build_user("ai-image-user")
    @server = FakeOpenAIServer.start
    Ai::Setting.current.update!(base_url: @server.url, api_key: "fake-key",
                               image_base_url: @server.url, image_api_key: "fake-image-key")
  end

  teardown do
    @server.stop
  end

  def build_generation(prompt: "Neuron parts")
    Ai::Generation.create!(user: @user, model: "fake-mini", prompt: prompt, mode: :create_deck,
                           card_limit: 3)
  end

  test "generate_image is offered and attaches usable media to the deck" do
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Neurons" } } ])
    @server.chat_response(tool_calls: [
      { name: "generate_image", arguments: { filename: "neuron.png",
                                            prompt: "Labeled diagram of a neuron" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic", fields: [ "Look at the picture", "x" ] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    generation = build_generation
    assert_equal :done, Ai::Agent::DeckBuilder.new(generation).call

    # The tool was offered between upsert_note_type and add_note
    tool_names = @server.chat_requests.first[:body]["tools"].map { |t| t.dig("function", "name") }
    assert_equal %w[create_deck upsert_note_type generate_image add_note update_note
                    delete_note list_notes search_notes finish], tool_names

    media = generation.deck.media_files.take
    assert_not_nil media
    assert_equal "neuron.png", media.filename
    assert_equal "image/png", media.content_type
    assert media.file.blob.present?
    assert media.file.blob.byte_size.positive?
    assert_equal "image/png", media.file.blob.content_type

    # The images request hit the OpenAI shape: defaults verified by the live
    # spike (gpt-image-1-mini at medium renders correct label text)
    image_request = @server.requests.find { |r| r[:path] == "/images/generations" }
    assert_equal "gpt-image-1-mini", image_request[:body]["model"]
    assert_equal "medium", image_request[:body]["quality"]
    assert_equal "1024x1024", image_request[:body]["size"]
    assert_equal "Bearer fake-image-key", image_request[:auth]
  end

  test "a base url with a path segment keeps its path (e.g. .../v1)" do
    Ai::Setting.current.update!(image_base_url: "#{@server.url}/v1")
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Neurons" } } ] )
    @server.chat_response(tool_calls: [
      { name: "generate_image", arguments: { filename: "neuron.png", prompt: "a neuron" } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ] )

    generation = build_generation
    assert_equal :done, Ai::Agent::DeckBuilder.new(generation).call

    # RFC-3986 merge drops the last path segment of a base without a trailing
    # slash; the client must not, or https://api.openai.com/v1 404s.
    assert_equal "/v1/images/generations",
                 @server.requests.find { |r| r[:path].end_with?("/images/generations") }[:path]
    assert_not_nil generation.deck.media_files.find_by(filename: "neuron.png")
  end

  test "the generated image renders in card HTML via the deck media route" do
    basic = { name: "Basic", fields: %w[Front Back],
              front_template: "{{Front}}", back_template: "{{FrontSide}}<hr>{{Back}}" }
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Neurons" } } ])
    @server.chat_response(tool_calls: [ { name: "upsert_note_type", arguments: basic } ])
    @server.chat_response(tool_calls: [
      { name: "generate_image", arguments: { filename: "neuron.png", prompt: "a neuron" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Basic",
                                      fields: [ "<img src=\"neuron.png\">", "the picture" ] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    generation = build_generation
    Ai::Agent::DeckBuilder.new(generation).call

    card = generation.deck.cards.take
    html = CardHtml.render(card, side: :question,
                            media_url: ->(f) { "/media/#{f}" })
    assert_includes html, %(<img src="/media/neuron.png">)
  end

  test "generate_image errors are recoverable tool results" do
    @server.images_fail = true
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Neurons" } } ])
    @server.chat_response(tool_calls: [
      { name: "generate_image", arguments: { filename: "neuron.png", prompt: "a neuron" } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    generation = build_generation
    result = Ai::Agent::DeckBuilder.new(generation).call

    assert_equal :done, result # one failed image does not fail the run
    assert generation.deck.media_files.empty?
    assert generation.journal.any? do |e|
      e["type"] == "tool" && e["name"] == "generate_image" && e["error"]
    end
  end

  test "bad filenames, duplicate names and the per-run cap are refused" do
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Neurons" } } ])
    @server.chat_response(tool_calls: [
      # Path separators and spaces are rejected up front (no API call)
      { name: "generate_image", arguments: { filename: "../evil.png", prompt: "x" } },
      { name: "generate_image", arguments: { filename: "mic phone.png", prompt: "x" } },
      # OK — the run's only successful generation
      { name: "generate_image", arguments: { filename: "good.png", prompt: "a diagram" } },
      # Same name again: refuse rather than overwrite
      { name: "generate_image", arguments: { filename: "good.png", prompt: "another diagram" } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    generation = build_generation
    assert_equal :done, Ai::Agent::DeckBuilder.new(generation).call

    names = generation.deck.media_files.map(&:filename)
    assert_equal %w[good.png], names

    image_error = @server.tool_results.find { |r| r["error"].to_s.include?("evil.png") }
    assert_not_nil image_error
    dup_error = @server.tool_results.find { |r| r["error"].to_s.include?("already exists") }
    assert_not_nil dup_error
  end

  test "without image configuration the tool is not offered" do
    Ai::Setting.current.update!(image_base_url: nil, image_api_key: nil)
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Neurons" } } ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    Ai::Agent::DeckBuilder.new(build_generation).call

    tool_names = @server.chat_requests.first[:body]["tools"].map { |t| t.dig("function", "name") }
    assert_not_includes tool_names, "generate_image"
  end
end
