module Decks
  # Imports an Anki .apkg into a new Deck owned by user, preserving progress.
  #
  # One .apkg = one Deck (subdecks are flattened onto cards as anki_subdeck —
  # see ARCHITECTURE.md decision 3). Importing user gets card_states derived
  # from Anki's SM-2 columns using Anki's own migration heuristics.
  class Import
    # The user already owns a deck with the requested/derived name.
    class DuplicateNameError < StandardError
      def initialize(name)
        super("you already have a deck named “#{name}”. Import again with a different name.")
      end
    end

    def self.call(user, path, name: nil)
      new(user, path, name: name).call
    end

    def initialize(user, path, name: nil)
      @user = user
      @path = path
      @name = name
    end

    def call
      # Fail fast: an explicitly taken deck name needs no file processing.
      validate_name_availability!(@name) if @name.present?

      package = Anki::Apkg::Package.new(@path)
      package.with_package do |pkg|
        # Cheap first pass: collection members only, enough to derive the
        # deck name — big media archives are only extracted once the name
        # is known to be good.
        pkg.extract_collections!
        collection = pkg.collection
        read_source_rows(collection)
        # All source rows (and models/decks/crt) are read eagerly; release
        # the collection's file descriptor before the bulk inserts.
        collection.close
        validate_name_availability!(deck_name)

        pkg.extract_media!
        Deck.transaction do
          deck = create_deck
          note_types = import_note_types(deck)
          note_ids = import_notes(deck, note_types)
          card_ids = import_cards(deck, note_ids)
          import_card_states(deck, card_ids)
          import_review_logs(card_ids)
          import_media(pkg, deck)
          backfill_last_reviewed_at(card_ids)
          deck
        end
      end
    end

    private

    def read_source_rows(collection)
      @col = collection
      @notes = collection.each_note.to_a
      @cards = collection.each_card.to_a
      @revlog = collection.each_revlog.to_a
      @deck_names = collection.decks.transform_values { |d| d["name"] }
      collection.models # warm memoized lookups used after the db is closed
      # did -> card count, to derive the deck name from where the cards live.
      @card_counts = @cards.each_with_object(Hash.new(0)) { |c, h| h[c["did"]] += 1 }
    end

    def create_deck
      Deck.create!(
        user: @user,
        name: deck_name,
        description: derived_description
      )
    end

    # The deck's name: the explicit override, or the name derived from the
    # collection. Resolved once after the source rows are read and validated
    # for availability before any heavy extraction work.
    def deck_name
      @deck_name ||= @name.presence || derived_name
    end

    # Raises DuplicateNameError before heavy work when the importing user
    # already owns a deck with this name (Deck.create! still enforces
    # uniqueness as the race-safe backstop).
    def validate_name_availability!(name)
      return if name.blank?
      return unless @user.decks.exists?(name: name)

      raise DuplicateNameError.new(name)
    end

    def derived_name
      main_did = @card_counts.max_by { |_, count| count }.first
      @deck_names.fetch(main_did.to_s, "Imported deck").split("::").first.to_s.strip.presence || "Imported deck"
    end

    def derived_description
      top_name = derived_name
      root = @col.decks.values
        .select { |d| d["name"].to_s.split("::").first == top_name }
        .min_by { |d| d["name"].to_s.count("::") }
      root && root["desc"].to_s.strip.presence
    end

    def import_note_types(deck)
      used_mids = @notes.map { |n| n[:mid] }.uniq
      used_mids.map do |mid|
        model = @col.models.fetch(mid.to_s) do
          raise Anki::Apkg::Error, "note #{mid} references unknown model"
        end
        field_names = model["flds"].sort_by.with_index { |f, i| f["ord"] || i }.map { |f| f["name"] }
        NoteType.create!(
          deck: deck,
          name: model["name"],
          kind: model["type"] == 1 ? :cloze : :standard,
          field_names: field_names,
          templates: model["tmpls"].sort_by.with_index { |t, i| t["ord"] || i }.map do |t|
            { "name" => t["name"], "front" => t["qfmt"], "back" => t["afmt"] }
          end,
          card_requirements: normalize_requirements(model["req"], field_names),
          css: model["css"]
        )
      end.index_by { |nt| nt.name } # model names are unique in a collection
    end

    def model_name_for(mid)
      @col.models.fetch(mid.to_s, {}).fetch("name", nil)
    end

    # Legacy Anki stores card requirements as [template_ord, kind,
    # [field ordinals]]; our stored format uses field names so that
    # Cards::Generate and the note type UI agree on one representation.
    def normalize_requirements(req, field_names)
      Array(req).filter_map do |(tord, kind, fld_ords)|
        names = Array(fld_ords).map { |fo| fo.is_a?(Integer) ? field_names[fo] : fo }.compact
        [ tord, kind, names ]
      end
    end
    def import_notes(deck, note_types)
      now = Time.now.utc
      rows = @notes.map do |n|
        type_name = model_name_for(n[:mid]) or raise Anki::Apkg::Error, "unknown model #{n[:mid]}"
        {
          deck_id: deck.id,
          note_type_id: note_types.fetch(type_name).id,
          fields: n[:fields],
          tags: n[:tags].strip,
          guid: n[:guid],
          anki_note_id: n[:id],
          created_at: now,
          updated_at: now
        }
      end
      batch_insert(Note, rows)
      assert_imported!(Note, deck.id, rows.size)
      Note.where(deck_id: deck.id).pluck(:anki_note_id, :id).to_h
    end

    def import_cards(deck, note_ids)
      now = Time.now.utc
      rows = @cards.map do |c|
        nid = note_ids[c["nid"]]
        raise Anki::Apkg::Error, "card #{c['id']} references unknown note" unless nid

        {
          note_id: nid,
          deck_id: deck.id,
          template_ord: c["ord"],
          position: position_for(c),
          suspended: c["queue"] == -1,
          anki_subdeck: @deck_names.fetch(c["did"].to_s, ""),
          anki_card_id: c["id"],
          created_at: now,
          updated_at: now
        }
      end
      batch_insert(Card, rows)
      assert_imported!(Card, deck.id, rows.size)
      Card.where(deck_id: deck.id).pluck(:anki_card_id, :id).to_h
    end

    # New cards order by position; anything already introduced sorts last.
    def position_for(card)
      card["queue"] == 0 ? card["due"] : card["id"]
    end

    # Anki SM-2 -> our FSRS-ish state, following Anki's own migration heuristic
    # (stability ≈ interval; difficulty derived from the ease factor).
    def import_card_states(deck, card_ids)
      now = Time.now.utc
      rows = @cards.map do |c|
        our_id = card_ids[c["id"]]
        next nil unless our_id

        queue = c["queue"]
        state = case queue
        when -2, -3, -4 then map_type(c["type"])
        when 0 then :new
        when 1, 3 then :learning
        when 2 then :review
        else map_type(c["type"])
        end

        {
          user_id: @user.id,
          card_id: our_id,
          state: CardState.states.fetch(state),
          stability: c["ivl"].to_i.positive? ? c["ivl"].to_f : nil,
          difficulty: difficulty_from_factor(c["factor"]),
          due: due_for(c),
          reps: c["reps"],
          lapses: c["lapses"],
          remaining_steps: (queue == 1 || queue == 3 || c["type"] == 1 || c["type"] == 3) ? 1 : 0,
          created_at: now,
          updated_at: now
        }
      end.compact
      batch_insert(CardState, rows)
    end

    def map_type(type)
      { 0 => :new, 1 => :learning, 2 => :review, 3 => :relearning }.fetch(type, :new)
    end

    # factor 1300..4000 (ease 1.3..4.0) -> FSRS difficulty 1 (easy)..10 (hard)
    def difficulty_from_factor(factor)
      return nil if factor.to_i.zero?

      ease = factor.to_i / 1000.0
      (10 - (ease - 1.3) * (9 / 2.7)).round(4).clamp(1.0, 10.0)
    end

    # queue 1: epoch seconds. queue 0: new (no due). queue 2/3 and others: day
    # number counted from the collection creation time.
    def due_for(card)
      return nil if card["queue"] == 0

      due = card["due"].to_i
      if due > 100_000_000 # epoch seconds (currently ~1.7e9)
        Time.at(due).utc
      else
        @col.crt + due.days
      end
    end

    def import_review_logs(card_ids)
      now = Time.now.utc
      rows = @revlog.filter_map do |r|
        our_id = card_ids[r[:cid]]
        next nil unless our_id
        next nil unless (1..4).cover?(r[:ease])

        {
          user_id: @user.id,
          card_id: our_id,
          rating: r[:ease],
          reviewed_at: r[:reviewed_at],
          duration_ms: r[:time_ms],
          sync_op_id: nil,
          created_at: now,
          updated_at: now
        }
      end
      batch_insert(ReviewLog, rows)
    end

    def import_media(package, deck)
      package.media_manifest.each do |number, filename|
        filename = filename.to_s
        next if filename.empty? || filename.match?(%r{[/\\]}) || filename.start_with?(".")

        member = package.media_member(number)
        next unless member

        media = MediaFile.new(deck: deck, filename: filename,
                              content_type: MediaFile.content_type_for(filename))
        media.attach_from(member)
        media.save!
      end
    end

    def backfill_last_reviewed_at(card_ids)
      last_seen = @revlog.each_with_object({}) do |r, h|
        our_id = card_ids[r[:cid]]
        h[our_id] = r[:reviewed_at] if our_id && (!h[our_id] || r[:reviewed_at] > h[our_id])
      end
      return if last_seen.empty?

      now = Time.now.utc
      rows = last_seen.map do |card_id, reviewed_at|
        state = CardState.find_by(user: @user, card_id: card_id)
        next unless state

        state.attributes.slice("user_id", "card_id", "state", "stability", "difficulty",
                               "reps", "lapses", "remaining_steps")
              .merge("id" => state.id, "due" => state.due, "last_reviewed_at" => reviewed_at,
                     "created_at" => state.created_at, "updated_at" => now)
      end.compact
      CardState.upsert_all(rows, unique_by: :id) if rows.any?
    end

    # SQLite bounds statement variables, so insert in modest batches.
    # insert_all! (never insert_all): Rails 8.1's insert_all appends
    # ON CONFLICT DO NOTHING, so rows violating any uniqueness constraint
    # would be silently dropped — an import must fail loudly instead.
    def batch_insert(model, rows)
      batch_size = [ 700 / model.column_names.size, 1 ].max
      rows.each_slice(batch_size) { |batch| model.insert_all!(batch) }
    end

    # Belt and braces: nothing may drop rows between insert and lookup.
    def assert_imported!(model, deck_id, expected)
      actual = model.where(deck_id: deck_id).count
      return if actual == expected

      raise Anki::Apkg::Error, "imported only #{actual} of #{expected} #{model.name.pluralize}"
    end
  end
end
