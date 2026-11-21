class Decks::MediaController < ApplicationController
  before_action :require_login

  CHUNK = 64.kilobytes

  # Serves deck media. Hand-rolled HTTP Range support (206 partial content)
  # because audio seeking on mobile requires it; Rails' send_file alone does
  # not honor Range headers.
  def show
    deck = Deck.visible_to(current_user).find(params[:id])
    media = deck.media_files.find_by!(filename: params[:filename])
    path = media.file.blob.service.path_for(media.file.blob.key)
    size = File.size(path)

    response.headers["Cache-Control"] = "public, max-age=86400"
    response.headers["Accept-Ranges"] = "bytes"

    range = parse_range(request.headers["Range"], size)
    if range
      start, finish = range
      response.status = 206
      response.headers["Content-Range"] = "bytes #{start}-#{finish}/#{size}"
      response.headers["Content-Length"] = (finish - start + 1).to_s
      set_media_headers(media)
      self.response_body = RangeBody.new(path, start, finish)
    else
      set_media_headers(media)
      send_file path, filename: media.filename, type: media.content_type, disposition: :inline
    end
  end

  private

  def set_media_headers(media)
    response.headers["Content-Type"] = media.content_type
    response.headers["Content-Disposition"] =
      %(inline; filename="#{media.filename.gsub(/["\\]/, "")}")
  end

  # Parses "bytes=2-5", "bytes=7-" and "bytes=-3" into [start, finish].
  # Returns nil for missing, malformed, multi-range or unsatisfiable ranges
  # (callers then serve the whole file, which is valid HTTP behavior).
  def parse_range(header, size)
    return nil if header.blank?

    m = header.to_s.match(/\Abytes=(\d*)-(\d*)\z/)
    return nil if m.nil? || (m[1].empty? && m[2].empty?)

    if m[1].empty? # suffix: last N bytes
      suffix = m[2].to_i
      return nil if suffix.zero?
      [ [ size - suffix, 0 ].max, size - 1 ]
    elsif m[2].empty?
      [ m[1].to_i, size - 1 ]
    else
      start = m[1].to_i
      finish = m[2].to_i
      return nil if start > finish || start >= size
      [ start, [ finish, size - 1 ].min ]
    end
  end

  # Streams a byte range from disk without loading large media into memory.
  class RangeBody
    def initialize(path, start, finish)
      @path, @start, @finish = path, start, finish
    end

    def each
      File.open(@path, "rb") do |file|
        file.seek(@start)
        remaining = @finish - @start + 1
        while remaining.positive?
          chunk = file.read([ CHUNK, remaining ].min)
          break if chunk.nil?
          remaining -= chunk.bytesize
          yield chunk
        end
      end
    end
  end
end
