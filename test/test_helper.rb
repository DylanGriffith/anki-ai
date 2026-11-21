ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |file| require file }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    def build_user(name = "tester")
      User.create!(name: name, password: "password123")
    end

    # Writes a builder .apkg to a Tempfile that stays referenced (unreferenced
    # Tempfiles are unlinked by their GC finalizer mid-test otherwise).
    def with_apkg(builder, basename = "anki")
      file = Tempfile.new([ basename, ".apkg" ])
      builder.write(file.path)
      yield file.path
    ensure
      file&.close!
    end
  end
end
