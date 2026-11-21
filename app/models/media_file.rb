class MediaFile < ApplicationRecord
  belongs_to :deck
  has_one_attached :file, service: :local, dependent: :purge_later

  validates :filename, presence: true, uniqueness: { scope: :deck_id },
                       format: { without: %r{[/\\]}, message: "must not contain path separators" }

  CONTENT_TYPES = {
    "mp3" => "audio/mpeg", "m4a" => "audio/mp4", "aac" => "audio/aac", "ogg" => "audio/ogg",
    "oga" => "audio/ogg", "opus" => "audio/ogg", "wav" => "audio/wav", "flac" => "audio/flac",
    "webm" => "video/webm", "mp4" => "video/mp4", "weba" => "audio/webm",
    "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "gif" => "image/gif",
    "bmp" => "image/bmp", "webp" => "image/webp", "svg" => "image/svg+xml", "tif" => "image/tiff",
    "tiff" => "image/tiff"
  }.freeze

  def self.content_type_for(filename)
    CONTENT_TYPES[filename.to_s.split(".").last.to_s.downcase] || "application/octet-stream"
  end

  # Eager upload: attach(io:) defers the actual disk write to the record's
  # commit callback and needs the io to stay open until then — with nobody
  # closing it, importing N media files held N open handles and exhausted
  # the process fd limit (Errno::EMFILE) on big decks. Uploading inside the
  # block lets the file close deterministically, and attaching by signed_id
  # only creates the association.
  def attach_from(path)
    self.byte_size = File.size(path)
    blob = File.open(path) do |io|
      ActiveStorage::Blob.create_and_upload!(io: io, filename: filename,
                                             content_type: content_type,
                                             identify: false,
                                             service_name: :local) # mirror has_one_attached service:
    end
    file.attach(blob.signed_id)
  end
end
