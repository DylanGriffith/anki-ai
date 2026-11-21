require "open3"
require "json"

module Anki
  module Apkg
    # A .apkg/.colpkg file: a ZIP with a collection SQLite DB, a media manifest
    # ("media", JSON number -> filename), and media members stored under numeric
    # names. Container handling shells out to the system unzip binary so large
    # archives never sit in memory.
    class Package
      MANIFEST_MEMBER = "media"
      COLLECTION_PREFERENCE = %w[collection.anki21 collection.anki2].freeze

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
          yield self
        ensure
          @workdir = nil
        end
      end

      def collection
        Collection.new(collection_path)
      end

      def collection_path
        raise Error, "not extracted; call extract! with a block" unless @workdir

        COLLECTION_PREFERENCE.each do |name|
          candidate = @workdir.join(name)
          return candidate if candidate.file?
        end
        raise UnsupportedFormatError,
              "no legacy collection found (looked for collection.anki2/.anki21). " \
              "If this file only contains collection.anki21b, re-export it from Anki " \
              "with \"Support older Anki versions\" checked."
      end

      # Hash of numeric member name -> real media filename.
      def media_manifest
        @media_manifest ||= begin
          member = @workdir.join(MANIFEST_MEMBER)
          member.file? ? JSON.parse(member.read) : {}
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
