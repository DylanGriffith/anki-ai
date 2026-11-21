require "application_system_test_case"

class ImportDeckTest < ApplicationSystemTestCase
  test "imports an .apkg through the UI" do
    user = User.create!(name: "dylan", password: "password123")

    apkg = AnkiApkgBuilder.new
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back Audio],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{FrontSide}}<hr>{{Back}}{{Audio}}" } ])
      .add_deck(id: 1650000000001, name: "Test French", desc: "A small French deck")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001,
                fields: [ "hello", "bonjour", "[sound:word.mp3]" ], tags: "core")
      .add_note(id: 1600000000102, guid: "g2", mid: 1600000000001,
                fields: [ "dog", "chien", "" ], tags: "animals")
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001, due: 1)
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1650000000001, due: 2)
      .add_media("word.mp3", "fake-mp3-bytes-0123456789")

    with_apkg(apkg, "ui-import") do |path|
      sign_in_as("dylan", "password123")

      click_on "Import .apkg"
      evidence("step2_import_form")

      attach_file "file", path
      click_submit("Import")

      assert_selector "h1", text: "Test French"
      assert_text "2 cards"
      assert_text "2 notes"
      assert_text "1 note types"
      assert_text "1 media files"
      evidence("step2_imported_deck")
    end
  end

  test "shows an error for a non-apkg file" do
    User.create!(name: "dylan", password: "password123")
    bad = Tempfile.new([ "bad", ".apkg" ])
    bad.binmode
    bad.write("this is not a zip file")
    bad.flush

    sign_in_as("dylan", "password123")
    click_on "Import .apkg"
    attach_file "file", bad.path
    click_submit("Import")

    assert_selector "h1", text: "Import Anki deck"
    assert_text(/Import failed/i)
    evidence("step2_import_error")
  ensure
    bad&.close!
  end
end
