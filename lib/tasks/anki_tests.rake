desc "Run the slow Anki fixture import tests against the real decks in fixtures/"
task "test:fixtures" do
  ENV["ANKI_FIXTURES"] = "1"
  sh "bin/rails", "test", "test/anki_fixtures"
end
