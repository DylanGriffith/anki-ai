require "sqlite3"
require "zlib"

module Anki
  module Apkg
    # Writes a legacy schema-11 collection.anki2 — the format every Anki
    # version imports and our own reader expects — plus numbered media
    # members and the JSON manifest, into a directory ready to be zipped
    # into an .apkg. Mirrors what Anki itself writes for "Anki 2.0 export".
    class Schema11Writer
      SCHEMA = <<~SQL
        CREATE TABLE col (
          id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL,
          scm integer NOT NULL, ver integer NOT NULL, dty integer NOT NULL,
          usn integer NOT NULL, ls integer NOT NULL, conf text NOT NULL,
          models text NOT NULL, decks text NOT NULL, dconf text NOT NULL, tags text NOT NULL
        );
        CREATE TABLE notes (
          id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL,
          mod integer NOT NULL, usn integer NOT NULL, tags text NOT NULL,
          flds text NOT NULL, sfld text NOT NULL, csum integer NOT NULL,
          flags integer NOT NULL, data text NOT NULL
        );
        CREATE TABLE cards (
          id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL,
          ord integer NOT NULL, mod integer NOT NULL, usn integer NOT NULL,
          type integer NOT NULL, queue integer NOT NULL, due integer NOT NULL,
          ivl integer NOT NULL, factor integer NOT NULL, reps integer NOT NULL,
          lapses integer NOT NULL, left integer NOT NULL, odue integer NOT NULL,
          odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL
        );
        CREATE TABLE revlog (
          id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL,
          ease integer NOT NULL, ivl integer NOT NULL, lastIvl integer NOT NULL,
          factor integer NOT NULL, time integer NOT NULL, type integer NOT NULL
        );
        CREATE TABLE graves (
          usn integer NOT NULL, oid integer NOT NULL, type integer NOT NULL
        );
        CREATE INDEX ix_notes_usn on notes (usn);
        CREATE INDEX ix_cards_usn on cards (usn);
        CREATE INDEX ix_revlog_usn on revlog (usn);
        CREATE INDEX ix_cards_nid on cards (nid);
        CREATE INDEX ix_revlog_cid on revlog (cid);
        CREATE INDEX ix_notes_csum on notes (csum);
      SQL

      # Anki's default collection conf; enough for any importer.
      DEFAULT_CONF = {
        "nextPos" => 1, "estTimes" => true, "activeDecks" => [ 1 ],
        "sortType" => "noteFld", "timeLim" => 0, "sortBackwards" => false,
        "addToCur" => true, "curDeck" => 1, "newBury" => true, "newSpread" => 0,
        "dueCounts" => true, "curModel" => "1", "collapseTime" => 1200
      }.freeze

      # models:  { id_string => legacy model hash }
      # decks:   { id_string => legacy deck hash }
      # notes:   [{ id, guid, mid, mod, tags, fields }]
      # cards:   [{ id, nid, did, ord, mod, type, queue, due, ivl, factor,
      #             reps, lapses, left }]
      # revlog:  [{ id, cid, ease, ivl, last_ivl, factor, time_ms, type }]
      # media:   [[ filename, source_path ]] in member order
      def initialize(dir:, crt:, models:, decks:, notes:, cards:, revlog: [], media: [],
                     dconf: {}, conf: DEFAULT_CONF)
        @dir = Pathname.new(dir)
        @crt = crt.to_i
        @models = models
        @decks = decks
        @notes = notes
        @cards = cards
        @revlog = revlog
        @media = media
        @dconf = dconf
        @conf = conf
      end

      def write!
        write_collection
        write_media
        self
      end

      private

      def write_collection
        db = SQLite3::Database.new(@dir.join("collection.anki2").to_s)
        db.execute_batch(SCHEMA)
        db.execute(<<~SQL, col_row)
          INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
          VALUES (?, ?, ?, ?, ?, 0, 0, 0, ?, ?, ?, ?, '{}')
        SQL

        @notes.each do |n|
          sfld = strip_html(Array(n[:fields]).first.to_s)
          db.execute("INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) " \
                     "VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, 0, '')",
                     [ n[:id], n[:guid], n[:mid], n[:mod], n[:tags],
                       Array(n[:fields]).join("\u001F"), sfld, csum(sfld) ])
        end

        @cards.each do |c|
          db.execute("INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, " \
                     "reps, lapses, left, odue, odid, flags, data) " \
                     "VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, '')",
                     [ c[:id], c[:nid], c[:did], c[:ord], c[:mod], c[:type], c[:queue],
                       c[:due], c[:ivl], c[:factor], c[:reps], c[:lapses], c[:left] ])
        end

        @revlog.each do |r|
          db.execute("INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) " \
                     "VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)",
                     [ r[:id], r[:cid], r[:ease], r[:ivl], r[:last_ivl],
                       r[:factor], r[:time_ms], r[:type] ])
        end
        db.close
      end

      def col_row
        [ 1, @crt, Time.now.utc.to_i, 0, 11,
          JSON.generate(@conf), JSON.generate(@models), JSON.generate(@decks),
          JSON.generate(@dconf) ]
      end

      def write_media
        manifest = {}
        @media.each_with_index do |(filename, source), i|
          number = i.to_s
          manifest[number] = filename
          FileUtils.cp(source.to_s, @dir.join(number).to_s)
        end
        File.binwrite(@dir.join("media").to_s, JSON.generate(manifest))
      end

      # Sort-field text: HTML tags stripped, entities decoded — close enough
      # to Anki's stripHTMLMedia for dupe detection and sorting.
      def strip_html(html)
        text = html.to_s
                    .gsub(%r{<style\b[^>]*>.*?</style>}mi, "")
                    .gsub(%r{<script\b[^>]*>.*?</script>}mi, "")
                    .gsub(%r{<br\s*/?>}i, "\n")
                    .gsub(/<[^>]+>/, "")
        CGI.unescapeHTML(text).strip
      end

      # Anki's field checksum: crc32 of the sort field (as a signed 32-bit
      # int, which is how SQLite stores it back).
      def csum(sfld)
        [ Zlib.crc32(sfld) ].pack("L").unpack1("l")
      end
    end
  end
end
