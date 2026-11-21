require "sqlite3"
require_relative "../protobuf"

module Anki
  module Apkg
    # Read-only access to a modern Anki collection (schema 18, as found in
    # zstd-compressed collection.anki21b members of Anki 23.10+ exports).
    # Exposes the same interface as the legacy Collection but reads the
    # normalized tables (notetypes/fields/templates/decks) and decodes the
    # protobuf blobs Anki stores instead of JSON.
    #
    # Card requirements ("req") are not stored in this format; they are
    # recomputed from each template's front, following Anki's rules:
    # a card is generated when any directly-referenced field is non-empty,
    # or (if the front only uses conditional sections) when the first
    # conditional field is non-empty.
    class NewCollection
      SPECIAL_TOKENS = %w[FrontSide Tags Deck Subdeck Card Type Tags NoteType].freeze

      def initialize(path)
        @db = SQLite3::Database.new(path.to_s, readonly: true, results_as_hash: true)
        # Anki's schema declares a custom "unicase" collation on name
        # columns; SQLite refuses to even prepare queries against those
        # tables unless the collation exists.
        @db.collation("unicase", proc { |a, b| a <=> b })
        @col = @db.execute("SELECT * FROM col LIMIT 1").first
        raise Error, "collection has no col row" if @col.nil?
      end

      def close
        @db.close
      end

      def crt
        Time.at(@col["crt"]).utc
      end

      # Legacy-compatible model hash keyed by note type id, with the req
      # entries normalized to [template_ord, kind, [field names]].
      def models
        @models ||= notetype_rows.to_h do |row|
          config = Protobuf.parse(row["config"])
          kind = config[1]&.first == 1 ? 1 : 0
          field_names = fields_for(row["id"])
          templates = templates_for(row["id"], field_names)
          [ row["id"].to_s, {
            "id" => row["id"],
            "name" => row["name"],
            "type" => kind,
            "flds" => field_names.map.with_index { |n, i| { "ord" => i, "name" => n } },
            "tmpls" => templates.map { |t| { "ord" => t[:ord], "name" => t[:name], "qfmt" => t[:qfmt], "afmt" => t[:afmt] } },
            "css" => utf8(config[3]&.first).to_s,
            "req" => templates.map { |t| [ t[:ord], *requirement_for(t[:qfmt], field_names) ] }
          } ]
        end
      end

      # Legacy-compatible deck hash keyed by deck id.
      def decks
        @decks ||= @db.execute("SELECT id, name, kind FROM decks").to_h do |row|
          desc = deck_description(row["kind"])
          [ row["id"].to_s, { "id" => row["id"], "name" => row["name"], "desc" => desc } ]
        end
      end

      def counts
        {
          notes: @db.get_first_value("SELECT COUNT(*) FROM notes"),
          cards: @db.get_first_value("SELECT COUNT(*) FROM cards"),
          revlog: @db.get_first_value("SELECT COUNT(*) FROM revlog")
        }
      end

      def each_note
        return to_enum(:each_note) unless block_given?
        @db.execute("SELECT id, guid, mid, tags, flds FROM notes") do |row|
          yield id: row["id"], guid: row["guid"], mid: row["mid"], tags: row["tags"].to_s,
                fields: row["flds"].to_s.split("\u001F")
        end
      end

      def each_card
        return to_enum(:each_card) unless block_given?
        @db.execute("SELECT * FROM cards") do |row|
          yield row
        end
      end

      def each_revlog
        return to_enum(:each_revlog) unless block_given?
        @db.execute("SELECT * FROM revlog") do |row|
          yield id: row["id"], cid: row["cid"], ease: row["ease"], ivl: row["ivl"],
                last_ivl: row["lastIvl"], time_ms: row["time"], type: row["type"],
                reviewed_at: Time.at(row["id"] / 1000.0).utc
        end
      end

      private

      def notetype_rows
        @db.execute("SELECT id, name, config FROM notetypes")
      end

      def fields_for(ntid)
        @db.execute("SELECT ord, name FROM fields WHERE ntid = ? ORDER BY ord", ntid)
          .map { |row| utf8(row["name"]) }
      end

      def templates_for(ntid, _field_names)
        @db.execute("SELECT ord, name, config FROM templates WHERE ntid = ? ORDER BY ord", ntid)
          .filter_map do |row|
            config = Protobuf.parse(row["config"])
            qfmt = utf8(config[1]&.first)
            afmt = utf8(config[2]&.first)
            # Orphaned template rows can reference note types that were
            # not exported; their qfmt/afmt are missing.
            next if qfmt.nil? && afmt.nil?

            { ord: row["ord"], name: utf8(row["name"]), qfmt: qfmt.to_s, afmt: afmt.to_s }
          end
      end

      # kind blob: { normal: { config_id: 1, desc: 2 } } or a filtered deck.
      def deck_description(kind_blob)
        normal = Protobuf.parse(kind_blob.to_s)[1]&.first
        return "" if normal.nil?

        utf8(Protobuf.parse(normal)[2]&.first).to_s
      end

      # [kind, [field names]] requirement for one template front.
      def requirement_for(qfmt, field_names)
        direct, conditional = [], []
        qfmt.to_s.scan(/\{\{([^}]*)\}\}/) do |(token)|
          name = token.strip
          next if name.empty?

          if name.start_with?("#", "^")
            conditional << name[1..].strip
          else
            direct << name.split(":").last.strip
          end
        end
        names = field_names
        direct_refs = direct.uniq.select { |n| names.include?(n) }
        conditional_refs = conditional.uniq.select { |n| names.include?(n) }
        if direct_refs.any?
          [ "any", direct_refs ]
        elsif conditional_refs.any?
          [ "any", [ conditional_refs.first ] ]
        else
          [ "none", [] ]
        end
      end

      def utf8(bytes)
        return nil if bytes.nil?

        bytes.dup.force_encoding("UTF-8")
      end
    end
  end
end
