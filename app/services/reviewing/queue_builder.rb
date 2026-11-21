module Reviewing
  # Builds the study queue for a (deck, user): due learning/relearning/review
  # cards first (by due), then new cards (by position), respecting the deck's
  # daily limits. New cards may have no card_state row yet (created lazily on
  # first review); those count as new.
  class QueueBuilder
    def self.call(user:, deck:, now: Time.now.utc)
      new(user: user, deck: deck, now: now).call
    end

    attr_reader :counts

    def initialize(user:, deck:, now:)
      @user = user
      @deck = deck
      @now = now
    end

    def call
      reviews_done = ReviewLog.where(user: @user)
                              .where(card: @deck.cards)
                              .where("reviewed_at >= ?", day_start).count
      new_done = ReviewLog.where(user: @user)
                          .where(card: @deck.cards)
                          .where("reviewed_at >= ?", day_start)
                          .where.not(card_id: reviewed_earlier_card_ids)
                          .count

      review_budget = [ @deck.reviews_per_day - reviews_done, 0 ].max
      new_budget = [ @deck.new_per_day - new_done, 0 ].max

      due_cards = due_states.order(:due).limit(review_budget).map(&:card)
      new_cards = new_queue.limit(new_budget).to_a

      @counts = {
        due_now: due_states.count,
        due_learning_future: future_learning_count,
        new_remaining: [ new_queue.count, new_budget ].min,
        reviews_done_today: reviews_done,
        new_done_today: new_done,
        next_due_at: next_due_at
      }

      { cards: due_cards + new_cards, counts: @counts }
    end

    private

    def day_start
      @now.beginning_of_day
    end

    # Due learning/relearning/review states for this user in this deck.
    def due_states
      CardState.joins(:card)
               .where(user: @user, card: { deck_id: @deck.id })
               .where(state: [ :learning, :relearning, :review ])
               .where("card_states.due <= ?", @now)
               .where(card: { suspended: false })
    end

    def future_learning_count
      CardState.joins(:card)
               .where(user: @user, card: { deck_id: @deck.id })
               .where(state: [ :learning, :relearning ])
               .where("card_states.due > ?", @now)
               .where(card: { suspended: false })
               .count
    end

    # New cards (state new or no state row), ordered by position.
    def new_queue
      Card.where(deck_id: @deck.id, suspended: false)
          .where.not(id: non_new_card_ids)
          .order(:position, :id)
    end

    # Cards this user has already introduced (any non-new state).
    def non_new_card_ids
      CardState.joins(:card)
               .where(user: @user, card: { deck_id: @deck.id })
               .where.not(state: :new)
               .select(:card_id)
    end

    # Earliest upcoming due time among non-new states (for the waiting screen).
    def next_due_at
      CardState.joins(:card)
               .where(user: @user, card: { deck_id: @deck.id })
               .where(state: [ :learning, :relearning, :review ])
               .where("card_states.due > ?", @now)
               .minimum(:due)
    end

    # Cards the user had already reviewed before today (for new-done counting).
    def reviewed_earlier_card_ids
      ReviewLog.where(user: @user)
               .where(card: @deck.cards)
               .where("reviewed_at < ?", day_start)
               .distinct.select(:card_id)
    end
  end
end
