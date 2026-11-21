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

  def attach_from(path)
    self.byte_size = File.size(path)
    file.attach(io: File.open(path), filename: filename, content_type: content_type,
                identify: false)
  end
end
