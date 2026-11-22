require "test_helper"

class Ai::GenerationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = build_user("ai-web")
    post login_path, params: { name: @user.name, password: "password123" }
    @server = FakeOpenAIServer.start
    Ai::Setting.current.update!(base_url: @server.url, api_key: "fake-key")
  end

  teardown do
    @server.stop
  end

  test "new shows the model dropdown from the API list" do
    get new_ai_generation_url
    assert_response :success
    assert_select "select#model option", count: 2
    assert_select "option[value=fake-mini]", text: "fake-mini"
    assert_select "option[value=fake-pro]", text: "fake-pro"
    # The list was cached for next time
    assert_equal %w[fake-mini fake-pro], Ai::Setting.current.models
  end

  test "new falls back to a free-text model field when the API is unreachable" do
    Ai::Setting.current.update!(base_url: "http://127.0.0.1:1", api_key: "k")
    get new_ai_generation_url
    assert_response :success
    assert_select "input#model"
    assert_select "select#model", count: 0
  end

  test "create enqueues and (inline) runs the generation, then redirects to its page" do
    @server.chat_response(tool_calls: [ { name: "create_deck", arguments: { name: "Web Deck" } } ])
    @server.chat_response(tool_calls: [ { name: "finish", arguments: { summary: "built" } } ])

    assert_difference -> { @user.ai_generations.count }, 1 do
      post ai_generations_url, params: { prompt: "tiny deck", model: "fake-mini" }
    end
    assert_redirected_to ai_generation_path(Ai::Generation.last)

    # The inline adapter already ran the job: the deck exists
    generation = Ai::Generation.last
    assert generation.done?
    assert_equal "Web Deck", generation.deck.name
  end

  test "create without a prompt bounces back with an error" do
    assert_no_difference -> { Ai::Generation.count } do
      post ai_generations_url, params: { prompt: "  ", model: "fake-mini" }
    end
    assert_redirected_to new_ai_generation_path
    assert_match(/prompt/i, flash[:alert])
  end

  test "show renders the transcript and links the deck" do
    generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
    generation.log!(type: "assistant", text: "Building…", thinking: "weighing the options")
    generation.log!(type: "tool", name: "add_note", arguments: { note_type: "Basic" },
                    result: { note_id: 1 }, error: false)
    deck = @user.decks.create!(name: "Shown")
    generation.update!(status: :done, deck: deck)

    get ai_generation_url(generation)
    assert_response :success
    assert_text "Building…"
    # Compact transcript: one collapsed row per entry, tool name in the summary
    assert_select "details.transcript-entry", count: 2
    assert_select "details.transcript-entry[open]", count: 0
    assert_select "details.transcript-entry--tool summary", text: "add_note"
    assert_select ".transcript-thinking", text: /weighing the options/
    # Green dot for done, and the status marker the JS poller keys off
    assert_select ".status-dot.status-dot--done", count: 1
    assert_select ".generation-status[data-generation-status=done]", count: 1
    assert_match(/Open deck/, @response.body)
  end

  test "show polls while running" do
    generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
    generation.update!(status: :running)
    generation.log_stream!(text: "Buil", thinking: "let me think",
                           tool_calls: [ { id: "call_1", name: "create_deck" } ], chars: 18)
    get ai_generation_url(generation)
    assert_response :success
    assert_select ".status-dot.status-dot--running", count: 1
    # The in-progress assistant entry shows what's streaming so far
    assert_select "details.transcript-entry--assistant summary", text: /thinking…/
    assert_select "details.transcript-entry--assistant summary", text: /create_deck/
    # …with a visible live preview line and a char counter
    assert_select ".stream-preview", text: /Buil/
    assert_select ".stream-preview", text: /18 chars/
    # The JS poller (application.js) refreshes while the marker says running
    assert_select ".generation-status[data-generation-status=running]", count: 1
  end

  test "show marks failed generations with a red dot and the error" do
    generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
    generation.update!(status: :failed, error: "connection refused")
    get ai_generation_url(generation)
    assert_response :success
    assert_select ".status-dot.status-dot--failed", count: 1
    assert_match(/Generation failed/, @response.body)
  end

  test "generations are only visible to their owner" do
    generation = Ai::Generation.create!(user: @user, model: "m", prompt: "p")
    build_user("ai-other")
    post login_path, params: { name: "ai-other", password: "password123" }
    get ai_generation_url(generation)
    assert_response :not_found
  end

  test "everything requires login" do
    delete logout_path
    get new_ai_generation_url
    assert_redirected_to login_path
    post ai_generations_url, params: { prompt: "x", model: "m" }
    assert_redirected_to login_path
  end

  test "unconfigured AI bounces with a hint to run the rake task" do
    Ai::Setting.current.destroy # reset singleton
    post login_path, params: { name: @user.name, password: "password123" }

    get new_ai_generation_url
    assert_redirected_to decks_path
    assert_match(/rake ai:config/, flash[:alert])

    post ai_generations_url, params: { prompt: "x", model: "m" }
    assert_redirected_to decks_path
  end

  private

  def assert_text(text)
    assert_includes @response.body, text
  end
end
