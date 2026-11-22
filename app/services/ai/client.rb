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

    def initialize(base_url:, api_key:)
      @base = URI.parse(base_url.to_s.strip.sub(%r{/+\z}, ""))
      raise Error, "invalid base url" unless %w[http https].include?(@base.scheme)

      @api_key = api_key.to_s
    end

    # Returns the assistant message as a plain hash:
    #   { content: String?, tool_calls: [{ id:, name:, arguments: Hash }] }
    # (OpenAI sends tool-call arguments as a JSON *string*.)
    # With `on_delta`, streams: the request sets `stream: true` and
    # on_delta is called (throttled by the caller) with the accumulated
    #   { content: String, tool_calls: [{ id:, name: }] }
    # while chunks arrive — a long generation phase stays visible on the
    # status page instead of appearing all at once. Servers that ignore
    # `stream` and answer with a plain completion are handled too.
    def chat(model:, messages:, tools: [], on_delta: nil)
      return chat_streaming(model, messages, tools, on_delta) if on_delta

      body = { model: model, messages: messages }
      body[:tools] = tools if tools.any?
      data = request(:post, "/chat/completions", body)
      message_from(data)
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

      {
        content: message["content"],
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
    def chat_streaming(model, messages, tools, on_delta)
      body = { model: model, messages: messages, stream: true }
      body[:tools] = tools if tools.any?

      http = new_http
      request = build_request(:post, "/chat/completions", body)
      content = +""
      tool_calls = {}

      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "API returned #{response.code}: #{truncate(response.body)}"
        end

        type = response["content-type"].to_s
        if type.include?("text/event-stream")
          each_sse_data(response) do |payload|
            delta = payload.dig("choices", 0, "delta") || {}
            content << delta["content"].to_s if delta["content"]
            merge_tool_delta(tool_calls, delta["tool_calls"])
            # dup: consumers must not see later mutations of the buffer
            on_delta.call(content: content.dup,
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
