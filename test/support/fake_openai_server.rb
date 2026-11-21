require "puma/server"

# A scripted, local OpenAI-compatible API for tests — the agent's client
# makes REAL Net::HTTP calls against it, so the full HTTP path (headers,
# JSON bodies, error handling) is exercised without any network access.
#
#   server = FakeOpenAIServer.start
#   server.chat_response(tool_calls: [{ name: "create_deck", arguments: { name: "X" } }])
#   Ai::Setting.current.update!(base_url: server.url, api_key: "fake-key")
#   ... the agent's next chat request pops that scripted response ...
#
# Each scripted entry is used once, in order; an exhausted script serves 500
# (which the client surfaces as Ai::Error).
class FakeOpenAIServer
  class App
    def initialize(server)
      @server = server
    end

    def call(env)
      body = env["rack.input"].read
      @server.requests << { method: env["REQUEST_METHOD"], path: env["PATH_INFO"],
                            auth: env["HTTP_AUTHORIZATION"], body: body.empty? ? nil : JSON.parse(body) }
      case [ env["REQUEST_METHOD"], env["PATH_INFO"] ]
      in [ "GET", "/models" ]
        json(200, { object: "list", data: @server.models.map { |id| { id: id } } })
      in [ "POST", "/chat/completions" ]
        entry = @server.next_chat_response
        return json(500, { error: { message: "script exhausted" } }) unless entry

        json(200, { id: "chatcmpl-fake", object: "chat.completion",
                    choices: [ { index: 0, message: message_for(entry), finish_reason: "tool_calls" } ] })
      else
        json(404, { error: { message: "no such endpoint" } })
      end
    rescue JSON::ParserError
      json(400, { error: { message: "invalid JSON" } })
    end

    private

    def message_for(entry)
      if entry[:error]
        { role: "assistant", content: entry[:error] }
      else
        { role: "assistant", content: entry[:content],
          tool_calls: Array(entry[:tool_calls]).map do |call|
            { id: "call-#{call.object_id}", type: "function",
              function: { name: call[:name], arguments: JSON.generate(call[:arguments] || {}) } }
          end }
      end
    end

    def json(status, payload)
      [ status, { "Content-Type" => "application/json" }, [ JSON.generate(payload) ] ]
    end
  end

  attr_reader :models, :requests

  def initialize(models: %w[fake-mini fake-pro])
    @models = models
    @script = []
    @requests = []
    @mutex = Mutex.new
  end

  def self.start(**options)
    new(**options).tap(&:start)
  end

  def start
    @server = Puma::Server.new(App.new(self))
    tcp = @server.add_tcp_listener("127.0.0.1", 0)
    @port = tcp.addr[1]
    @server.run
    self
  end

  def stop
    @server&.stop(true)
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  # Queue one scripted assistant turn: content and/or tool_calls
  # ({ name:, arguments: } hashes). `error:` serves a plain-content
  # assistant message instead. A block is evaluated when the request
  # arrives, so scripted arguments can depend on earlier tool results
  # (exactly what a real model does):
  #   server.chat_response do |srv|
  #     { tool_calls: [{ name: "update_note",
  #                      arguments: { note_id: srv.tool_results(-2)["note_id"] } }] }
  #   end
  def chat_response(content: nil, tool_calls: [], error: nil, &block)
    @script << (block || ->(_server) { { content: content, tool_calls: tool_calls, error: error } })
    self
  end

  def next_chat_response
    @mutex.synchronize do
      entry = @script.shift
      entry.is_a?(Proc) ? entry.call(self) : entry
    end
  end

  # Parsed tool results (the "role": "tool" messages) from the most recent
  # chat request — the agent's own tool outputs, as the model saw them. The
  # current request is already recorded by the time a block script runs, so
  # this includes everything the model gets to see for that turn.
  def tool_results(offset = -1)
    request = chat_requests[offset] or return []
    request[:body]["messages"].select { |m| m["role"] == "tool" }
              .map { |m| JSON.parse(m["content"]) }
  end

  def chat_requests
    requests.select { |r| r[:path] == "/chat/completions" }
  end

  def last_chat_request
    chat_requests.last
  end
end
