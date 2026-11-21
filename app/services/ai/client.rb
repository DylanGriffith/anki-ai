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
    def chat(model:, messages:, tools: [])
      body = { model: model, messages: messages }
      body[:tools] = tools if tools.any?
      data = request(:post, "/chat/completions", body)
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

    # Model ids for the dropdown.
    def models
      data = request(:get, "/models")
      Array(data["data"]).map { |m| m["id"] }.compact
    end

    private

    def parse_arguments(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      {} # a malformed tool call becomes "no arguments"; the agent tool
      # then answers with an error the model can fix on its next turn
    end

    def request(method, path, body = nil)
      http = Net::HTTP.new(@base.host, @base.port)
      http.use_ssl = @base.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

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
