# Minimal protobuf wire-format decoder (varint, length-delimited, fixed32/64)
# used to read the blobs Anki stores in its new (schema 18) collection
# format: notetype/template/deck config and the .apkg media manifest.
# Returns { field_number => [values] } with raw bytes for LEN fields and
# integers for varints.
module Anki
  module Protobuf
    module_function

    def parse(data)
      fields = Hash.new { |h, k| h[k] = [] }
      pos = 0
      size = data.bytesize
      while pos < size
        tag, pos = read_varint(data, pos)
        field = tag >> 3
        wire = tag & 7
        case wire
        when 0 then value, pos = read_varint(data, pos)
        when 1 then value, pos = data.byteslice(pos, 8), pos + 8
        when 2
          len, pos = read_varint(data, pos)
          value, pos = data.byteslice(pos, len), pos + len
        when 5 then value, pos = data.byteslice(pos, 4), pos + 4
        else
          raise ArgumentError, "unsupported protobuf wire type #{wire} for field #{field}"
        end
        fields[field] << value
      end
      fields
    end

    def read_varint(data, pos)
      value = 0
      shift = 0
      loop do
        byte = data.getbyte(pos)
        raise ArgumentError, "truncated varint" if byte.nil?

        pos += 1
        value |= (byte & 0x7F) << shift
        break if (byte & 0x80).zero?

        shift += 7
      end
      [ value, pos ]
    end
  end
end
