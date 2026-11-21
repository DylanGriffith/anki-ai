require "test_helper"

class Anki::Apkg::PackageTest < ActiveSupport::TestCase
  def build_package
    AnkiApkgBuilder.new
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{FrontSide}}<hr>{{Back}}" } ])
      .add_model(id: 1600000000002, name: "Cloze", type: 1, fields: %w[Text Extra],
                 templates: [ { name: "Cloze", front: "{{cloze:Text}}", back: "{{cloze:Text}}{{hint:Extra}}" } ])
      .add_deck(id: 1, name: "Default", desc: "")
      .add_deck(id: 1650000000001, name: "Parent::Child", desc: "root desc")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001,
                fields: [ "hello", "bonjour <b>!</b>" ], tags: " core ")
      .add_note(id: 1600000000102, guid: "g2", mid: 1600000000002,
                fields: [ "{{c1::un}} {{c2::deux}}", "" ], tags: "numbers french")
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001,
                queue: 0, due: 7)
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1650000000001,
                ord: 0, queue: 2, due: 12, ivl: 30, factor: 2350, reps: 4, lapses: 1)
      .add_revlog(id: 1600000000301, cid: 1600000000202, ease: 3, ivl: 30, time: 1500)
      .add_media("word.mp3", "fake-mp3-bytes")
      .add_media("image.png", "fake-png-bytes")
  end

  test "reads models, decks, notes, cards, revlog and media" do
    with_apkg(build_package, "test") do |path|
      Anki::Apkg::Package.new(path).extract! do |pkg|
        col = pkg.collection

        assert_equal 2, col.models.size
        basic = col.models.fetch("1600000000001")
        assert_equal "Basic", basic["name"]
        assert_equal %w[Front Back], basic["flds"].map { |f| f["name"] }
        assert_equal "{{Front}}", basic["tmpls"].first["qfmt"]

        assert_equal "Parent::Child", col.decks.fetch("1650000000001")["name"]

        assert_equal({ notes: 2, cards: 2, revlog: 1 }, col.counts)

        notes = col.each_note.to_a
        assert_equal "g1", notes.first[:guid]
        assert_equal [ "hello", "bonjour <b>!</b>" ], notes.first[:fields]
        assert_equal " core ", notes.first[:tags] # raw; the importer strips

        cards = col.each_card.to_a
        assert_equal 1600000000201, cards.first["id"]

        revlog = col.each_revlog.to_a
        assert_equal 3, revlog.first[:ease]
        assert_equal Time.at(1600000000301 / 1000.0).utc, revlog.first[:reviewed_at]

        assert_equal({ "0" => "word.mp3", "1" => "image.png" }, pkg.media_manifest)
        assert pkg.media_member(0).file?
        assert_equal "fake-mp3-bytes", pkg.media_member(0).read
      end
    end
  end

  test "extracts in two phases: collections first, media only when asked" do
    with_apkg(build_package, "phased") do |path|
      Anki::Apkg::Package.new(path).with_package do |pkg|
        pkg.extract_collections!

        # The collection is readable without extracting any media.
        assert_equal({ notes: 2, cards: 2, revlog: 1 }, pkg.collection.counts)
        assert_equal({ }, pkg.media_manifest) # manifest not extracted yet
        assert_nil pkg.media_member(0)

        pkg.extract_media!
        assert_equal({ "0" => "word.mp3", "1" => "image.png" }, pkg.media_manifest)
        assert_equal "fake-mp3-bytes", pkg.media_member(0).read
      end
    end
  end

  test "prefers collection.anki21 over collection.anki2" do
    path = build_package.write(Tempfile.new(%w[test .apkg]).path)
    # Re-zip the same collection as .anki21 alongside .anki2
    Dir.mktmpdir do |dir|
      system("unzip", "-oq", path.to_s, "-d", dir, exception: true)
      FileUtils.cp(File.join(dir, "collection.anki2"), File.join(dir, "collection.anki21"))
      system("zip", "-qj", path.to_s, File.join(dir, "collection.anki21"), exception: true)
    end

    Anki::Apkg::Package.new(path).extract! do |pkg|
      assert_match %r{collection\.anki21\z}, pkg.real_collection_path.to_s
    end
  end

  test "raises when the archive has no usable collection member" do
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "collection.anki21b")) # not zstd, not SQLite
      path = File.join(dir, "out.apkg")
      system("zip", "-qj", path, File.join(dir, "collection.anki21b"), exception: true)

      error = assert_raises(Anki::Apkg::UnsupportedFormatError) do
        Anki::Apkg::Package.new(path).extract! { |pkg| pkg.collection }
      end
      assert_match(/no usable collection/i, error.message)
    end
  end

  test "reads an Anki 23.10+ package: schema 18 in a zstd anki21b, protobuf media manifest" do
    builder = AnkiModernApkgBuilder.new
      .add_model(id: 725886, name: "EN-FR", fields: %w[Front Back Audio],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{FrontSide}}<hr>{{Back}}{{Audio}}" } ],
                 css: ".card { color: red; }")
      .add_model(id: 1777020778336, name: "FR-EN Cloze", type: 1, fields: %w[Text Extra],
                 templates: [ { name: "Cloze", front: "{{cloze:Text}}", back: "{{cloze:Text}}{{hint:Extra}}" } ])
      .add_deck(id: 1, name: "Default")
      .add_deck(id: 1777020936287, name: "Dylan French Vocab", desc: "my desc")
      .add_note(id: 1001, guid: "g1", mid: 725886,
                fields: [ "être", "to be", "[sound:a.mp3]" ], tags: "core")
      .add_card(id: 2001, nid: 1001, did: 1777020936287, due: 5)
      .add_media("a.mp3", "fake-mp3-bytes")

    with_apkg(builder, "modern") do |path|
      Anki::Apkg::Package.new(path).extract! do |pkg|
        col = pkg.collection
        assert_instance_of Anki::Apkg::NewCollection, col

        # Normalized tables, not the JSON columns of the placeholder anki2.
        assert_equal 2, col.models.size
        en_fr = col.models.fetch("725886")
        assert_equal "EN-FR", en_fr["name"]
        assert_equal 0, en_fr["type"]
        assert_equal %w[Front Back Audio], en_fr["flds"].map { |f| f["name"] }
        assert_equal ".card { color: red; }", en_fr["css"]
        assert_equal "{{FrontSide}}<hr>{{Back}}{{Audio}}", en_fr["tmpls"].first["afmt"]
        # req is not stored in schema 18; recomputed from the template front.
        assert_equal [ [ 0, "any", [ "Front" ] ] ], en_fr["req"]

        cloze = col.models.fetch("1777020778336")
        assert_equal 1, cloze["type"]
        assert_equal [ [ 0, "any", [ "Text" ] ] ], cloze["req"]

        # Deck description comes from the protobuf kind blob.
        deck = col.decks.fetch("1777020936287")
        assert_equal "Dylan French Vocab", deck["name"]
        assert_equal "my desc", deck["desc"]

        assert_equal({ notes: 1, cards: 1, revlog: 0 }, col.counts)
        note = col.each_note.first
        assert_equal "g1", note[:guid]
        assert_equal [ "être", "to be", "[sound:a.mp3]" ], note[:fields]

        # Protobuf manifest keyed by member ordinal, members decompressed.
        assert_equal({ "0" => "a.mp3" }, pkg.media_manifest)
        assert_equal "fake-mp3-bytes", pkg.media_member(0).read
      end
    end
  end

  test "missing file raises" do
    assert_raises(Anki::Apkg::Error) { Anki::Apkg::Package.new("/nonexistent.apkg") }
  end
end
