require "zlib"

module Ai
  # Derives image-occlusion mask boxes for an AI-generated labeled diagram by
  # diffing it against an edited, label-free copy of itself (the Images API
  # "remove the labels" round-trip). No gem or native dependencies: a minimal
  # PNG decoder (Ruby stdlib zlib) plus thresholding, connected components
  # and blob merging in plain Ruby.
  #
  # Validated on a live neuron diagram (see git history): blind coordinate
  # guessing by vision models fails (mean IoU ~0.3-0.5), while the pixel diff
  # yields letter blobs that merge into word boxes matching every label.
  class PixelDiff
    MAX_MASKS = 40
    # A pixel counts as "changed" when the grayscale delta reaches this
    # fraction of full white. Label text is near-black erased to near-white,
    # so labels sit far above the redraw noise a generative edit inevitably
    # leaves along the drawing's outlines.
    THRESHOLD = 0.85
    # Blobs smaller than this many pixels are redraw noise, not letters.
    MIN_AREA = 20
    # Gaps up to this fraction of image width are bridged when merging letter
    # blobs into words (spans spaces and pointer-line junctions).
    MERGE_SPAN = 0.015

    # Returns mask boxes as fractions of the image dimensions, ordered
    # top-to-bottom: { "x" => 0.21, "y" => 0.12, "w" => 0.04, "h" => 0.012 }.
    # Returns [] when the pair yields nothing usable.
    def self.masks(labeled_bytes:, clean_bytes:)
      labeled = Png.grayscale(labeled_bytes)
      clean = Png.grayscale(clean_bytes)
      return [] unless labeled && clean
      return [] unless labeled[:width] == clean[:width] &&
                       labeled[:height] == clean[:height] &&
                       labeled[:width].positive? && labeled[:height].positive?

      changed = changed_bitmap(labeled, clean)
      width = labeled[:width]
      blobs = blobs_from(changed, width)
      boxes = merge_blobs(blobs, width)
      boxes.first(MAX_MASKS)
             .map { |x, y, w, h| fraction_box(x, y, w, h, width, labeled[:height]) }
             .sort_by { |m| [ m["y"], m["x"] ] }
    end

    def self.fraction_box(x, y, w, h, width, height)
      { "x" => (x.fdiv(width)).round(4), "y" => (y.fdiv(height)).round(4),
        "w" => (w.fdiv(width)).round(4), "h" => (h.fdiv(height)).round(4) }
    end

    # Marks pixels whose grayscale value differs strongly between the pair.
    def self.changed_bitmap(labeled, clean)
      delta = (255 * THRESHOLD).round
      gray_l = labeled[:gray]
      gray_c = clean[:gray]
      Array.new(labeled[:width] * labeled[:height]) do |i|
        (gray_l.getbyte(i) - gray_c.getbyte(i)).abs >= delta
      end
    end

    # 4-connected components of changed pixels, as [x, y, w, h] boxes with
    # area above MIN_AREA.
    def self.blobs_from(changed, width)
      height = changed.length / width
      seen = changed.dup
      blobs = []
      height.times do |y|
        row = y * width
        width.times do |x|
          next unless seen[row + x]
          blob = flood(seen, width, height, x, y)
          blobs << blob if blob
        end
      end
      blobs
    end

    # Iterative 4-connected flood fill over +seen+ (mutated); returns the
    # component's bounding box when it clears MIN_AREA, nil for noise.
    def self.flood(seen, width, height, start_x, start_y)
      min_x = max_x = start_x
      min_y = max_y = start_y
      area = 0
      stack = [ [ start_x, start_y ] ]
      until stack.empty?
        x, y = stack.pop
        idx = y * width + x
        next unless seen[idx]
        seen[idx] = false
        area += 1
        min_x = x if x < min_x
        max_x = x if x > max_x
        min_y = y if y < min_y
        max_y = y if y > max_y
        stack << [ x - 1, y ] if x.positive? && seen[idx - 1]
        stack << [ x + 1, y ] if x < width - 1 && seen[idx + 1]
        stack << [ x, y - 1 ] if y.positive? && seen[idx - width]
        stack << [ x, y + 1 ] if y < height - 1 && seen[idx + width]
      end
      return nil if area < MIN_AREA
      [ min_x, min_y, max_x - min_x + 1, max_y - min_y + 1 ]
    end

    # Repeatedly unites boxes separated by gaps no wider than the merge span,
    # until no pair is close enough (letters -> words, words -> label boxes).
    def self.merge_blobs(blobs, width)
      span = (width * MERGE_SPAN).ceil
      boxes = blobs.dup
      loop do
        pair = nearest_pair(boxes, span)
        break if pair.nil?
        a, b = boxes.values_at(*pair)
        boxes.delete_at(pair.last)
        boxes[pair.first] = unite(a, b)
      end
      boxes
    end

    # First pair of boxes whose expansions by +span+ overlap, or nil.
    def self.nearest_pair(boxes, span)
      (0...boxes.size).each do |i|
        ((i + 1)...boxes.size).each do |j|
          return [ i, j ] if within_span?(boxes[i], boxes[j], span)
        end
      end
      nil
    end

    # Boxes are mergeable when their gap along both axes is at most +span+
    # (negative gaps mean they already overlap).
    def self.within_span?(a, b, span)
      ax, ay, aw, ah = a
      bx, by, bw, bh = b
      (ax <= bx + bw + span && bx <= ax + aw + span) &&
        (ay <= by + bh + span && by <= ay + ah + span)
    end

    def self.unite(a, b)
      ax, ay, aw, ah = a
      bx, by, bw, bh = b
      x = [ ax, bx ].min
      y = [ ay, by ].min
      [ x, y, [ ax + aw, bx + bw ].max - x, [ ay + ah, by + bh ].max - y ]
    end

    # Minimal PNG reader: 8-bit gray / gray+alpha / RGB / RGBA / palette,
    # non-interlaced. Decodes to { width:, height:, gray: } where gray is a
    # binary string of one luminance byte per pixel. Returns nil for formats
    # it cannot handle (bit depth != 8, interlaced, truncated).
    module Png
      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
      LUMA = ->(r, g, b) { (0.299 * r + 0.587 * g + 0.114 * b).round }.freeze

      def self.grayscale(png_bytes)
        data = png_bytes.dup.force_encoding(Encoding::BINARY)
        return nil unless data.start_with?(PNG_SIGNATURE)

        width = height = color_type = nil
        idat = +"".b
        offset = PNG_SIGNATURE.length
        while offset + 8 <= data.length
          length = data[offset, 4].unpack1("N")
          type = data[offset + 4, 4]
          chunk = data[offset + 8, length]
          break if chunk.nil? || chunk.length < length
          offset += 12 + length
          case type
          when "IHDR"
            width, height, _depth, color_type, _comp, _filter, interlace = chunk.unpack("NNCCCCC")
            return nil if interlace != 0
            palette = nil
          when "PLTE"
            palette = chunk
          when "tRNS"
            nil # transparency ignored: opaque diagrams
          when "IDAT"
            idat << chunk
          when "IEND"
            break
          end
        end
        return nil if width.nil? || idat.empty?
        channels = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }[color_type]
        return nil if channels.nil?

        raw = inflate_reversed_strategy(idat)
        return nil if raw.nil?

        grayscale_from(raw, width, height, channels, palette)
      rescue Zlib::Error
        nil
      end

      def self.inflate_reversed_strategy(idat)
        Zlib::Inflate.inflate(idat)
      end

      # Undo per-scanline filters and map to one luminance byte per pixel.
      def self.grayscale_from(raw, width, height, channels, palette)
        stride = width * channels
        gray = +"".b
        prev = String.new(capacity: stride).b
        prev << (0.chr * stride)
        pos = 0
        (0...height).each do
          line = raw[pos, 1 + stride]
          return nil if line.nil? || line.length < 1 + stride
          pos += 1 + stride
          filter = line.getbyte(0)
          line = unfilters(filter, line.byteslice(1, stride), prev, channels)
          return nil if line.nil?
          gray << luminance(line, width, channels, palette)
          prev = line
        end
        { width: width, height: height, gray: gray }
      end

      def self.unfilters(filter, line, prev, channels)
        case filter
        when 0 then line
        when 1 then subtract_left(line, channels)
        when 2 then add_prev(line, prev)
        when 3 then average(line, prev, channels)
        when 4 then paeth(line, prev, channels)
        end
      end

      def self.subtract_left(line, channels)
        bytes = line.unpack("C*")
        i = channels
        while i < bytes.length
          bytes[i] = (bytes[i] + bytes[i - channels]) & 0xff
          i += 1
        end
        bytes.pack("C*")
      end

      def self.add_prev(line, prev)
        bytes = line.unpack("C*")
        pb = prev.unpack("C*")
        i = 0
        while i < bytes.length
          bytes[i] = (bytes[i] + pb[i]) & 0xff
          i += 1
        end
        bytes.pack("C*")
      end

      def self.average(line, prev, channels)
        bytes = line.unpack("C*")
        pb = prev.unpack("C*")
        i = 0
        while i < bytes.length
          left = i >= channels ? bytes[i - channels] : 0
          bytes[i] = (bytes[i] + ((left + pb[i]) >> 1)) & 0xff
          i += 1
        end
        bytes.pack("C*")
      end

      def self.paeth(line, prev, channels)
        bytes = line.unpack("C*")
        pb = prev.unpack("C*")
        i = 0
        while i < bytes.length
          a = i >= channels ? bytes[i - channels] : 0
          b = pb[i]
          c = i >= channels ? pb[i - channels] : 0
          p = a + b - c
          pa = (p - a).abs
          pbv = (p - b).abs
          pc = (p - c).abs
          best = pa <= pbv && pa <= pc ? a : (pbv <= pc ? b : c)
          bytes[i] = (bytes[i] + best) & 0xff
          i += 1
        end
        bytes.pack("C*")
      end

      # One luminance byte per pixel for the decoded scanline.
      def self.luminance(line, width, channels, palette)
        case channels
        when 1
          return line unless palette
          out = +"".b
          line.each_byte { |idx| out << palette_luma(palette, idx) }
          out
        when 2 # gray + alpha
          out = +"".b
          i = 0
          while i < line.length
            out << line.getbyte(i)
            i += 2
          end
          out
        when 3
          out = +"".b
          i = 0
          while i < line.length
            r, g, b = line.byteslice(i, 3).unpack("CCC")
            out << LUMA.call(r, g, b)
            i += 3
          end
          out
        when 4
          out = +"".b
          i = 0
          while i < line.length
            r, g, b = line.byteslice(i, 4).unpack("CCCC")
            out << LUMA.call(r, g, b)
            i += 4
          end
          out
        end
      end

      def self.palette_luma(palette, idx)
        r, g, b = palette.byteslice(idx * 3, 3).unpack("CCC")
        LUMA.call(r, g, b)
      end
    end
  end
end
