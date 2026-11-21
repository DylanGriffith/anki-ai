require "application_system_test_case"

# End-to-end .apkg export: the UI download produces an archive our own
# reader (and any Anki version) can consume, and it re-imports with all
# content intact.
class ExportDeckTest < ApplicationSystemTestCase
  include StudySystemHelpers

  setup do
    clear_download_dir
  end

  teardown do
    clear_download_dir
  end

  test "exporting a deck downloads an .apkg that re-imports with all content" do
    deck = login_and_import
    visit deck_path(deck)
    assert_text "3 cards"
    assert_text "1 media files"
    evidence("step5_export_button")

    # A download click never finishes Turbo's visit (no page load follows a
    # download), so click_on's settle would hang; click directly and poll the
    # filesystem instead. The turbo-busy test flag stays true after a
    # cancelled navigation — reset it for the helpers that settle.
    find_link("Export .apkg").execute_script("this.click()")
    path = wait_for_download("Study Test.apkg")
    page.execute_script("window.__turboBusy = false")

    # The archive is a flat legacy .apkg: schema-11 collection, media
    # manifest, and numbered media members.
    out, _err, status = Open3.capture3("unzip", "-l", path)
    assert status.success?
    assert_includes out, "collection.anki2"
    assert_includes out, "media"

    # Our own reader accepts the package and finds all content, including
    # the deck's media manifest.
    package = Anki::Apkg::Package.new(path)
    package.with_package do |pkg|
      pkg.extract_collections!
      pkg.extract_media!
      assert_equal [ "water.mp3" ], pkg.media_manifest.values

      collection = pkg.collection
      assert_equal 3, collection.each_note.to_a.size
      assert_equal 3, collection.each_card.to_a.size
      collection.close
    end

    # And the file imports back through the UI with a fresh name
    click_on "Back"
    click_on "Import .apkg"
    attach_file "file", path
    fill_in "name", with: "Reimported"
    click_submit("Import")
    assert_selector "h1", text: "Reimported"
    assert_text "3 cards"

    reimported = User.find_by!(name: "student").decks.find_by!(name: "Reimported")
    assert_equal 3, reimported.cards.count
    assert_equal [ "water.mp3" ], reimported.media_files.pluck(:filename)
    evidence("step5_reimported")
  end

  private

  def clear_download_dir
    FileUtils.rm_rf(Dir[ApplicationSystemTestCase::EXPORT_DOWNLOAD_DIR.join("*")])
  end

  # Chrome writes <name>.crdownload while a download is in flight; the file
  # is complete only once no partial file remains.
  def wait_for_download(filename, timeout: 30)
    path = ApplicationSystemTestCase::EXPORT_DOWNLOAD_DIR.join(filename)
    deadline = Time.now + timeout
    until path.exist? && Dir[ApplicationSystemTestCase::EXPORT_DOWNLOAD_DIR.join("*.crdownload")].empty?
      raise "download of #{filename} did not complete" if Time.now > deadline

      sleep 0.25
    end
    path.to_s
  end
end
