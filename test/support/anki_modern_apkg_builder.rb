require "sqlite3"
require "digest"

require "sqlite3"
require "digest"
require "open3"
require "tmpdir"
require "fileutils"

# Builds synthetic Anki 23.10+ .apkg files: a schema-18 collection whose
# notetypes/fields/templates/decks live in normalized tables with protobuf
# config blobs, zstd-compressed into collection.anki21b (plus a placeholder
# collection.anki2, like Anki writes, to prove the 21b member wins), a
# zstd-compressed protobuf media manifest, and zstd-compressed media
# members — mirroring a real modern export byte-for-byte in structure.
class AnkiModernApkgBuilder
  # The tables the reader touches. Collated name columns match Anki's
  # schema, which is why the reader registers a "unicase" collation.
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
      flds text NOT NULL, sfld integer NOT NULL, csum integer NOT NULL,
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
    CREATE TABLE notetypes (
      id integer PRIMARY KEY, name text NOT NULL COLLATE unicase,
      mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL
    );
    CREATE TABLE fields (
      ntid integer NOT NULL, ord integer NOT NULL,
      name text NOT NULL COLLATE unicase, config blob NOT NULL,
      PRIMARY KEY (ntid, ord)
    ) without rowid;
    CREATE TABLE templates (
      ntid integer NOT NULL, ord integer NOT NULL,
      name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
      usn integer NOT NULL, config blob NOT NULL,
      PRIMARY KEY (ntid, ord)
    ) without rowid;
    CREATE TABLE decks (
      id integer PRIMARY KEY, name text NOT NULL COLLATE unicase,
      mtime_secs integer NOT NULL, usn integer NOT NULL,
      common blob NOT NULL, kind blob NOT NULL
    );
    CREATE TABLE deck_config (
      id integer PRIMARY KEY, name text NOT NULL COLLATE unicase,
      mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL
    );
  SQL

  def initialize(crt: Time.utc(2026, 1, 1).to_i)
    @crt = crt
    @notetypes = []
    @decks = []
    @notes = []
    @cards = []
    @revlog = []
    @media = [] # [filename, content]
  end

  def add_model(id:, name:, type: 0, fields:, templates:, css: "", original_id: 1)
    @notetypes << { id: id, name: name, type: type, css: css, original_id: original_id,
                    fields: fields, templates: templates }
    self
  end

  def add_deck(id:, name:, desc: "", config_id: 1)
    @decks << { id: id, name: name, desc: desc, config_id: config_id }
    self
  end

  def add_note(id:, guid:, mid:, fields:, tags: "")
    @notes << { id: id, guid: guid, mid: mid, tags: tags, flds: fields.join("\u001F") }
    self
  end

  def add_card(id:, nid:, did:, ord: 0, type: 0, queue: 0, due: 0, ivl: 0,
               factor: 0, reps: 0, lapses: 0, left: 0)
    @cards << { id: id, nid: nid, did: did, ord: ord, type: type, queue: queue,
                due: due, ivl: ivl, factor: factor, reps: reps, lapses: lapses, left: left }
    self
  end

  def add_revlog(id:, cid:, ease:, ivl: 0, last_ivl: 0, time: 100, type: 1)
    @revlog << { id: id, cid: cid, ease: ease, ivl: ivl, last_ivl: last_ivl, time: time, type: type }
    self
  end

  def add_media(filename, content)
    @media << [ filename, content ]
    self
  end

  def write(path)
    Dir.mktmpdir("anki-modern-builder-") do |dir|
      db = SQLite3::Database.new(File.join(dir, "collection.sqlite"))
      db.collation("unicase", proc { |a, b| a <=> b })
      db.execute_batch(SCHEMA)
      db.execute("INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags) " \
                 "VALUES (1, ?, ?, 0, 18, 0, 0, 0, '{}', '{}', '{}', '{}', '[]')", [ @crt, @crt ])

      db.execute("INSERT INTO deck_config (id, name, mtime_secs, usn, config) VALUES (1, 'Default', 0, 0, ?)",
                 [ pb_varint(1, 1) ])
      @decks.each do |d|
        # kind: Normal { config_id: 1, desc: 2 } — what the reader decodes.
        kind = pb_bytes(1, pb_join(pb_varint(1, d[:config_id]), pb_bytes(2, d[:desc])))
        common = pb_join(pb_varint(1, d[:config_id]))
        db.execute("INSERT INTO decks (id, name, mtime_secs, usn, common, kind) VALUES (?, ?, 0, 0, ?, ?)",
                   [ d[:id], d[:name], common, kind ])
      end

      @notetypes.each do |nt|
        # notetype config: 1 kind (1 = cloze), 3 css, 4 original id.
        config = pb_join(
          pb_varint(1, nt[:type] == 1 ? 1 : 0),
          nt[:css].empty? ? "" : pb_bytes(3, nt[:css]),
          pb_varint(4, nt[:original_id])
        )
        db.execute("INSERT INTO notetypes (id, name, mtime_secs, usn, config) VALUES (?, ?, 0, 0, ?)",
                   [ nt[:id], nt[:name], config ])
        nt[:fields].each_with_index do |name, i|
          db.execute("INSERT INTO fields (ntid, ord, name, config) VALUES (?, ?, ?, ?)",
                     [ nt[:id], i, name, pb_join(pb_varint(1, 20)) ])
        end
        nt[:templates].each_with_index do |t, i|
          # template config: 1 qfmt, 2 afmt.
          db.execute("INSERT INTO templates (ntid, ord, name, mtime_secs, usn, config) VALUES (?, ?, ?, 0, 0, ?)",
                     [ nt[:id], i, t[:name], pb_join(pb_bytes(1, t[:front]), pb_bytes(2, t[:back])) ])
        end
      end

      @notes.each do |n|
        db.execute("INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) " \
                   "VALUES (?, ?, ?, 0, 0, ?, ?, 0, 0, 0, '')",
                   [ n[:id], n[:guid], n[:mid], n[:tags], n[:flds] ])
      end
      @cards.each do |c|
        db.execute("INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, " \
                   "reps, lapses, left, odue, odid, flags, data) " \
                   "VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, '')",
                   [ c[:id], c[:nid], c[:did], c[:ord], c[:type], c[:queue], c[:due],
                     c[:ivl], c[:factor], c[:reps], c[:lapses], c[:left] ])
      end
      @revlog.each do |r|
        db.execute("INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) " \
                   "VALUES (?, ?, 0, ?, ?, ?, 0, ?, ?)",
                   [ r[:id], r[:cid], r[:ease], r[:ivl], r[:last_ivl], r[:time], r[:type] ])
      end
      db.close

      # The real collection, zstd-compressed, like Anki 23.10+ writes it.
      File.binwrite(File.join(dir, "collection.anki21b"),
                    Anki::Zstd.compress(File.binread(File.join(dir, "collection.sqlite"))))

      # Placeholder legacy member (a valid schema-11 DB with a stub note),
      # as Anki writes it: must never win over collection.anki21b.
      placeholder = SQLite3::Database.new(File.join(dir, "collection.anki2"))
      placeholder.execute_batch(AnkiApkgBuilder::SCHEMA)
      placeholder.execute("INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags) " \
                          "VALUES (1, ?, ?, 0, 11, 0, 0, 0, '{}', '{}', '{}', '{}', '[]')", [ @crt, @crt ])
      placeholder.execute("INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) " \
                          "VALUES (1, 'placeholder', 1, 0, 0, '', 'Please update Anki', 0, 0, 0, '')")
      placeholder.close

      # Media: zstd-compressed members and a zstd-compressed protobuf
      # manifest whose repeated field-1 entries carry fname/size/sha1 in
      # zip member order.
      manifest = pb_join(@media.map do |(filename, content)|
        pb_bytes(1, pb_join(
          pb_bytes(1, filename),
          pb_varint(2, content.bytesize),
          pb_bytes(3, Digest::SHA1.digest(content))
        ))
      end)
      File.binwrite(File.join(dir, "media"), Anki::Zstd.compress(manifest))
      @media.each_with_index do |(_filename, content), i|
        File.binwrite(File.join(dir, i.to_s), Anki::Zstd.compress(content))
      end

      members = [ "collection.anki21b", "collection.anki2", "media" ] + @media.each_index.map(&:to_s)
      FileUtils.rm_f(path.to_s)
      out, err, status = Open3.capture3("zip", "-q", "-j", path.to_s, *members.map { |m| File.join(dir, m) })
      raise "zip failed (#{status.exitstatus}): #{err.presence || out}" unless status.success?
    end
    Pathname.new(path)
  end

  private
  def pb_varint(field, value)
    pb_key(field, 0) + pb_varint_value(value)
  end

  def pb_bytes(field, string)
    pb_key(field, 2) + pb_varint_value(string.bytesize) + string.b
  end

  def pb_key(field, wire)
    pb_varint_value((field << 3) | wire)
  end

  def pb_varint_value(value)
    bytes = []
    loop do
      byte = value & 0x7F
      value >>= 7
      byte |= 0x80 unless value.zero?
      bytes << byte
      break if value.zero?
    end
    bytes.pack("C*")
  end

  def pb_join(*parts)
    parts.join.b
  end
end
