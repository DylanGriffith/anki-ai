class Decks::StudyController < ApplicationController
  before_action :require_login
  before_action :set_deck

  def show
    build_queue
    if @cards.any?
      @note_type = @card.note.note_type
      @question_html = render_side(:question)
    end
  end

  def reveal
    @card = @deck.cards.find(params[:card_id])
    @typed = params[:typed].to_s
    @note_type = @card.note.note_type
    @question_html = render_side(:question)
    @answer_html = render_side(:answer, typed: @typed, front_side: @question_html)
    @intervals = button_intervals
  end

  def answer
    card = @deck.cards.find(params[:card_id])
    rating = params[:rating].to_i
    head :bad_request unless (1..4).cover?(rating)

    Reviewing::Apply.call(user: current_user, card: card, rating: rating)
    redirect_to study_deck_path(@deck)
  end

  private

  def set_deck
    @deck = Deck.visible_to(current_user).find(params[:deck_id] || params[:id])
  end

  def build_queue
    queue = Reviewing::QueueBuilder.call(user: current_user, deck: @deck)
    @cards = queue[:cards]
    @counts = queue[:counts]
    @card = @cards.first
  end

  def render_side(side, typed: nil, front_side: nil)
    CardHtml.render(@card, side: side, typed: typed, front_side: front_side, media_url: media_url)
  end

  def media_url
    ->(filename) { media_deck_path(@deck, filename) }
  end

  # Interval preview per rating button, like Anki (fuzz disabled so previews
  # are stable).
  def button_intervals
    state = @card.state_for(current_user)
    scheduler = Fsrs::V6.new(enable_fuzz: false)
    (1..4).map do |rating|
      result = scheduler.schedule(
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
      minutes = (interval / 1.minute).round
      [ minutes, 1 ].max.to_s + "m"
    else
      (interval / 1.day).round.to_s + "d"
    end
  end
end
