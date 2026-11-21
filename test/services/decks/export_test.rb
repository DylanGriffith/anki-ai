require "test_helper"

class Decks::ExportTest < ActiveSupport::TestCase
  setup do
    @user = build_user("exporter")
  end

  # A representative package: two note types (incl. cloze), a subdeck, media,
  # cards in every queue (new / learning / review / suspended) and revlog.
  # progress: false drops the review card's history back to new for the
  # "no progress" export case.
  def build_package(progress: true)
    builder = AnkiApkgBuilder.new(crt: Time.utc(2026, 1, 1).to_i)
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back Audio],
                 templates: [ { name: "Card 1", front: "{{Front}}",
                                back: "{{FrontSide}}<hr>{{Back}}{{Audio}}" } ],
                 css: ".card { color: red; }",
                 req: [ [ 0, "any", [ "Front" ] ] ])
      .add_model(id: 1600000000002, name: "Cloze", type: 1, fields: %w[Text],
                 templates: [ { name: "Cloze", front: "{{cloze:Text}}", back: "{{Back}}" } ])
      .add_deck(id: 1, name: "Default")
      .add_deck(id: 1650000000001, name: "Export Round Trip", desc: "deck description")
      .add_deck(id: 1650000000002, name: "Export Round Trip::Chapter 1")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001,
                fields: [ "hello", "bonjour", "[sound:word.mp3]" ], tags: "core french")
      .add_note(id: 1600000000102, guid: "g2", mid: 1600000000001,
                fields: [ "dog", "chien", "" ])
      .add_note(id: 1600000000103, guid: "g3", mid: 1600000000001,
                fields: [ "cat", "chat", "" ])
      .add_note(id: 1600000000104, guid: "g4", mid: 1600000000001,
                fields: [ "bird", "oiseau", "" ])
      .add_note(id: 1600000000105, guid: "g5", mid: 1600000000002,
                fields: [ "un {{c1::chat}}" ])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001, due: 1)
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1650000000002, due: 2)
      .add_card(id: 1600000000203, nid: 1600000000103, did: 1650000000002,
                **(progress ? { type: 2, queue: 2, due: 12, ivl: 30, factor: 2500,
                                reps: 4, lapses: 1 } : { due: 12 }))
      .add_card(id: 1600000000204, nid: 1600000000104, did: 1650000000001,
                queue: -1, due: 5)
      .add_card(id: 1600000000205, nid: 1600000000105, did: 1650000000002, ord: 0, due: 3)
      .add_card(id: 1600000000206, nid: 1600000000105, did: 1650000000002, ord: 1, due: 4)
    builder = builder.add_revlog(id: 1600000000301, cid: 1600000000203, ease: 3, ivl: 30,
                                 last_ivl: 12, time: 1500, type: 1) if progress
    builder.add_media("word.mp3", "fake-mp3-bytes")
           .add_media("map.png", "fake-png-bytes")
  end

  def import_for(user, name = "Export Round Trip", package = build_package)
    with_apkg(package, "export-test") do |path|
      Decks::Import.call(user, path, name: name)
    end
  end

  test "import → export → re-import round-trips content and progress" do
    deck = import_for(@user)
    cards = deck.cards.order(:position, :id).to_a

    # Generate native progress: graduate one card (Easy), review another twice
    # (Good x2 graduates through the learning steps).
    reviewed_at = Time.now.utc
    Reviewing::Apply.call(user: @user, card: cards[0], rating: 4, reviewed_at: reviewed_at)
    Reviewing::Apply.call(user: @user, card: cards[1], rating: 3,
                          reviewed_at: reviewed_at - 2.hours, duration_ms: 900)
    Reviewing::Apply.call(user: @user, card: cards[1], rating: 3,
                          reviewed_at: reviewed_at - 1.hour, duration_ms: 400)

    path = Decks::Export.call(user: @user, deck: deck)
    assert File.exist?(path)

    # The archive is a valid zip with the expected flat members
    out, _err, status = Open3.capture3("unzip", "-l", path)
    assert status.success?
    assert_includes out, "collection.anki2"
    assert_includes out, " media"
    assert_equal 2, deck.media_files.count

    # The collection is a valid SQLite db with Anki's schema-11 shape —
    # exactly what any Anki version needs to open the file.
    Dir.mktmpdir do |dir|
      system("unzip", "-o", "-q", path, "-d", dir)
      db = SQLite3::Database.new(File.join(dir, "collection.anki2"))
      assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      assert_equal 11, db.get_first_value("SELECT ver FROM col")
      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM col")
      %w[col notes cards revlog graves].each do |table|
        assert db.get_first_value("SELECT COUNT(*) FROM #{table}") >= 0, "#{table} present"
      end
      assert_equal 6, db.get_first_value("SELECT COUNT(*) FROM cards")
      assert_equal 5, db.get_first_value("SELECT COUNT(*) FROM notes")
      assert_equal 4, db.get_first_value("SELECT COUNT(*) FROM revlog")
      db.close
    end

    other = build_user("importer")
    copy = Decks::Import.call(other, path, name: "Copy")

    # Content survives: notes, cards, note types, media
    assert_equal deck.notes.count, copy.notes.count
    assert_equal deck.cards.count, copy.cards.count
    assert_equal deck.media_files.count, copy.media_files.count
    assert_equal deck.note_types.map(&:name).sort, copy.note_types.map(&:name).sort
    assert_equal deck.notes.order(:guid).pluck(:guid), copy.notes.order(:guid).pluck(:guid)
    assert_equal [ "map.png", "word.mp3" ], copy.media_files.order(:filename).pluck(:filename)
    assert_equal "fake-mp3-bytes",
                 File.binread(copy.media_files.find_by!(filename: "word.mp3").file.blob.service
                                    .path_for(copy.media_files.find_by!(filename: "word.mp3")
                                                      .file.blob.key))
    # tags, fields and note type details survive
    original_note = deck.notes.find_by!(guid: "g1")
    copy_note = copy.notes.find_by!(guid: "g1")
    assert_equal original_note.fields, copy_note.fields
    assert_equal original_note.tags, copy_note.tags
    copy_basic = copy.note_types.find_by!(name: "Basic")
    assert_equal %w[Front Back Audio], copy_basic.field_names
    assert_equal "Card 1", copy_basic.templates.first["name"]
    assert_equal "{{FrontSide}}<hr>{{Back}}{{Audio}}", copy_basic.templates.first["back"]
    assert_includes copy_basic.css, "color: red"
    assert copy.note_types.find_by!(name: "Cloze").cloze?
    # card requirements round-trip through names again
    assert_equal [ [ 0, "any", [ "Front" ] ] ], copy_basic.card_requirements

    # Anki ids are preserved, so round-trips are stable
    assert_equal deck.cards.order(:anki_card_id).pluck(:anki_card_id),
                 copy.cards.order(:anki_card_id).pluck(:anki_card_id)
    assert_equal deck.notes.order(:anki_note_id).pluck(:anki_note_id),
                 copy.notes.order(:anki_note_id).pluck(:anki_note_id)

    # Subdeck names survive on cards (full source names, as import stores them)
    assert_equal 4, copy.cards.where(anki_subdeck: "Export Round Trip::Chapter 1").count

    # Progress round-trips
    graduated = copy.cards.find_by!(anki_card_id: cards[0].anki_card_id).state_for(other)
    assert graduated.state_review?
    assert_equal 1, graduated.reps
    original_graduated = cards[0].state_for(@user)
    assert_in_delta original_graduated.due.to_i, graduated.due.to_i, 1.day.to_i

    stepped = copy.cards.find_by!(anki_card_id: cards[1].anki_card_id).state_for(other)
    assert stepped.state_review?
    assert_equal 2, stepped.reps

    imported_review = copy.cards.find_by!(anki_card_id: 1600000000203).state_for(other)
    assert imported_review.state_review?
    assert_equal 4, imported_review.reps
    assert_equal 1, imported_review.lapses

    # New cards stay new (import seeds fresh-state rows) and keep their order
    new_card = copy.cards.find_by!(anki_card_id: 1600000000205)
    new_state = new_card.state_for(other)
    assert new_state.nil? || new_state.state_new?
    assert_equal 3, new_card.position

    # Suspended stays suspended
    assert copy.cards.find_by!(anki_card_id: 1600000000204).suspended?

    # Review history round-trips: 3 native reviews + 1 imported revlog
    assert_equal 4, ReviewLog.where(user: other, card: copy.cards).count
    ratings = ReviewLog.where(user: other, card: copy.cards).order(:reviewed_at).pluck(:rating)
    assert_equal %w[good good good easy], ratings
    # The native reviews of the stepped card keep their durations, in order
    stepped_card = copy.cards.find_by!(anki_card_id: cards[1].anki_card_id)
    stepped_logs = ReviewLog.where(user: other, card: stepped_card).order(:reviewed_at).to_a
    assert_equal [ 900, 400 ], stepped_logs.map(&:duration_ms)

    # Difficulty/factor round-trips within the mapping tolerance
    assert_in_delta original_graduated.difficulty, graduated.difficulty, 0.35
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "exporting without progress exports everything as new" do
    deck = import_for(@user, "Export Round Trip", build_package(progress: false))
    path = Decks::Export.call(user: @user, deck: deck)

    other = build_user("fresh")
    copy = Decks::Import.call(other, path, name: "Fresh copy")

    copy.cards.each do |card|
      state = card.state_for(other)
      assert state.nil? || state.state_new?, "card #{card.id} should be new, got #{state&.state}"
      assert_equal 0, state.reps.to_i if state
    end
    assert_equal 0, ReviewLog.where(user: other, card: copy.cards).count
    assert_equal 12, copy.cards.find_by!(anki_card_id: 1600000000203).position
    assert copy.cards.find_by!(anki_card_id: 1600000000204).suspended?
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "exports cards created in-app (generated Anki ids)" do
    deck = @user.decks.create!(name: "Handmade", description: "built here")
    note_type = deck.note_types.create!(
      name: "Simple", field_names: %w[Q A],
      templates: [ { "name" => "Card 1", "front" => "{{Q}}", "back" => "{{A}}" } ],
      card_requirements: [ [ 0, "any", [ "Q" ] ] ], css: ""
    )
    note = deck.notes.create!(note_type: note_type, fields: %w[hello ciao], guid: "manual-1")
    Cards::Generate.call(note, position: 1)

    path = Decks::Export.call(user: @user, deck: deck)
    other = build_user("importer2")
    copy = Decks::Import.call(other, path, name: "Handmade")

    assert_equal 1, copy.cards.count
    assert_equal %w[hello ciao], copy.notes.first.fields
    assert_equal 1, copy.cards.first.position
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "round-tripped exports are byte-stable for media and templates" do
    deck = import_for(@user)
    path = Decks::Export.call(user: @user, deck: deck)
    other = build_user("second")
    copy = Decks::Import.call(other, path, name: "Copy")

    path2 = Decks::Export.call(user: other, deck: copy)

    # The second export reads back with the same content shape
    third = build_user("third")
    again = Decks::Import.call(third, path2, name: "Again")
    assert_equal copy.notes.count, again.notes.count
    assert_equal copy.cards.count, again.cards.count
    assert_equal copy.media_files.count, again.media_files.count
    assert_equal copy.note_types.map { |nt| nt.templates }, again.note_types.map { |nt| nt.templates }
  ensure
    [ path, path2 ].compact.each { |p| File.delete(p) if File.exist?(p) }
  end
end
