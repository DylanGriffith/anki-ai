require "application_system_test_case"

# Shared helpers for study-session system tests: a small importable deck and
# the sign-in + UI import dance.
module StudySystemHelpers
  def build_study_apkg
    AnkiApkgBuilder.new
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back Audio],
                 templates: [ { name: "Card 1", front: "{{Front}}",
                                back: "{{FrontSide}}<hr id=answer>{{Back}}{{Audio}}" } ])
      .add_deck(id: 1650000000001, name: "Study Test", desc: "Small deck for E2E")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001,
                fields: [ "hello", "bonjour", "" ])
      .add_note(id: 1600000000102, guid: "g2", mid: 1600000000001,
                fields: [ "dog", "chien", "" ])
      .add_note(id: 1600000000103, guid: "g3", mid: 1600000000001,
                fields: [ "water", "l'eau", "[sound:water.mp3]" ])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001, due: 1)
      .add_card(id: 1600000000202, nid: 1600000000102, did: 1650000000001, due: 2)
      .add_card(id: 1600000000203, nid: 1600000000103, did: 1650000000001, due: 3)
      .add_media("water.mp3", "fake-mp3-water-bytes")
  end

  def login_and_import
    User.create!(name: "student", password: "password123")
    sign_in_as("student", "password123")

    with_apkg(build_study_apkg, "study-e2e") do |path|
      click_on "Import .apkg"
      attach_file "file", path
      click_submit("Import")
    end
    assert_selector "h1", text: "Study Test"
    User.find_by!(name: "student").decks.find_by!(name: "Study Test")
  end

  # Polls a JS condition until true (or fails). The session exposes itself as
  # window.__studySession for exactly this kind of state check.
  def wait_until_js(condition, timeout = 15)
    deadline = Time.now + timeout
    until page.evaluate_script(condition)
      raise "timed out waiting for: #{condition}" if Time.now > deadline
      sleep 0.1
    end
    true
  end
end
