require "fiddle"
require "open3"

module Anki
  # Zstd decompression for Anki 23.10+ .apkg files, whose `media` manifest
  # is zstd-compressed rather than plain JSON. Binds the system libzstd
  # through the stdlib Fiddle extension (no gem dependency) and falls back
  # to the zstd CLI. macOS does not ship a zstd CLI, but Homebrew's library
  # is a common install; Linux distributions bundle libzstd.so.1.
  module Zstd
    MAGIC = "\x28\xB5\x2F\xFD".b.freeze # zstd frame header

    LIB_CANDIDATES = [
      "/opt/homebrew/opt/zstd/lib/libzstd.dylib", # Homebrew (Apple silicon)
      "/usr/local/opt/zstd/lib/libzstd.dylib",    # Homebrew (Intel)
      "libzstd.so.1",                             # Linux (dynamic linker)
      "/usr/lib/aarch64-linux-gnu/libzstd.so.1",
      "/usr/lib/x86_64-linux-gnu/libzstd.so.1",
      "/usr/lib/libzstd.so.1",
      "libzstd.dylib"
    ].freeze

    # ZSTD_CONTENTSIZE_UNKNOWN / _ERROR read through a signed long long.
    CONTENT_SIZE_UNKNOWN = -1
    CONTENT_SIZE_ERROR   = -2

    MAX_OUTPUT = 512 * 1024 * 1024

    class << self
      def zstd?(data)
        data.to_s.byteslice(0, 4) == MAGIC
      end

      def decompress(data)
        via_libzstd(data) || via_cli(data) || raise(Apkg::Error, <<~MSG.squish)
          This file uses zstd compression (Anki 23.10+ export format). Install
          zstd to import it (e.g. `brew install zstd`), or re-export from Anki.
        MSG
      end

      # Compresses with the system libzstd (CLI fallback). Used to build
      # modern-format fixtures in tests, and by .apkg export later.
      def compress(data, level: 3)
        via_libzstd_compress(data, level) || via_cli_compress(data, level) ||
          raise(Apkg::Error, "zstd compression unavailable (install zstd, e.g. `brew install zstd`)")
      end

      private

      def handle
        return @handle if instance_variable_defined?(:@handle)

        @handle = LIB_CANDIDATES.filter_map do |path|
          begin
            Fiddle.dlopen(path)
          rescue Fiddle::DLError
            nil
          end
        end.first
      rescue Fiddle::DLError
        nil
      end

      def via_libzstd(data)
        fns = libzstd_functions or return nil
        src = Fiddle::Pointer[data]
        size = fns[:get_size].call(src, data.bytesize)
        if size == CONTENT_SIZE_ERROR
          nil
        elsif size == CONTENT_SIZE_UNKNOWN || size <= 0
          cap = frame_bound(fns, src, data.bytesize) or return nil
          decompress_with(fns, src, data.bytesize, cap)
        else
          decompress_with(fns, src, data.bytesize, size)
        end
      rescue Fiddle::DLError, StandardError
        nil
      end

      def decompress_with(fns, src, src_size, cap)
        return nil if cap <= 0 || cap > MAX_OUTPUT

        dst = Fiddle::Pointer.malloc(cap)
        written = fns[:decompress].call(dst, cap, src, src_size)
        return nil if fns[:is_error].call(written) != 0

        dst.to_s(written)
      end

      # Upper bound on the decompressed size when the frame header does not
      # carry an exact content size (ZSTD_decompressBound, libzstd >= 1.4.5).
      def frame_bound(fns, src, src_size)
        bound = fns[:get_bound].call(src, src_size)
        fns[:is_error].call(bound) != 0 ? nil : bound
      end

      def libzstd_functions
        return @libzstd_functions if instance_variable_defined?(:@libzstd_functions)

        @libzstd_functions = begin
          lib = handle
          if lib.nil?
            nil
          else
            {
              get_size: Fiddle::Function.new(lib["ZSTD_getFrameContentSize"],
                [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T ], Fiddle::TYPE_LONG_LONG),
              get_bound: Fiddle::Function.new(lib["ZSTD_decompressBound"],
                [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T ], Fiddle::TYPE_SIZE_T),
              decompress: Fiddle::Function.new(lib["ZSTD_decompress"],
                [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T ],
                Fiddle::TYPE_SIZE_T),
              compress_bound: Fiddle::Function.new(lib["ZSTD_compressBound"],
                [ Fiddle::TYPE_SIZE_T ], Fiddle::TYPE_SIZE_T),
              compress: Fiddle::Function.new(lib["ZSTD_compress"],
                [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_VOIDP,
                  Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT ], Fiddle::TYPE_SIZE_T),
              is_error: Fiddle::Function.new(lib["ZSTD_isError"],
                [ Fiddle::TYPE_SIZE_T ], Fiddle::TYPE_INT)
            }
          end
        rescue Fiddle::DLError
          nil
        end
      end
      def via_cli(data)
        [ "zstd", "zstdcat" ].each do |cmd|
          out, status = Open3.capture2(cmd, "-dc", binmode: true, stdin_data: data)
          return out if status.success? && !out.empty?
        end
        nil
      rescue Errno::ENOENT, StandardError
        nil
      end

      def via_libzstd_compress(data, level)
        fns = libzstd_functions or return nil
        src = Fiddle::Pointer[data]
        bound = fns[:compress_bound].call(data.bytesize)
        return nil if fns[:is_error].call(bound) != 0

        dst = Fiddle::Pointer.malloc(bound)
        written = fns[:compress].call(dst, bound, src, data.bytesize, level)
        return nil if fns[:is_error].call(written) != 0

        dst.to_s(written)
      rescue Fiddle::DLError, StandardError
        nil
      end

      def via_cli_compress(data, level)
        out, status = Open3.capture2("zstd", "-#{level}", "-c", binmode: true, stdin_data: data)
        status.success? ? out : nil
      rescue Errno::ENOENT, StandardError
        nil
      end
    end
  end
end
