require "net/http"

module Ai
  class Error < StandardError; end

  # Minimal OpenAI-compatible chat client over Net::HTTP — no SDK, just the
  # two endpoints the agent loop needs:
  #   POST {base_url}/chat/completions  (messages + tools)
  #   GET  {base_url}/models            (model list for the dropdown)
  # Works against OpenAI, OpenRouter, LM Studio, Ollama's compat layer, etc.
  class Client
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120

    # Bounds on the model's output. max_tokens asks the server to stop
    # cleanly (a degenerate model looping on one segment otherwise streams
    # forever — read timeouts are per-chunk, so an endless stream never
    # times out; thinking models also burn many tokens on reasoning, so
    # this is generous). max_chars is the client-side hard stop for servers
    # that ignore it — a bounded reply can never reach it. A 400 that
    # blames max_tokens (o-series models, output ceilings) is retried
    # without it.
    DEFAULT_MAX_TOKENS = 16_384
    DEFAULT_MAX_CHARS = 128_000

    def initialize(base_url:, api_key:)
      @base = URI.parse(base_url.to_s.strip.sub(%r{/+\z}, ""))
      raise Error, "invalid base url" unless %w[http https].include?(@base.scheme)

      @api_key = api_key.to_s
    end

    # Returns the assistant message as a plain hash:
    #   { content: String?, thinking: String?, tool_calls: [{ id:, name:, arguments: Hash }] }
    # (OpenAI sends tool-call arguments as a JSON *string*.) `thinking` is
    # the model's reasoning, kept separate from content (see absorb_delta).
    # With `on_delta`, streams: the request sets `stream: true` and
    # on_delta is called with the accumulated
    #   { content: String, thinking: String, tool_calls: [{ id:, name: }] }
    # while chunks arrive — a long generation phase stays visible on the
    # status page instead of appearing all at once. Servers that ignore
    # `stream` and answer with a plain completion are handled too.
    def chat(model:, messages:, tools: [], on_delta: nil,
             max_tokens: DEFAULT_MAX_TOKENS, max_chars: DEFAULT_MAX_CHARS)
      return chat_streaming(model, messages, tools, on_delta, max_tokens, max_chars) if on_delta

      body = { model: model, messages: messages }
      body[:tools] = tools if tools.any?
      body[:max_tokens] = max_tokens if max_tokens
      message_from(chat_request(body))
    end

    # Model ids for the dropdown.
    def models
      data = request(:get, "/models")
      Array(data["data"]).map { |m| m["id"] }.compact
    end

    private

    def message_from(data)
      message = data.dig("choices", 0, "message")
      raise Error, "chat response has no message" unless message.is_a?(Hash)

      content = +""
      thinking = +""
      absorb_message_content(message["content"], content, thinking)
      thinking << message["reasoning"] if message["reasoning"].is_a?(String)
      thinking << message["reasoning_content"] if message["reasoning_content"].is_a?(String)

      {
        content: content.presence,
        thinking: thinking.presence,
        tool_calls: Array(message["tool_calls"]).map do |call|
          {
            id: call["id"],
            name: call.dig("function", "name"),
            arguments: parse_arguments(call.dig("function", "arguments"))
          }
        end
      }
    end

    # Streaming chat: Server-Sent Events, one JSON delta per "data:" line.
    # Tool-call arguments arrive as fragments keyed by an index; text as
    # content deltas. Returns the same shape as the non-streaming path.
    def chat_streaming(model, messages, tools, on_delta, max_tokens, max_chars)
      body = { model: model, messages: messages, stream: true }
      body[:tools] = tools if tools.any?
      body[:max_tokens] = max_tokens if max_tokens

      begin
        stream_response(body, on_delta, max_chars)
      rescue Error => e
        # OpenAI's o-series models reject `max_tokens`; retry once without
        # it (the char cap still bounds the stream).
        raise unless e.message.include?("400") && e.message.match?(/max_tokens/i)

        stream_response(body.except(:max_tokens), on_delta, max_chars)
      end
    end

    def stream_response(body, on_delta, max_chars)
      http = new_http
      request = build_request(:post, "/chat/completions", body)
      content = +""
      thinking = +""
      tool_calls = {}

      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "API returned #{response.code}: #{truncate(response.body)}"
        end

        if response["content-type"].to_s.include?("text/event-stream")
          each_sse_data(response) do |payload|
            delta = payload.dig("choices", 0, "delta") || {}
            absorb_delta(delta, content, thinking)
            merge_tool_delta(tool_calls, delta["tool_calls"])
            if content.length + thinking.length > max_chars
              raise Error, "model streamed more than #{max_chars} characters without " \
                           "finishing — it looks stuck in a loop; aborting"
            end
            # dup: consumers must not see later mutations of the buffers
            on_delta.call(content: content.dup, thinking: thinking.dup,
                          tool_calls: tool_calls.values_at(*tool_calls.keys.sort)
                                               .map { |c| { id: c[:id], name: c[:name] } })
          end
        else
          # Server ignored `stream` and sent a plain completion.
          return message_from(JSON.parse(response.body))
        end
      end

      {
        content: content.presence,
        thinking: thinking.presence,
        tool_calls: tool_calls.values_at(*tool_calls.keys.sort).map do |c|
          { id: c[:id], name: c[:name], arguments: parse_arguments(c[:arguments]) }
        end
      }
    rescue JSON::ParserError => e
      raise Error, "API returned invalid JSON: #{truncate(e.message)}"
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
           OpenSSL::SSL::SSLError, SocketError => e
      raise Error, "could not reach the API: #{e.class} #{e.message}"
    end

    # Content deltas come in several dialects and must never be #to_s'd
    # wholesale: a plain String (most servers), a `reasoning` /
    # `reasoning_content` String (DeepSeek-style), or an Array of typed
    # parts (thinking models, e.g.
    #   [{"type" => "thinking", "thinking" => [{"type" => "text", "text" => "…"}]}]
    # ). Only real answer text reaches the content buffer; reasoning goes
    # to its own buffer so the UI can show (and cap) it separately.
    def absorb_delta(delta, content, thinking)
      absorb_message_content(delta["content"], content, thinking)
      thinking << delta["reasoning"] if delta["reasoning"].is_a?(String)
      thinking << delta["reasoning_content"] if delta["reasoning_content"].is_a?(String)
    end

    def absorb_message_content(value, content, thinking)
      case value
      when String then content << value
      when Array then value.each { |part| absorb_part(part, content, thinking) }
      when Hash then absorb_part(value, content, thinking)
      end
    end

    def absorb_part(part, content, thinking)
      return unless part.is_a?(Hash)

      case part["type"]
      when "thinking", "reasoning"
        Array(part["thinking"] || part["reasoning"]).each do |chunk|
          thinking << chunk["text"] if chunk.is_a?(Hash) && chunk["text"].is_a?(String)
        end
        thinking << part["text"] if part["text"].is_a?(String)
      else # "text", or a part with no type carrying plain text
        content << part["text"] if part["text"].is_a?(String)
      end
    end

    # Tool-call deltas: the first fragment carries id + function name, later
    # fragments append to the arguments string.
    def merge_tool_delta(tool_calls, deltas)
      Array(deltas).each do |delta|
        index = delta["index"] || 0
        call = tool_calls[index] ||= { id: nil, name: nil, arguments: +"" }
        call[:id] = delta["id"] if delta["id"]
        call[:name] = delta.dig("function", "name") if delta.dig("function", "name")
        call[:arguments] << delta.dig("function", "arguments").to_s
      end
    end

    # Yields each SSE "data:" payload (JSON-parsed); "[DONE]" ends the stream.
    def each_sse_data(response)
      buffer = +""
      response.read_body do |chunk|
        buffer << chunk
        while (line = buffer.slice!(/\A[^\n]*\n/))
          data = line.strip.sub(/\Adata:\s?/, "")
          next if data.empty? || data.start_with?(":")
          return if data == "[DONE]"

          yield JSON.parse(data)
        end
      end
    end

    def new_http
      http = Net::HTTP.new(@base.host, @base.port)
      http.use_ssl = @base.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http
    end

    def parse_arguments(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      {} # a malformed tool call becomes "no arguments"; the agent tool
      # then answers with an error the model can fix on its next turn
    end

    def request(method, path, body = nil)
      http = new_http
      request = build_request(method, path, body)
      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "API returned #{response.code}: #{truncate(response.body)}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "API returned invalid JSON: #{truncate(response&.body || e.message)}"
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
           OpenSSL::SSL::SSLError, SocketError => e
      raise Error, "could not reach the API: #{e.class} #{e.message}"
    end

    # POST /chat/completions for the non-streaming path, with the
    # max_tokens-rejected retry shared with the streaming path.
    def chat_request(body)
      request(:post, "/chat/completions", body)
    rescue Error => e
      raise unless e.message.include?("400") && e.message.match?(/max_tokens/i)

      request(:post, "/chat/completions", body.except(:max_tokens))
    end

    def build_request(method, path, body)
      klass = method == :get ? Net::HTTP::Get : Net::HTTP::Post
      request = klass.new(URI.join(@base.to_s + "/", path.sub(%r{\A/+}, "")))
      request["Authorization"] = "Bearer #{@api_key}" if @api_key.present?
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      request
    end

    def truncate(text)
      text.to_s.gsub(/\s+/, " ").truncate(300)
    end
  end
end
