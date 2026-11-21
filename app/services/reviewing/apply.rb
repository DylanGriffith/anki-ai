module Reviewing
  # Applies a single review to a card, persisting the FSRS state transition
  # and the review log. Used by the online study flow AND the offline sync
  # endpoint (which passes its own reviewed_at), so results are identical
  # wherever a review originated.
  class Apply
    SCHEDULER = Fsrs::V6.new

    def self.call(user:, card:, rating:, reviewed_at: Time.now.utc, duration_ms: 0, sync_op_id: nil)
      new(user: user, card: card, rating: rating, reviewed_at: reviewed_at,
          duration_ms: duration_ms, sync_op_id: sync_op_id).call
    end

    def initialize(user:, card:, rating:, reviewed_at:, duration_ms:, sync_op_id:)
      @user = user
      @card = card
      @rating = rating
      @reviewed_at = reviewed_at
      @duration_ms = duration_ms
      @sync_op_id = sync_op_id
    end

    def call
      Card.transaction do
        state = find_or_build_state
        result = SCHEDULER.schedule(
          state: { state: state.state.to_sym, stability: state.stability,
                   difficulty: state.difficulty, remaining_steps: state.remaining_steps,
                   last_review: state.last_reviewed_at },
          rating: @rating, now: @reviewed_at
        )

        state.update!(
          state: result.state.state,
          stability: result.state.stability,
          difficulty: result.state.difficulty,
          remaining_steps: result.state.remaining_steps,
          due: result.due,
          last_reviewed_at: @reviewed_at,
          reps: state.reps + 1,
          lapses: state.lapses + (result.lapsed? ? 1 : 0)
        )

        ReviewLog.create!(
          user: @user, card: @card, rating: @rating, reviewed_at: @reviewed_at,
          duration_ms: @duration_ms, sync_op_id: @sync_op_id
        )
        state
      end
    end

    private

    def find_or_build_state
      @card.card_states.find_or_create_by!(user: @user) do |s|
        s.state = :new
        s.reps = 0
        s.lapses = 0
        s.remaining_steps = 0
      end
    end
  end
end
