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

  test "prefers collection.anki21 over collection.anki2" do
    path = build_package.write(Tempfile.new(%w[test .apkg]).path)
    # Re-zip the same collection as .anki21 alongside .anki2
    Dir.mktmpdir do |dir|
      system("unzip", "-oq", path.to_s, "-d", dir, exception: true)
      FileUtils.cp(File.join(dir, "collection.anki2"), File.join(dir, "collection.anki21"))
      system("zip", "-qj", path.to_s, File.join(dir, "collection.anki21"), exception: true)
    end

    Anki::Apkg::Package.new(path).extract! do |pkg|
      assert_match %r{collection\.anki21\z}, pkg.collection_path.to_s
    end
  end

  test "raises a helpful error for zstd-only collections (anki21b)" do
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "collection.anki21b"))
      path = File.join(dir, "out.apkg")
      system("zip", "-qj", path, File.join(dir, "collection.anki21b"), exception: true)

      error = assert_raises(Anki::Apkg::UnsupportedFormatError) do
        Anki::Apkg::Package.new(path).extract! { |pkg| pkg.collection_path }
      end
      assert_match(/re-export it from Anki/i, error.message)
    end
  end

  test "missing file raises" do
    assert_raises(Anki::Apkg::Error) { Anki::Apkg::Package.new("/nonexistent.apkg") }
  end
end
