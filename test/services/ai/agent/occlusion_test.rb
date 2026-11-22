require "test_helper"

class Ai::Agent::OcclusionTest < ActiveSupport::TestCase
  setup do
    @user = build_user("occl-user")
    @server = FakeOpenAIServer.start
    Ai::Setting.current.update!(base_url: @server.url, api_key: "fake-key",
                               image_base_url: @server.url,
                               image_api_key: "fake-image-key")
    # The labeled diagram and its label-free twin, as the Images API would
    # return them: two black label rectangles on white, then the same image
    # with both labels erased.
    @labeled = MiniPng.b64(width: 100, height: 80,
                           rects: [ [ 10, 10, 8, 6 ], [ 60, 20, 6, 8 ] ])
    @clean = MiniPng.b64(width: 100, height: 80)
    @server.generate_b64 = @labeled
    @server.edit_b64 = @clean
  end

  teardown do
    @server.stop
  end

  def build_generation(prompt: "Neuron occlusion")
    Ai::Generation.create!(user: @user, model: "fake-mini", prompt: prompt, mode: :create_deck,
                           card_limit: 10)
  end

  def script_run(occlusion: "true")
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Occl" } } ])
    @server.chat_response(tool_calls: [
      { name: "generate_image", arguments: { filename: "neuron.png", prompt: "Labeled neuron",
                                             occlusion: occlusion } }
    ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Occlusion", kind: "occlusion",
                                               fields: %w[Image Notes],
                                               front_template: "{{Image}}",
                                               back_template: "{{Image}}<hr>{{Notes}}" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Occlusion",
                                       fields: [ %(<img src="neuron.png">), "Parts of a neuron" ] } }
    ])
  end

  test "occlusion: true edits the labels away, derives masks, and one note makes one card per mask" do
    script_run
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    generation = build_generation
    assert_equal :done, Ai::Agent::DeckBuilder.new(generation).call

    # The label-free twin round-tripped through the edits endpoint and was
    # discarded; only the labeled diagram is deck media.
    media = generation.deck.media_files.find_by!(filename: "neuron.png")
    assert_equal 1, generation.deck.media_files.size
    assert_equal 2, media.masks.size

    edit_request = @server.requests.find { |r| r[:path] == "/images/edits" }
    assert_not_nil edit_request
    assert edit_request[:content_type].start_with?("multipart/form-data")
    assert_includes edit_request[:body], "gpt-image-1-mini"

    # One occlusion note -> two cards, one per mask.
    note = generation.deck.notes.sole
    assert_equal 2, note.cards.size
    assert generation.journal.any? { |e| e["type"] == "status" && e["masks"] == 2 }
  end

  test "the question side covers one label; the answer side reveals it" do
    script_run
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])
    generation = build_generation
    Ai::Agent::DeckBuilder.new(generation).call

    card = generation.deck.cards.find_by!(template_ord: 0)
    question = CardHtml.render(card, side: :question, media_url: ->(f) { "/media/#{f}" })
    answer = CardHtml.render(card, side: :answer, media_url: ->(f) { "/media/#{f}" })

    assert_includes question, %(<span class="occl-wrap">)
    assert_includes question, %(class="occl-mask" style="left:10.0%;top:12.5%;width:8.0%;height:7.5%")
    assert_not_includes answer, "occl-mask"
    assert_includes answer, %(<img src="/media/neuron.png">)

    # Card 2 covers the other label (60, 20 on a 100x80 canvas).
    card2 = generation.deck.cards.find_by!(template_ord: 1)
    question2 = CardHtml.render(card2, side: :question, media_url: ->(f) { "/media/#{f}" })
    assert_includes question2, %(style="left:60.0%;top:25.0%;width:6.0%;height:10.0%")
  end

  test "an occlusion note without masks still gets a plain single card" do
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Occl" } } ])
    @server.chat_response(tool_calls: [
      { name: "upsert_note_type", arguments: { name: "Occlusion", kind: "occlusion",
                                               fields: %w[Image Notes],
                                               front_template: "{{Image}}",
                                               back_template: "{{Image}}<hr>{{Notes}}" } }
    ])
    @server.chat_response(tool_calls: [
      { name: "add_note", arguments: { note_type: "Occlusion",
                                       fields: [ %(<img src="picture.png">), "No masks" ] } }
    ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "done" } } ])

    generation = build_generation
    assert_equal :done, Ai::Agent::DeckBuilder.new(generation).call

    note = generation.deck.notes.sole
    assert_equal 1, note.cards.size
    assert_not_includes CardHtml.render(note.cards.sole, side: :question,
                                         media_url: ->(f) { "/media/#{f}" }), "occl-mask"
  end
end
