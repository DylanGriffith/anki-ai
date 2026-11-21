# Slow tests that import the real decks in fixtures/. Run with:
#   bin/rails test:fixtures
# Gated behind ANKI_FIXTURES=1 so they stay out of the default suite.
if ENV["ANKI_FIXTURES"] == "1"
  require "test_helper"

  class FixtureImportTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("fixtures")

    test "imports Ultimate Geography (images, 4 card templates per note)" do
      user = build_user("geographer")
      start = Time.current
      deck = Decks::Import.call(user, FIXTURES.join("Ultimate_Geography_v53.apkg").to_s)
      elapsed = (Time.current - start).round(1)

      assert_equal "Ultimate Geography", deck.name
      assert_predicate deck.description, :present?

      assert_equal 319, deck.notes.count
      assert_equal 978, deck.cards.count # 4 templates x 319 - filtered by req
      assert_equal 546, deck.media_files.count

      note_type = deck.note_types.sole
      assert_equal [ "Country", "Country info", "Capital", "Capital info", "Capital hint", "Flag", "Flag similarity", "Map" ], note_type.field_names
      assert_equal 4, note_type.templates.size
      assert_equal [ "Country - Capital", "Capital - Country", "Flag - Country", "Map - Country" ],
                   note_type.templates.map { |t| t["name"] }

      # First note renders through the real templates: England -> London
      card = deck.cards.joins(:note).order(:id).first
      media_url = ->(f) { "/decks/#{deck.id}/media/#{f}" }
      q = CardHtml.render(card, side: :question, media_url: media_url)
      assert_match(/England/, q)
      assert_no_match(/London/, q)

      a = CardHtml.render(card, side: :answer, front_side: q, media_url: media_url)
      assert_match(/London/, a)

      # Flag and Map templates render the images through the media route
      england = deck.notes.find { |n| n.field("Country") == "England" }
      flag_card = england.cards.find_by!(template_ord: 2)
      map_card = england.cards.find_by!(template_ord: 3)
      flag_q = CardHtml.render(flag_card, side: :question, media_url: media_url)
      assert_match(%r{<img[^>]*src="/decks/#{deck.id}/media/ug-flag-england\.svg"}, flag_q)
      map_a = CardHtml.render(map_card, side: :question, media_url: media_url)
      assert_match(%r{<img[^>]*src="/decks/#{deck.id}/media/ug-map-england\.png"}, map_a)

      # All cards are new; positions round-trip exactly from the source's new-card due values
      assert_equal 978, user.card_states.where(state: :new).count
      source_path = FIXTURES.join("Ultimate_Geography_v53.apkg").to_s
      source_dues = Anki::Apkg::Package.new(source_path).extract! do |pkg|
        pkg.collection.each_card.filter_map { |c| c["queue"] == 0 ? c["due"] : nil }.sort
      end
      assert_equal source_dues, deck.cards.order(:position).pluck(:position)

      puts "\nUltimate Geography imported in #{elapsed}s"
    end

    test "imports 5000 French Words (audio, subdecks, 18 note types)" do
      user = build_user("francophile")
      start = Time.current
      deck = Decks::Import.call(user, FIXTURES.join("5000_most_frequently_used_French_words_v_60.apkg").to_s)
      elapsed = (Time.current - start).round(1)

      assert_equal "5000 Most Common French Words", deck.name

      assert_equal 15_474, deck.notes.count
      assert_equal 15_474, deck.cards.count
      assert_equal 15, deck.note_types.count # 18 models exist; 15 are used by notes

      # Subdecks preserved on cards (of the 62 decks in the collection, 38 hold cards)
      subdecks = deck.cards.distinct.pluck(:anki_subdeck).reject(&:blank?)
      assert_equal 38, subdecks.count
      assert subdecks.all? { |sd| sd.start_with?("5000 Most Common French Words") }

      # Audio: notes reference [sound:...] files that exist in media_files
      audio_note = deck.notes.find { |n| n.fields.join.include?("[sound:") }
      assert_not_nil audio_note, "expected at least one note with audio"
      referenced = audio_note.fields.join.scan(/\[sound:([^\]]+)\]/).flatten
      assert referenced.all? { |f| deck.media_files.exists?(filename: f) }

      media_count = deck.media_files.count
      assert media_count > 5_000, "expected thousands of audio files, got #{media_count}"

      # The audio media actually serves bytes
      mp3 = deck.media_files.where("filename LIKE '%.mp3'").first
      assert_predicate mp3, :present?
      blob_path = mp3.file.blob.service.path_for(mp3.file.blob.key)
      assert File.file?(blob_path)
      assert File.size(blob_path).positive?

      puts "\n5000 French Words imported in #{elapsed}s (#{media_count} media files)"
    end
  end
end
