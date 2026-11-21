module Reviewing
  # Serializes a study queue for the client-side session: both sides of every
  # card pre-rendered (so reveal, media and typed-answer comparisons work with
  # no further server round-trips — i.e. offline), per-rating interval
  # previews like Anki's (fuzz disabled so previews are stable), and the
  # note-type CSS collected into one block.
  class SessionSerializer
    # {{type:Field}} on the back template means the card is a type-answer card.
    TYPE_FILTER = /\{\{type:([^}]+?)\}\}/

    def self.call(user:, deck:, cards:)
      new(user: user, deck: deck, cards: cards).call
    end

    def initialize(user:, deck:, cards:)
      @user = user
      @deck = deck
      @cards = cards
      @media_url = ->(filename) { route_helpers.media_deck_path(@deck, filename) }
      @scheduler = Fsrs::V6.new(enable_fuzz: false)
    end

    def call
      {
        "deck_id" => @deck.id,
        "done_url" => route_helpers.deck_path(@deck),
        "css" => note_types.map { |nt| CardHtml.css(nt) }.join("\n"),
        "cards" => @cards.map { |card| serialize_card(card) }
      }
    end

    private

    def serialize_card(card)
      question = CardHtml.render(card, side: :question, media_url: @media_url)
      answer = CardHtml.render(card, side: :answer, front_side: question, media_url: @media_url)
      data = {
        "id" => card.id,
        "question_html" => question,
        "answer_html" => answer,
        "intervals" => interval_previews(card)
      }
      typed = typed_answer(card)
      data["typed_answer"] = typed unless typed.nil?
      data
    end

    # For {{type:Field}} templates the answer-side comparison can't be
    # pre-rendered (nothing is typed yet), so the expected text is embedded
    # and the client builds the comparison at reveal time.
    def typed_answer(card)
      template = card.note.note_type.template(card.template_ord)
      field_name = template["back"].to_s[TYPE_FILTER, 1]
      return nil if field_name.nil?
      fields = card.note.note_type.field_names.zip(card.note.fields).to_h
      fields[field_name.strip].to_s
    end

    # Interval preview per rating button, mirroring Anki.
    def interval_previews(card)
      state = card.state_for(@user)
      (1..4).map do |rating|
        result = @scheduler.schedule(
          state: {
            state: state&.state&.to_sym || :new,
            stability: state&.stability,
            difficulty: state&.difficulty,
            remaining_steps: state&.remaining_steps || 0,
            last_review: state&.last_reviewed_at
          },
          rating: rating
        )
        format_interval(result.interval)
      end
    end

    def format_interval(interval)
      if interval < 1.day
        [ (interval / 1.minute).round, 1 ].max.to_s + "m"
      else
        (interval / 1.day).round.to_s + "d"
      end
    end

    def note_types
      @note_types ||= @cards.map { |card| card.note.note_type }.uniq
    end

    def route_helpers
      Rails.application.routes.url_helpers
    end
  end
end
