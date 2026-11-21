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
    generation.log!(type: "assistant", text: "Building…")
    deck = @user.decks.create!(name: "Shown")
    generation.update!(status: :done, deck: deck)

    get ai_generation_url(generation)
    assert_response :success
    assert_text "Building…"
    assert_match(/Open deck/, @response.body)
    assert_no_match(/setTimeout/, @response.body) # done: no polling script
  end

  test "show polls while running" do
    generation = Ai::Generation.create!(user: @user, model: "fake-mini", prompt: "test")
    generation.update!(status: :running)
    get ai_generation_url(generation)
    assert_response :success
    assert_match(/setTimeout/, @response.body)
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
