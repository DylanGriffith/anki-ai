# Minimal PNG writer for tests: an 8-bit RGB image, white background, with
# optional solid black rectangles (stand-ins for the label text an image-
# generation model would produce). Exercises the app's real PNG decoder and
# pixel-diff path without binary fixtures.
module MiniPng
  module_function

  def png(width:, height:, rects: [])
    line = 255.chr * (width * 3)
    rows = Array.new(height) { line.dup }
    rects.each do |(x, y, w, h)|
      (y...[ y + h, height ].min).each do |yy|
        (x...[ x + w, width ].min).each do |xx|
          rows[yy][xx * 3, 3] = "\x00\x00\x00".b
        end
      end
    end
    raw = rows.map { |r| 0.chr.b + r }.join
    chunks = ihdr(width, height) + idat(raw) + iend
    ["\x89PNG\r\n\x1a\n".b, chunks].join
  end

  def b64(**kwargs)
    [ png(**kwargs) ].pack("m0")
  end

  def ihdr(width, height)
    chunk("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC"))
  end

  def idat(raw)
    chunk("IDAT", Zlib::Deflate.deflate(raw))
  end

  def iend
    chunk("IEND", "".b)
  end

  def chunk(type, data)
    body = type.b + data
    [ data.length ].pack("N") + body + [ Zlib.crc32(body) ].pack("N")
  end
end
