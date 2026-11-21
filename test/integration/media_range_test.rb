require "test_helper"

class MediaRangeTest < ActionDispatch::IntegrationTest
  test "media responses support HTTP Range requests for audio seeking" do
    user = User.create!(name: "range", password: "password123")
    deck = user.decks.create!(name: "Range deck")
    media = MediaFile.new(deck: deck, filename: "sound.mp3", content_type: "audio/mpeg")
    t = Tempfile.new("media")
    t.binmode
    t.write("0123456789")
    t.flush
    path = t.path
    media.attach_from(path)
    media.save!

    post login_path, params: { name: "range", password: "password123" }

    get media_deck_path(deck, "sound.mp3")
    assert_response :success
    assert_equal "audio/mpeg", response.headers["Content-Type"]
    assert_equal 10, response.headers["Content-Length"].to_i

    get media_deck_path(deck, "sound.mp3"), headers: { "Range" => "bytes=2-5" }
    assert_response :partial_content
    assert_equal "bytes 2-5/10", response.headers["Content-Range"]
    assert_equal "2345", response.body

    get media_deck_path(deck, "sound.mp3"), headers: { "Range" => "bytes=7-" }
    assert_response :partial_content
    assert_equal "789", response.body
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "media requires login" do
    user = User.create!(name: "private", password: "password123")
    deck = user.decks.create!(name: "Private deck")

    get media_deck_path(deck, "whatever.mp3")
    assert_redirected_to login_path
  end
end
