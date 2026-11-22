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
        if @server.reject_max_tokens? && @server.requests.last[:body]["max_tokens"]
          return json(400, { error: { message: "Unsupported parameter: 'max_tokens' is not " \
                                              "supported with this model." } })
        end

        entry = @server.next_chat_response
        return json(500, { error: { message: "script exhausted" } }) unless entry

        if @server.requests.last[:body]["stream"] && @server.streaming?
          sse_stream(entry)
        else
          json(200, { id: "chatcmpl-fake", object: "chat.completion",
                      choices: [ { index: 0, message: message_for(entry), finish_reason: "tool_calls" } ] })
        end
      else
        json(404, { error: { message: "no such endpoint" } })
      end
    rescue JSON::ParserError
      json(400, { error: { message: "invalid JSON" } })
    end

    private

    # Server-Sent Events stream, like a real OpenAI-compatible server:
    # text and tool-call arguments split across multiple deltas, in the
    # dialects real providers use:
    #   entry[:thinking]  -> reasoning as ARRAY content parts (GLM-style
    #                        thinking models: {"type" => "thinking",
    #                        "thinking" => [{"type" => "text", ...}]})
    #   entry[:reasoning] -> reasoning as a delta `reasoning` string field
    #                        (DeepSeek-style)
    #   entry[:loop]      -> N identical thinking-part deltas with no end
    #                        in sight (the degenerate model that streams
    #                        the same segment forever)
    #   entry[:tool_dialect] -> how tool-call fragments are shaped:
    #     :standard (default)  OpenAI shape — header delta, then
    #                          argument-only deltas
    #     :blank_name_echo     Mistral/GLM (confirmed against
    #                          api.mistral.ai, 2026-11): the header carries
    #                          name + the FIRST argument slice, and every
    #                          continuation fragment echoes `"name": ""`
    #     :name_pieces         providers (vLLM & friends) that stream the
    #                          function name itself across fragments
    def sse_stream(entry)
      events = []
      if entry[:error]
        events << { choices: [ { index: 0, delta: { role: "assistant" } } ] }
        entry[:error].to_s.chars.each_slice(40) do |slice|
          events << { choices: [ { index: 0, delta: { content: slice.join } } ] }
        end
      else
        events << { choices: [ { index: 0, delta: { role: "assistant", content: nil } } ] }
        if entry[:loop]
          entry[:loop].times do
            events << { choices: [ { index: 0, delta: { content: [ thinking_part("}^{A}^{A", true) ] } } ] }
          end
        else
          if entry[:reasoning]
            entry[:reasoning].to_s.chars.each_slice(8) do |slice|
              events << { choices: [ { index: 0, delta: { reasoning: slice.join } } ] }
            end
          end
          if entry[:thinking]
            entry[:thinking].to_s.chars.each_slice(8) do |slice|
              events << { choices: [ { index: 0, delta: { content: [ thinking_part(slice.join, false) ] } } ] }
            end
            events << { choices: [ { index: 0, delta: { content: [ thinking_part("", true) ] } } ] }
          end
          entry[:content].to_s.chars.each_slice(8).each do |slice|
            events << { choices: [ { index: 0, delta: { content: slice.join } } ] }
          end
          stream_tool_calls(entry, events)
        end
      end
      events << { choices: [ { index: 0, delta: {}, finish_reason: "tool_calls" } ] }

      # Each SSE event split mid-line into two chunks, so the client's
      # incremental buffer handling (partial lines across reads) is
      # genuinely exercised.
      body = events.flat_map do |event|
        text = "data: #{JSON.generate(event)}\n\n"
        half = (text.length / 2.0).ceil
        [ text[0, half], text[half..] ]
      end << "data: [DONE]\n\n"
      [ 200, { "Content-Type" => "text/event-stream" }, body ]
    end

    def stream_tool_calls(entry, events)
      dialect = entry[:tool_dialect]
      Array(entry[:tool_calls]).each_with_index do |call, index|
        id = "call-#{call.object_id}"
        slices = JSON.generate(call[:arguments] || {}).chars.each_slice(12).map(&:join)
        if dialect == :name_pieces
          call[:name].to_s.chars.each_slice(6).each do |piece|
            events << tool_call_delta(index, index: index, id: id, type: "function",
                                            function: { name: piece.join, arguments: "" })
          end
          slices.each do |slice|
            events << tool_call_delta(index, index: index, function: { arguments: slice })
          end
        elsif dialect == :blank_name_echo
          # Header fragment carries the name AND the first argument slice;
          # continuations echo a blank name (which must not clobber it).
          header = { index: index, id: id, type: "function",
                     function: { name: call[:name], arguments: slices.shift.to_s } }
          events << tool_call_delta(index, header)
          slices.each do |slice|
            events << tool_call_delta(index, index: index,
                                            function: { name: "", arguments: slice })
          end
        else
          events << tool_call_delta(index, index: index, id: id, type: "function",
                                         function: { name: call[:name], arguments: "" })
          slices.each do |slice|
            events << tool_call_delta(index, index: index, function: { arguments: slice })
          end
        end
      end
    end

    def tool_call_delta(index, fragment)
      { choices: [ { index: 0, delta: { tool_calls: [ fragment ] } } ] }
    end

    def thinking_part(text, closed)
      { type: "thinking", thinking: [ { type: "text", text: text } ], closed: closed }
    end

    # The plain-completion dialects: thinking models return content as an
    # array of parts; DeepSeek-style servers put reasoning in its own field.
    def message_for(entry)
      if entry[:error]
        { role: "assistant", content: entry[:error] }
      else
        content = entry[:thinking] ? [ thinking_part(entry[:thinking], true),
                                       { type: "text", text: entry[:content].to_s } ]
                                   : entry[:content]
        message = { role: "assistant", content: content }
        message[:reasoning] = entry[:reasoning] if entry[:reasoning]
        message[:tool_calls] = Array(entry[:tool_calls]).map do |call|
          { id: "call-#{call.object_id}", type: "function",
            function: { name: call[:name], arguments: JSON.generate(call[:arguments] || {}) } }
        end
        message
      end
    end

    def json(status, payload)
      [ status, { "Content-Type" => "application/json" }, [ JSON.generate(payload) ] ]
    end
  end

  attr_reader :models, :requests

  # Reject max_tokens with OpenAI's o-series error (for the retry test).
  def reject_max_tokens=(flag)
    @reject_max_tokens = flag
  end

  def reject_max_tokens?
    !!@reject_max_tokens
  end

  def initialize(models: %w[fake-mini fake-pro], streaming: true)
    @models = models
    @streaming = streaming
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

  def streaming?
    @streaming
  end

  # Queue one scripted assistant turn: content and/or tool_calls
  # ({ name:, arguments: } hashes). `error:` serves a plain-content
  # assistant message instead. `thinking:` / `reasoning:` script the
  # reasoning dialects (content-part arrays / delta string field),
  # `loop:` a degenerate never-ending stream. A block is evaluated when
  # the request arrives, so scripted arguments can depend on earlier tool
  # results (exactly what a real model does):
  #   server.chat_response do |srv|
  #     { tool_calls: [{ name: "update_note",
  #                      arguments: { note_id: srv.tool_results(-2)["note_id"] } }] }
  #   end
  def chat_response(content: nil, tool_calls: [], error: nil, thinking: nil, reasoning: nil,
                    loop: nil, tool_dialect: nil, &block)
    @script << (block || ->(_server) { { content: content, tool_calls: tool_calls, error: error,
                                         thinking: thinking, reasoning: reasoning, loop: loop,
                                         tool_dialect: tool_dialect } })
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
