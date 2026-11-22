require "net/http"
require "tempfile"

module Ai
  # Minimal OpenAI Images API client over Net::HTTP — no SDK, one endpoint:
  #   POST {base_url}/images/generations  { model, prompt, size, quality }
  # Responses carry base64 image bytes (gpt-image models) or a URL (some
  # OpenAI-compatible servers) — both are handled.
  class ImagesClient
    # Verified against the live API (Nov 2026 spike): gpt-image-2 at medium
    # quality renders correctly-spelled diagram labels; the mini tier at low
    # quality garbles text ("nucteus"), which would poison the cards.
    DEFAULT_MODEL = "gpt-image-2"
    DEFAULT_SIZE = "1024x1024"
    DEFAULT_QUALITY = "medium"

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120
    PROMPT_MAX = 4_000

    def initialize(base_url:, api_key:)
      @base = URI.parse(base_url.to_s.strip.sub(%r{/+\z}, ""))
      raise Error, "invalid base url" unless %w[http https].include?(@base.scheme)

      @api_key = api_key.to_s
    end

    # Returns { prompt:, size:, bytes: (binary image), content_type: }.
    def generate(prompt:, model: DEFAULT_MODEL, size: DEFAULT_SIZE, quality: DEFAULT_QUALITY)
      body = { model: model, prompt: prompt.to_s.strip.truncate(PROMPT_MAX),
               size: size, quality: quality }
      data = request(body)
      item = Array(data["data"]).first
      raise Error, "images API returned no image data" if item.nil?

      if item["b64_json"].present?
        { prompt: prompt.to_s, size: size, bytes: item["b64_json"].unpack1("m"),
          content_type: "image/png" }
      elsif (url = item["url"]).present?
        download(url).merge(prompt: prompt.to_s, size: size)
      else
        raise Error, "images API response has neither b64_json nor url"
      end
    end

    private

    def request(body)
      uri = URI.join(@base, "images/generations")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      response = http.post(uri, JSON.generate(body),
                           "Content-Type" => "application/json",
                           "Accept" => "application/json",
                           "Authorization" => "Bearer #{@api_key}")
      parse(response)
    end

    def parse(response)
      data = JSON.parse(response.body.to_s)
      return data if response.is_a?(Net::HTTPSuccess)

      raise Error, data.dig("error", "message") || "images API failed: #{response.code}"
    rescue JSON::ParserError
      raise Error, "images API returned invalid JSON (HTTP #{response.code})"
    end

    def download(url)
      uri = URI.parse(url)
      raise Error, "invalid image url" unless %w[http https].include?(uri.scheme)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      response = http.get(uri)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "image download failed: HTTP #{response.code}"
      end

      { bytes: response.body, content_type: response["Content-Type"].to_s.split(";").first.presence || "image/png" }
    end
  end
end
