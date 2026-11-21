require "open3"

module Decks
  # Exports a deck as a legacy schema-11 .apkg — the format every Anki
  # version and our own importer read — including the requesting user's
  # progress (cards mapped back to Anki's SM-2 columns, review logs as
  # revlog) and all deck media. Returns a Tempfile; the caller streams it
  # and is responsible for deleting it.
  class Export
    # Generated ids for objects created in-app (imported ones keep their
    # original Anki ids). Ranges mimic Anki's real id spaces (ms since epoch)
    # and never overlap, so deck/subdeck, model, note and card ids are unique.
    DECK_ID_BASE  = 1_650_000_000_000
    MODEL_ID_BASE = 1_600_000_000_000
    NOTE_ID_BASE  = 1_550_000_000_000
    CARD_ID_BASE  = 1_500_000_000_000

    LEARNING_STEPS = 2 # FSRS learning steps ([1m, 10m]), for Anki's `left`

    def self.call(user:, deck:)
      new(user: user, deck: deck).call
    end

    def initialize(user:, deck:)
      @user = user
      @deck = deck
      @scheduler = Fsrs::V6.new(enable_fuzz: false)
    end

    def call
      file = Tempfile.new([ @deck.name.gsub(/[^\w.-]/, "-"), ".apkg" ])
      Dir.mktmpdir("anki-export-") do |dir|
        Anki::Apkg::Schema11Writer.new(
          dir: dir, crt: crt,
          models: anki_models, decks: anki_decks, dconf: anki_dconf,
          notes: anki_notes, cards: anki_cards, revlog: anki_revlog,
          media: anki_media
        ).write!
        zip_dir(dir, file.path)
      end
      file.close
      file.path
    end

    private

    # Collection creation time (day-granularity, like Anki): day numbers for
    # review dues are counted from this, so it must be stable per deck.
    def crt
      @crt ||= @deck.created_at.utc.beginning_of_day.to_i
    end

    def day_number(time)
      ((time.utc.to_i - crt) / 1.day).round
    end

    def note_types
      @note_types ||= @deck.note_types.index_by(&:id)
    end

    def anki_note_ids
      @anki_note_ids ||= @deck.notes.to_h { |n| [ n.id, n.anki_note_id || NOTE_ID_BASE + n.id ] }
    end

    def anki_card_ids
      @anki_card_ids ||= @deck.cards.to_h { |c| [ c.id, c.anki_card_id || CARD_ID_BASE + c.id ] }
    end

    def notes
      @notes ||= @deck.notes.to_a
    end

    def cards
      @cards ||= @deck.cards.to_a
    end

    def states_by_card
      @states_by_card ||= CardState.where(user: @user, card: cards).index_by(&:card_id)
    end

    # Subdeck structure is reconstructed from the cards' anki_subdeck names
    # (the import flattens Anki's child decks onto cards as full names).
    # The first "::" component is the original parent deck — drop it so the
    # subdeck nests under this deck's (possibly renamed) name, stably across
    # repeated round-trips.
    def subdeck_ids
      @subdeck_ids ||= begin
        names = @deck.cards.distinct.pluck(:anki_subdeck).reject(&:blank?).sort
        names.each_with_index.to_h { |name, i| [ relative_subdeck_name(name), DECK_ID_BASE + i ] }
      end
    end

    def relative_subdeck_name(full_name)
      parts = full_name.to_s.split("::")
      parts.length > 1 ? parts[1..].join("::") : full_name.to_s
    end

    def root_deck_id
      DECK_ID_BASE + 100
    end

    def anki_decks
      default = { "id" => 1, "name" => "Default", "mod" => 0, "usn" => 0,
                  "lrnToday" => [ 0, 0 ], "revToday" => [ 0, 0 ], "newToday" => [ 0, 0 ],
                  "timeToday" => [ 0, 0 ], "collapsed" => false,
                  "browserCollapsed" => false, "desc" => "", "dyn" => 0, "conf" => 1 }
      decks = { "1" => default }
      decks[root_deck_id.to_s] = default.merge(
        "id" => root_deck_id, "name" => @deck.name, "desc" => @deck.description.to_s
      )
      subdeck_ids.each do |name, id|
        decks[id.to_s] = default.merge("id" => id, "name" => "#{@deck.name}::#{name}")
      end
      decks
    end

    def anki_dconf
      { "1" => {
        "id" => 1, "name" => "Default", "replayq" => true, "timer" => 0, "maxTaken" => 60,
        "usn" => 0, "mod" => 0, "autoplay" => true,
        "lapse" => { "delays" => [ 10 ], "mult" => 0, "minInt" => 1,
                     "leechFails" => 8, "leechAction" => 0 },
        "new" => { "bury" => true, "delays" => [ 1, 10 ], "separate" => true,
                   "order" => 1, "perDay" => @deck.new_per_day },
        "rev" => { "bury" => true, "perDay" => @deck.reviews_per_day,
                   "ivlFct" => 1, "ease4" => 1.3, "maxIvl" => 36_500 }
      } }
    end

    def anki_models
      @deck.note_types.index_by do |nt|
        (MODEL_ID_BASE + nt.id).to_s
      end.transform_values { |nt| model_hash(nt) }
    end

    def model_hash(nt)
      {
        "id" => MODEL_ID_BASE + nt.id, "name" => nt.name, "type" => nt.cloze? ? 1 : 0,
        "mod" => nt.updated_at.to_i, "usn" => 0, "sortf" => 0, "did" => root_deck_id,
        "tmpls" => nt.templates.each_with_index.map do |t, i|
          { "name" => t["name"], "ord" => i, "qfmt" => t["front"], "afmt" => t["back"],
            "bqfmt" => "", "bafmt" => "", "did" => nil }
        end,
        "flds" => nt.field_names.each_with_index.map do |name, i|
          { "name" => name, "ord" => i, "sticky" => false, "rtl" => false,
            "font" => "Arial", "size" => 20, "media" => [] }
        end,
        "css" => nt.css.to_s,
        # field names back to ordinals, as legacy Anki expects
        "req" => Array(nt.card_requirements).map do |(tord, kind, names)|
          [ tord, kind, Array(names).filter_map { |n| nt.field_names.index(n) } ]
        end,
        "tags" => [], "vers" => []
      }
    end

    def anki_notes
      notes.map do |note|
        { id: anki_note_ids.fetch(note.id), guid: note.guid,
          mid: MODEL_ID_BASE + note.note_type_id, mod: note.updated_at.to_i,
          tags: note.tags.to_s.strip, fields: note.fields }
      end
    end

    def anki_cards
      cards.map do |card|
        state = states_by_card[card.id]
        anki_id = anki_card_ids.fetch(card.id)
        { id: anki_id, nid: anki_note_ids.fetch(card.note_id),
          did: subdeck_ids.fetch(relative_subdeck_name(card.anki_subdeck), root_deck_id),
          ord: card.template_ord, mod: card.updated_at.to_i }
          .merge(sm2_columns(card, state))
      end
    end

    # Our FSRS state back to Anki's SM-2 columns. Inverse of the mappings
    # Decks::Import applies on the way in, so import → export → import
    # round-trips progress.
    def sm2_columns(card, state)
      if state.nil? || state.state_new?
        return { type: 0, queue: card.suspended? ? -1 : 0, due: card.position, ivl: 0, factor: 0,
                 reps: state&.reps.to_i, lapses: state&.lapses.to_i, left: 0 }
      end

      type = { "learning" => 1, "review" => 2, "relearning" => 3 }.fetch(state.state)
      queue = state.state_learning? || state.state_relearning? ? 1 : 2
      queue = -1 if card.suspended?

      factor = state.difficulty ? factor_from_difficulty(state.difficulty) : 2500

      if queue == 1
        { type: type, queue: queue, due: (state.due || Time.now.utc).to_i,
          ivl: learning_interval(state), factor: factor,
          reps: state.reps, lapses: state.lapses,
          left: LEARNING_STEPS * 1000 + state.remaining_steps }
      else
        { type: type, queue: queue, due: day_number(state.due || Time.now.utc),
          ivl: review_interval(state), factor: factor,
          reps: state.reps, lapses: state.lapses, left: 0 }
      end
    end

    # Review cards: the interval actually in effect — distance from the last
    # review to the due date — falling back to the scheduler's interval for
    # the current stability (the same formula Anki's FSRS uses).
    def review_interval(state)
      if state.due && state.last_reviewed_at
        interval = ((state.due - state.last_reviewed_at) / 1.day).round
        return [ interval, 1 ].max
      end
      [ @scheduler.next_interval(state.stability).to_i, 1 ].max
    end

    # Learning cards store seconds until due (min 1 step).
    def learning_interval(state)
      if state.due && state.last_reviewed_at
        [ (state.due - state.last_reviewed_at).to_i, 60 ].max
      else
        60
      end
    end

    # Inverse of Import#difficulty_from_factor:
    # difficulty 1 (easy) -> 3000, 10 (hard) -> 1300
    def factor_from_difficulty(difficulty)
      ease = 1.3 + (10.0 - difficulty) * (2.7 / 9)
      (ease * 1000).round.clamp(1300, 4000)
    end

    def anki_revlog
      logs = ReviewLog.where(user: @user, card: cards).order(:reviewed_at, :id).to_a
      by_card = logs.group_by(&:card_id)
      rows = by_card.flat_map do |card_id, card_logs|
        previous_at = nil
        previous_rating = nil
        first = card_logs.first
        card_logs.map do |log|
          interval = previous_at ? ((log.reviewed_at - previous_at) / 1.day).round : 0
          entry = { id: (log.reviewed_at.to_f * 1000).to_i, cid: anki_card_ids.fetch(card_id),
                    # the enum reads back as a string; revlog ease is an integer
                    ease: ReviewLog.ratings.fetch(log.rating), ivl: interval, last_ivl: interval,
                    factor: factor_for(card_id), time_ms: log.duration_ms || 0,
                    type: revlog_type(first == log, previous_rating) }
          previous_at = log.reviewed_at
          previous_rating = log.rating
          entry
        end
      end.sort_by { |r| r[:id] }
      # Two reviews in the same millisecond would collide on the primary key.
      rows.each_cons(2) do |a, b|
        b[:id] = a[:id] + 1 if b[:id] <= a[:id]
      end
      rows
    end

    def revlog_type(first_review, previous_rating)
      return 0 if first_review # learn
      return 2 if previous_rating == 1 # relearn after a lapse
      1 # review
    end

    def factor_for(card_id)
      state = states_by_card[card_id]
      state&.difficulty ? factor_from_difficulty(state.difficulty) : 2500
    end

    def anki_media
      @deck.media_files.map do |media|
        [ media.filename, media.file.blob.service.path_for(media.file.blob.key) ]
      end
    end

    # Flat .apkg members (collection.anki2, media manifest, numbered media).
    def zip_dir(dir, out_path)
      members = [ "collection.anki2", "media" ] + @deck.media_files.count.times.map(&:to_s)
      FileUtils.rm_f(out_path) # zip refuses pre-existing empty files
      out, err, status = Open3.capture3("zip", "-q", "-j", out_path,
                                        *members.map { |m| File.join(dir, m) })
      raise Anki::Apkg::Error, "zip failed (#{status.exitstatus}): #{err.presence || out}" unless status.success?
    end
  end
end
