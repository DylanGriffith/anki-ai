require "open3"
require "json"

module Anki
  module Apkg
    # A .apkg/.colpkg file: a ZIP with a collection SQLite DB, a media manifest
    # ("media": JSON number -> filename for older exports; a zstd-compressed
    # protobuf message for Anki 23.10+), and media members stored under numeric
    # names. Container handling shells out to the system unzip binary so large
    # archives never sit in memory.
    class Package
      MANIFEST_MEMBER = "media"
      COLLECTION_PREFERENCE = %w[collection.anki21 collection.anki2].freeze
      SQLITE_HEADER = "SQLite format 3".freeze

      def initialize(path)
        @path = Pathname.new(path)
        raise Error, "#{@path} not found" unless @path.file?
      end

      # Extracts the whole archive to a temp dir, yields the package, then
      # removes the temp dir. One unzip invocation; media members are then
      # plain files named after their manifest numbers.
      def extract!
        Dir.mktmpdir("anki-apkg-") do |dir|
          @workdir = Pathname.new(dir)
          out, err, status = Open3.capture3("unzip", "-oq", @path.to_s, "-d", dir)
          raise Error, "unzip failed: #{err.presence || out}" unless status.success?
          decompress_modern_media!
          yield self
        ensure
          @workdir = nil
        end
      end

      def collection
        path = real_collection_path
        db = SQLite3::Database.new(path.to_s, readonly: true)
        ver = db.get_first_value("SELECT ver FROM col LIMIT 1")
        db.close
        case ver
        when 11 then Collection.new(path)
        when 18 then NewCollection.new(path)
        else
          raise Error, "unsupported collection schema version #{ver.inspect}"
        end
      end

      # Anki 23.10+ exports store the real collection in a zstd-compressed
      # collection.anki21b and leave a placeholder note in the legacy
      # collection.anki2 slot (a valid SQLite file whose single note says
      # "Please update to the latest Anki version"). So anki21b, when
      # present, is authoritative; legacy members are only used alone.
      def real_collection_path
        raise Error, "not extracted; call extract! with a block" unless @workdir

        anki21b = @workdir.join("collection.anki21b")
        if anki21b.file?
          raw = File.binread(anki21b.to_s)
          raw = Anki::Zstd.decompress(raw) if Anki::Zstd.zstd?(raw)
          target = @workdir.join("collection.anki21b.sqlite")
          File.binwrite(target.to_s, raw)
          return target if sqlite?(target)
        end

        COLLECTION_PREFERENCE.each do |name|
          candidate = @workdir.join(name)
          return candidate if sqlite?(candidate)
        end

        raise UnsupportedFormatError, "no usable collection found " \
          "(looked for collection.anki2/.anki21/.anki21b)"
      end

      def sqlite?(path)
        return false unless path&.file?

        File.binread(path.to_s, 16).to_s.start_with?(SQLITE_HEADER)
      end

      # In Anki 23.10+ exports the media members are zstd-compressed just
      # like the manifest, so a zstd manifest means every numeric member
      # must be decompressed in place before use. Legacy packages have a
      # plain JSON manifest and raw members — those are left untouched
      # (the manifest format, not a per-file magic sniff, decides: a
      # legacy package may legitimately contain .zst media).
      def decompress_modern_media!
        manifest = @workdir.join(MANIFEST_MEMBER)
        return unless manifest.file? && Anki::Zstd.zstd?(File.binread(manifest.to_s, 4))

        Dir.glob(@workdir.join("*").to_s).each do |path|
          next unless File.basename(path).match?(/\A\d+\z/)
          next unless Anki::Zstd.zstd?(File.binread(path, 4))

          File.binwrite(path, Anki::Zstd.decompress(File.binread(path)))
        end
      end

      # Hash of numeric member name -> real media filename. Older exports
      # store plain JSON; Anki 23.10+ stores a zstd-compressed protobuf
      # message whose repeated field 1 entries carry the filenames in zip
      # member order.
      def media_manifest
        @media_manifest ||= begin
          member = @workdir.join(MANIFEST_MEMBER)
          if member.file?
            raw = File.binread(member.to_s)
            raw = Anki::Zstd.decompress(raw) if Anki::Zstd.zstd?(raw)
            parse_manifest(raw)
          else
            {}
          end
        end
      end

      def parse_manifest(raw)
        if raw.lstrip.byteslice(0, 1) == "{"
          JSON.parse(raw)
        else
          Anki::Protobuf.parse(raw)[1].to_a.each_with_index.map do |entry, idx|
            fname = Anki::Protobuf.parse(entry)[1].first.to_s.dup.force_encoding("UTF-8")
            [ idx.to_s, fname ]
          end.to_h
        end
      end

      # Path of the extracted member for a manifest number.
      def media_member(number)
        raise Error, "not extracted; call extract! with a block" unless @workdir

        path = @workdir.join(number.to_s)
        path.file? ? path : nil
      end
    end

    # Read-only access to a legacy (schema 11) Anki collection.
    class Collection
      def initialize(path)
        @db = SQLite3::Database.new(path.to_s, readonly: true, results_as_hash: true)
        @col = @db.execute("SELECT * FROM col LIMIT 1").first
        raise Error, "collection.anki2 has no col row" if @col.nil?
      end

      def close
        @db.close
      end

      # Collection creation time (seconds) — day 0 for due-date day numbers.
      def crt
        Time.at(@col["crt"]).utc
      end

      # Anki note types ("models"): mid(string) -> { "id", "name", "type", "flds", "tmpls", "css", "req", ... }
      def models
        @models ||= JSON.parse(@col["models"])
      end

      # Anki decks: did(string) -> { "id", "name", "desc", ... }
      def decks
        @decks ||= JSON.parse(@col["decks"])
      end

      def counts
        {
          notes: @db.get_first_value("SELECT COUNT(*) FROM notes"),
          cards: @db.get_first_value("SELECT COUNT(*) FROM cards"),
          revlog: @db.get_first_value("SELECT COUNT(*) FROM revlog")
        }
      end

      # Yields { id:, guid:, mid:, tags:, fields: [..] } per note.
      def each_note
        return to_enum(:each_note) unless block_given?
        @db.execute("SELECT id, guid, mid, tags, flds FROM notes") do |row|
          yield id: row["id"], guid: row["guid"], mid: row["mid"], tags: row["tags"].to_s,
                fields: row["flds"].to_s.split("\u001F")
        end
      end

      # Yields the raw card row (Anki columns) per card.
      def each_card
        return to_enum(:each_card) unless block_given?
        @db.execute("SELECT * FROM cards") do |row|
          yield row
        end
      end

      # Yields { id:, cid:, ease:, ivl:, last_ivl:, time_ms:, reviewed_at:, type: } per review.
      def each_revlog
        return to_enum(:each_revlog) unless block_given?
        @db.execute("SELECT * FROM revlog") do |row|
          yield id: row["id"], cid: row["cid"], ease: row["ease"], ivl: row["ivl"],
                last_ivl: row["lastIvl"], time_ms: row["time"], type: row["type"],
                reviewed_at: Time.at(row["id"] / 1000.0).utc
        end
      end
    end
  end
end
