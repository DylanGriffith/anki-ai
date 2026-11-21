# Anki AI shells out to the system zip/unzip binaries for .apkg containers
# (see ARCHITECTURE.md decision 2). Fail fast when they are missing.
require "open3"

missing = %w[zip unzip].reject do |bin|
  Open3.capture3("which", bin)[2].success?
end

if missing.any?
  message = "Anki AI requires the #{missing.join(" and ")} binary " \
            "(#{missing.map { |b| "`#{b}`" }.join(" and ")}) on PATH for .apkg import/export."
  if Rails.env.production?
    raise message
  else
    Rails.logger.warn(message)
  end
end
