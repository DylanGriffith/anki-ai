require "test_helper"

class MediaFile::AttachFromTest < ActiveSupport::TestCase
  PNG_BYTES = FakeOpenAIServer::TINY_PNG_B64.unpack1("m").freeze

  setup do
    @user = User.create!(name: "attach-test-user", password: "password123")
    @deck = Deck.create!(user: @user, name: "Attach Deck")
  end

  test "attach_from persists the attachment row, not just the blob" do
    media = @deck.media_files.create!(filename: "a.png", content_type: "image/png")

    file = Tempfile.new([ "attach-test", ".png" ])
    begin
      file.binmode
      file.write(PNG_BYTES)
      file.flush
      media.attach_from(file.path)
    ensure
      file.close!
    end

    # Verify in SQL: the in-memory attach change can mask a missing row, and
    # the web process loads the record fresh — that is where this bug bit.
    # Rails 8.1 defers writing active_storage_attachments while the record is
    # dirty (attach_from sets byte_size), so the row needs an explicit save.
    assert ActiveStorage::Attachment.exists?(record_type: "MediaFile", record_id: media.id,
                                             name: "file"),
           "attachment row missing — serving would 500"
    fresh = MediaFile.find(media.id)
    assert fresh.file.attached?
    assert_equal PNG_BYTES.bytesize, fresh.file.blob.byte_size
    assert_equal PNG_BYTES.bytesize, fresh.byte_size
  end
end
