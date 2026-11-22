require "sqlite3"
require "open3"
require "json"
require "tmpdir"

# Builds small synthetic Anki .apkg files for tests: a schema-11
# collection.anki2 written with the sqlite3 gem, plus media members and a
# manifest, zipped with the system zip binary.
class AnkiApkgBuilder
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
  SQL

  def initialize(crt: Time.utc(2026, 1, 1).to_i)
    @crt = crt
    @models = {}
    @decks = {}
    @notes = []
    @cards = []
    @revlog = []
    @media = {} # member number -> [filename, content]
  end

  def add_model(id:, name:, type: 0, fields:, templates:, css: "", req: [])
    @models[id.to_s] = {
      "id" => id, "name" => name, "type" => type, "mod" => 0, "usn" => 0,
      "sortf" => 0, "did" => 1, "tmpls" => templates.each_with_index.map { |t, i|
        { "name" => t[:name], "ord" => i, "qfmt" => t[:front], "afmt" => t[:back], "bqfmt" => "", "bafmt" => "", "did" => nil }
      },
      "flds" => fields.each_with_index.map { |f, i|
        { "name" => f, "ord" => i, "sticky" => false, "rtl" => false, "font" => "Arial", "size" => 20, "media" => [] }
      },
      "css" => css, "req" => req, "tags" => [], "vers" => []
    }
    self
  end

  def add_deck(id:, name:, desc: "")
    @decks[id.to_s] = { "id" => id, "name" => name, "desc" => desc, "mod" => 0, "usn" => 0 }
    self
  end

  def add_note(id:, guid:, mid:, fields:, tags: "", mod: 0)
    @notes << { id: id, guid: guid, mid: mid, mod: mod, tags: tags, flds: fields.join("\u001F") }
    self
  end

  def add_card(id:, nid:, did:, ord: 0, type: 0, queue: 0, due: 0, ivl: 0,
               factor: 0, reps: 0, lapses: 0, left: 0, mod: 0)
    @cards << { id: id, nid: nid, did: did, ord: ord, type: type, queue: queue,
                due: due, ivl: ivl, factor: factor, reps: reps, lapses: lapses,
                left: left, mod: mod }
    self
  end

  def add_revlog(id:, cid:, ease:, ivl: 0, last_ivl: 0, time: 100, type: 1)
    @revlog << { id: id, cid: cid, ease: ease, ivl: ivl, last_ivl: last_ivl, time: time, type: type }
    self
  end

  def add_media(filename, content)
    @media[@media.size.to_s] = [ filename, content ]
    self
  end

  def write(path)
    Dir.mktmpdir("anki-apkg-builder-") do |dir|
      db = SQLite3::Database.new(File.join(dir, "collection.anki2"))
      db.execute_batch(SCHEMA)
      col_params = [ 1, @crt, @crt, 0, 11, JSON.generate(@models), JSON.generate(@decks) ]
      db.execute(<<~SQL, col_params)
        INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
        VALUES (?, ?, ?, ?, ?, 0, 0, 0, '{}', ?, ?, '{}', '{}')
      SQL
      @notes.each do |n|
        db.execute("INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) " \
                   "VALUES (?, ?, ?, ?, 0, ?, ?, 0, 0, 0, '')",
                   [ n[:id], n[:guid], n[:mid], n[:mod], n[:tags], n[:flds] ])
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
                   "VALUES (?, ?, 0, ?, ?, ?, 0, ?, ?)",
                   [ r[:id], r[:cid], r[:ease], r[:ivl], r[:last_ivl], r[:time], r[:type] ])
      end
      db.close

      File.binwrite(File.join(dir, "media"), JSON.generate(@media.transform_values(&:first)))
      @media.each do |number, (_filename, content)|
        File.binwrite(File.join(dir, number), content)
      end

      members = [ "collection.anki2", "media" ] + @media.keys
      FileUtils.rm_f(path.to_s) # zip refuses pre-existing empty files as "invalid structure"
      out, err, status = Open3.capture3("zip", "-q", "-j", path.to_s, *members.map { |m| File.join(dir, m) })
      raise "zip failed (#{status.exitstatus}): #{err.presence || out}" unless status.success?
    end
    Pathname.new(path)
  end
end
