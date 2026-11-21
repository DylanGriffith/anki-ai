require "test_helper"

class Decks::ImportTest < ActiveSupport::TestCase
  CRT = Time.utc(2026, 1, 1).to_i

  def build_package
    learning_due = Time.utc(2026, 1, 10, 12).to_i
    AnkiApkgBuilder.new(crt: CRT)
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back Audio],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{FrontSide}}<hr>{{Back}}{{Audio}}" } ],
                 css: ".card { font-family: sans-serif; }",
                 req: [ [ 0, "any", [ "Front" ] ] ])
      .add_model(id: 1600000000002, name: "Cloze", type: 1, fields: %w[Text],
                 templates: [ { name: "Cloze", front: "{{cloze:Text}}", back: "{{cloze:Text}}" } ])
      .add_deck(id: 1, name: "Default")
      .add_deck(id: 1650000000001, name: "Root Deck", desc: "The root deck description")
      .add_deck(id: 1650000000002, name: "Root Deck::Subdeck A")
      .add_deck(id: 1650000000003, name: "Root Deck::Subdeck A::Deep")
      # new card (position 7) in a subdeck
      .add_note(id: 1600000000101, guid: "n1", mid: 1600000000001,
                fields: [ "hello", "bonjour", "[sound:word.mp3]" ], tags: "core french")
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000003, due: 7)
      # review card with progress + revlog history, in another subdeck
      .add_note(id: 1600000000102, guid: "n2", mid: 1600000000001,
                fields: [ "dog", "chien", "" ])
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1650000000002,
                type: 2, queue: 2, due: 12, ivl: 30, factor: 2500, reps: 4, lapses: 1)
      .add_revlog(id: 1600000000301, cid: 1600000000202, ease: 3, ivl: 30, time: 1500, type: 1)
      .add_revlog(id: 1600000000401, cid: 1600000000202, ease: 4, ivl: 12, last_ivl: 4, time: 900, type: 1)
      # suspended cloze card
      .add_note(id: 1600000000103, guid: "n3", mid: 1600000000002,
                fields: [ "un {{c1::chat}} et {{c2::chien}}" ])
      .add_card(id: 1600000000203, nid: 1600000000103, did: 1650000000002,
                ord: 0, type: 0, queue: -1, due: 99)
      .add_card(id: 1600000000204, nid: 1600000000103, did: 1650000000002,
                ord: 1, type: 0, queue: 0, due: 3)
      # learning card due at a specific epoch second
      .add_note(id: 1600000000104, guid: "n4", mid: 1600000000001,
                fields: [ "cat", "chat", "" ])
      .add_card(id: 1600000000205, nid: 1600000000104, did: 1650000000002,
                type: 1, queue: 1, due: learning_due, ivl: 0, factor: 0, reps: 2, lapses: 0)
      .add_media("word.mp3", "fake-mp3-bytes")
      .add_media("map.png", "fake-png-bytes")
  end

  def import_deck(user:, name: nil)
    with_apkg(build_package, "import") { |path| Decks::Import.call(user, path, name: name) }
  end

  test "imports note types with fields, templates, req and css" do
    deck = import_deck(user: build_user)
    assert_equal 2, deck.note_types.count

    basic = deck.note_types.find_by!(name: "Basic")
    assert basic.standard?
    assert_equal %w[Front Back Audio], basic.field_names
    assert_equal [ { "name" => "Card 1", "front" => "{{Front}}",
                     "back" => "{{FrontSide}}<hr>{{Back}}{{Audio}}" } ], basic.templates
    assert_equal [ [ 0, "any", [ "Front" ] ] ], basic.card_requirements
    assert_equal ".card { font-family: sans-serif; }", basic.css

    cloze = deck.note_types.find_by!(name: "Cloze")
    assert cloze.cloze?
  end

  test "derives the deck name and description from the root deck" do
    deck = import_deck(user: build_user)
    assert_equal "Root Deck", deck.name
    assert_equal "The root deck description", deck.description
  end

  test "name override wins" do
    deck = import_deck(user: build_user, name: "My French")
    assert_equal "My French", deck.name
  end

  test "imports notes with fields, tags and guids" do
    deck = import_deck(user: build_user)
    note = deck.notes.find_by!(guid: "n1")
    assert_equal [ "hello", "bonjour", "[sound:word.mp3]" ], note.fields
    assert_equal "core french", note.tags
    assert_equal 1600000000101, note.anki_note_id
    assert_equal "hello", note.field("Front")
    assert_equal %w[core french], note.tags_list
  end

  test "imports cards with position, subdeck and suspension" do
    deck = import_deck(user: build_user)
    assert_equal 5, deck.cards.count

    new_card = deck.cards.find_by!(anki_card_id: 1600000000201)
    assert_equal 7, new_card.position
    assert_equal "Root Deck::Subdeck A::Deep", new_card.anki_subdeck
    assert_not new_card.suspended?

    suspended = deck.cards.find_by!(anki_card_id: 1600000000203)
    assert suspended.suspended?
  end

  test "maps SM-2 progress to card_states for the importing user" do
    user = build_user
    deck = import_deck(user: user)

    # New card: state new, no due yet
    new_state = deck.cards.find_by!(anki_card_id: 1600000000201).state_for(user)
    assert new_state.state_new?
    assert_nil new_state.due
    assert_nil new_state.stability

    # Review card: stability = ivl, difficulty from factor, due = crt + days
    review_state = deck.cards.find_by!(anki_card_id: 1600000000202).state_for(user)
    assert review_state.state_review?
    assert_equal 30.0, review_state.stability
    # factor 2500 -> ease 2.5 -> D = 10 - (2.5-1.3)*(9/2.7) = 6.0
    assert_in_delta 6.0, review_state.difficulty, 0.001
    assert_equal Time.utc(2026, 1, 1) + 12.days, review_state.due
    assert_equal 4, review_state.reps
    assert_equal 1, review_state.lapses
    # last_reviewed_at backfilled from newest revlog entry
    assert_in_delta Time.at(1600000000401 / 1000.0).utc.to_f, review_state.last_reviewed_at.to_f, 0.001

    # Learning card: epoch-second due
    learning_state = deck.cards.find_by!(anki_card_id: 1600000000205).state_for(user)
    assert learning_state.state_learning?
    assert_equal Time.utc(2026, 1, 10, 12), learning_state.due
    assert_equal 1, learning_state.remaining_steps

    # States exist only for the importing user
    assert_equal 5, user.reload.card_states.count
  end

  test "imports revlog as review logs with ratings and durations" do
    user = build_user
    deck = import_deck(user: user)
    card = deck.cards.find_by!(anki_card_id: 1600000000202)

    logs = card.review_logs.order(:reviewed_at)
    assert_equal 2, logs.count
    assert logs.first.rated_good?
    assert logs.last.rated_easy?
    assert_equal 1500, logs.first.duration_ms
  end

  test "imports media with content types and blobs on disk" do
    deck = import_deck(user: build_user)
    assert_equal 2, deck.media_files.count

    mp3 = deck.media_files.find_by!(filename: "word.mp3")
    assert_equal "audio/mpeg", mp3.content_type
    assert_equal 14, mp3.byte_size
    blob_path = mp3.file.blob.service.path_for(mp3.file.blob.key)
    assert File.file?(blob_path)
    assert_equal "fake-mp3-bytes", File.read(blob_path)

    png = deck.media_files.find_by!(filename: "map.png")
    assert_equal "image/png", png.content_type
  end

  test "renders imported cards through the template engine with media rewriting" do
    deck = import_deck(user: build_user)
    card = deck.cards.find_by!(anki_card_id: 1600000000201)
    media_url = ->(f) { "/decks/#{deck.id}/media/#{f}" }

    question = CardHtml.render(card, side: :question, media_url: media_url)
    assert_equal "hello", question

    answer = CardHtml.render(card, side: :answer, front_side: "hello", media_url: media_url)
    assert_match %r{^hello<hr>bonjour<audio controls[^>]*src="/decks/#{deck.id}/media/word\.mp3"></audio>$}i, answer
  end

  test "sanitizes dangerous field HTML" do
    pkg = build_package
    pkg.add_note(id: 1600000000199, guid: "evil", mid: 1600000000001,
                 fields: [ "<img src=x onerror=alert(1)>", "<script>alert(2)</script>ok", "" ])
    pkg.add_card(id: 1600000000299, nid: 1600000000199, did: 1650000000002, due: 5)
    deck = with_apkg(pkg, "evil") { |path| Decks::Import.call(build_user, path) }

    card = deck.cards.joins(:note).find_by!(notes: { guid: "evil" })
    media_url = ->(f) { "/decks/#{deck.id}/media/#{f}" }
    html = CardHtml.render(card, side: :answer, media_url: media_url)
    assert_no_match(/onerror/i, html)
    assert_no_match(/<script/i, html)
    assert_match(/ok/, html)
  end

  test "cloze cards render masked on the question and revealed on the answer" do
    deck = import_deck(user: build_user)
    card = deck.cards.find_by!(anki_card_id: 1600000000204) # cloze ord 1 -> reviews c2
    media_url = ->(f) { "/decks/#{deck.id}/media/#{f}" }

    q = CardHtml.render(card, side: :question, media_url: media_url)
    assert_equal "un [...] et [...]", q
    a = CardHtml.render(card, side: :answer, media_url: media_url)
    assert_equal %(un [...] et <span class="cloze">chien</span>), a
  end

  test "large imports batch inserts without exceeding SQLite variable limits" do
    pkg = build_package
    250.times do |i|
      pkg.add_note(id: 1600001000000 + i, guid: "bulk-#{i}", mid: 1600000000001,
                   fields: [ "front#{i}", "back#{i}", "" ])
      pkg.add_card(id: 1600002000000 + i, nid: 1600001000000 + i, did: 1650000000002, due: i)
    end
    deck = with_apkg(pkg, "bulk") { |path| Decks::Import.call(build_user, path) }

    assert_equal 250, deck.notes.where("guid LIKE 'bulk-%'").count
    assert_equal 250, deck.cards.where("anki_card_id >= 1600002000000").count
  end

  # Regression for Errno::EMFILE on big imports through the web UI: every
  # media file used to leave an open handle behind, exhausting the file
  # descriptor limit (~256 by default on macOS) around the 250th file.
  test "importing many media files does not leak file descriptors" do
    fd_dir = File.directory?("/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
    open_fds = -> { Dir.glob(File.join(fd_dir, "*")).size }

    pkg = AnkiApkgBuilder.new(crt: CRT)
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{Back}}" } ],
                 req: [ [ 0, "any", [ "Front" ] ] ])
      .add_deck(id: 1, name: "Default")
      .add_note(id: 1600000000101, guid: "n1", mid: 1600000000001, fields: %w[front back])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1, due: 1)
    300.times { |i| pkg.add_media("m#{i}.mp3", "fake-bytes-#{i}") }

    before = open_fds.call
    deck = with_apkg(pkg, "fds") { |path| Decks::Import.call(build_user, path) }
    after = open_fds.call

    assert_equal 300, deck.media_files.count
    assert after <= before + 2, "leaked file descriptors during import: #{before} -> #{after}"
  end

  # Anki's "Change Note Type" keeps GUIDs, so a collection can legitimately
  # hold distinct notes sharing a GUID (e.g. EN->FR and FR->EN of one word).
  test "imports notes that share a guid" do
    pkg = AnkiApkgBuilder.new(crt: CRT)
      .add_model(id: 1600000000001, name: "EN-FR", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{Back}}" } ],
                 req: [ [ 0, "any", [ "Front" ] ] ])
      .add_model(id: 1600000000002, name: "FR-EN", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{Back}}" } ],
                 req: [ [ 0, "any", [ "Front" ] ] ])
      .add_deck(id: 1, name: "Default")
      .add_note(id: 1600000000101, guid: "shared-guid", mid: 1600000000001,
                fields: [ "hello", "bonjour" ])
      .add_note(id: 1600000000102, guid: "shared-guid", mid: 1600000000002,
                fields: [ "bonjour", "hello" ])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1, due: 1)
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1, due: 2)

    deck = with_apkg(pkg, "dupguid") { |path| Decks::Import.call(build_user, path) }

    assert_equal 2, deck.notes.count
    assert_equal 2, deck.cards.count
    assert_equal 2, deck.note_types.count
    assert_equal [ 1600000000101, 1600000000102 ], deck.notes.order(:anki_note_id).pluck(:anki_note_id)
  end

  test "imports an Anki 23.10+ package end-to-end with progress and media" do
    user = build_user
    reviewed_at = Time.at(1_766_000_000).utc
    pkg = AnkiModernApkgBuilder.new
      .add_model(id: 725886, name: "EN-FR", fields: %w[Front Back Audio],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{FrontSide}}<hr>{{Back}}{{Audio}}" } ],
                 css: ".card { color: red; }")
      .add_model(id: 1777020778336, name: "FR-EN Cloze", type: 1, fields: %w[Text Extra],
                 templates: [ { name: "Cloze", front: "{{cloze:Text}}", back: "{{cloze:Text}}" } ])
      .add_deck(id: 1, name: "Default")
      .add_deck(id: 1777020936287, name: "Dylan French Vocab", desc: "my desc")
      .add_note(id: 1001, guid: "g1", mid: 725886,
                fields: [ "être", "to be", "[sound:a.mp3]" ], tags: "core")
      .add_card(id: 2001, nid: 1001, did: 1777020936287, due: 5)
      .add_note(id: 1002, guid: "g2", mid: 1777020778336, fields: [ "un {{c1::chat}}", "" ])
      .add_card(id: 2002, nid: 1002, did: 1777020936287, type: 2, queue: 2, due: 12,
                ivl: 30, factor: 2500, reps: 4, lapses: 1)
      .add_revlog(id: reviewed_at.to_i * 1000, cid: 2002, ease: 3, ivl: 30, time: 1500)
      .add_media("a.mp3", "fake-mp3-bytes")

    deck = with_apkg(pkg, "modern") { |path| Decks::Import.call(user, path) }

    assert_equal "Dylan French Vocab", deck.name
    assert_equal "my desc", deck.description

    note = deck.notes.find_by!(guid: "g1")
    assert_equal [ "être", "to be", "[sound:a.mp3]" ], note.fields
    assert_equal "core", note.tags
    assert deck.note_types.find_by!(name: "EN-FR").standard?
    assert deck.note_types.find_by!(name: "FR-EN Cloze").cloze?
    # req recomputed from the template front, normalized to field names.
    assert_equal [ [ 0, "any", [ "Front" ] ] ], deck.note_types.find_by!(name: "EN-FR").card_requirements
    assert_equal [ [ 0, "any", [ "Text" ] ] ], deck.note_types.find_by!(name: "FR-EN Cloze").card_requirements

    # Progress follows the same SM-2 mapping as legacy imports.
    state = deck.cards.find_by!(anki_card_id: 2002).state_for(user)
    assert state.state_review?
    assert_equal 30.0, state.stability
    assert_equal 6.0, state.difficulty # factor 2500 -> ease 2.5
    assert_equal Time.utc(2026, 1, 13), state.due # crt + 12 days
    assert_equal 4, state.reps

    log = deck.cards.find_by!(anki_card_id: 2002).review_logs.sole
    assert log.rated_good?
    assert_equal 1500, log.duration_ms
    assert_equal reviewed_at, log.reviewed_at

    # Media members are stored decompressed with the right content type.
    media = deck.media_files.sole
    assert_equal "a.mp3", media.filename
    assert_equal "audio/mpeg", media.content_type
    assert_equal "fake-mp3-bytes", media.file.blob.download
  end
end
