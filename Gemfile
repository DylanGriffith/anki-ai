source "https://rubygems.org"

gem "rails", "~> 8.1.4", ">= 8.1.4.1"
gem "propshaft"
gem "sqlite3", ">= 2.1"
gem "fiddle" # stdlib-externalized FFI (Ruby 4.0): binds system libzstd for Anki 23.10+ imports
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"

# Authentication (has_secure_password)
gem "bcrypt", "~> 3.1.7"

# Background jobs (AI agent loop)
gem "solid_queue"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Windows does not include zoneinfo files, so the tzinfo-data gem is used
gem "tzinfo-data", platforms: %i[ windows jruby ]

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end
