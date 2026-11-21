module Fsrs
  # Faithful Ruby port of FSRS-6, following the canonical py-fsrs scheduler
  # (open-spaced-repetition/py-fsrs) and the algorithm spec at
  # https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm
  #
  # Memory state: (S)tability in days, (D)ifficulty in [1, 10]. Retention uses
  # a power forgetting curve with trainable decay (w20).
  #
  # Pure value in / value out: no ActiveRecord knowledge. The same code
  # schedules online reviews and offline-synced reviews (which carry their own
  # reviewed_at), so results are identical either way.
  #
  # State values: :new, :learning, :review, :relearning.
  # learning/relearning cards carry remaining_steps (steps left incl. current).
  class V6
    DEFAULT_PARAMETERS = [
      0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666,
      0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912,
      0.0658, 0.1542
    ].freeze

    STABILITY_MIN = 0.001
    MIN_DIFFICULTY = 1.0
    MAX_DIFFICULTY = 10.0

    FUZZ_RANGES = [
      { start: 2.5, end: 7.0, factor: 0.15 },
      { start: 7.0, end: 20.0, factor: 0.1 },
      { start: 20.0, end: Float::INFINITY, factor: 0.05 }
    ].freeze

    attr_reader :parameters, :desired_retention, :learning_steps, :relearning_steps,
                :maximum_interval, :enable_fuzz

    def initialize(parameters: DEFAULT_PARAMETERS, desired_retention: 0.9,
                   learning_steps: [ 60, 600 ], relearning_steps: [ 600 ],
                   maximum_interval: 36_500, enable_fuzz: true)
      raise ArgumentError, "expected 21 parameters" unless parameters.size == 21

      @parameters = parameters.freeze
      @desired_retention = desired_retention
      @learning_steps = learning_steps.freeze   # seconds
      @relearning_steps = relearning_steps.freeze
      @maximum_interval = maximum_interval
      @enable_fuzz = enable_fuzz

      @decay = -@parameters[20]
      @factor = 0.9**(1.0 / @decay) - 1.0
    end

    State = Struct.new(:state, :stability, :difficulty, :remaining_steps, :last_review,
                       keyword_init: true)

    Result = Struct.new(:state, :due, :interval, keyword_init: true) do
      def lapsed? = false
    end

    # Ratings: 1 again, 2 hard, 3 good, 4 easy.
    # Returns Result with the next State and the due time (= now + interval).
    def schedule(state:, rating:, now: Time.now.utc)
      raise ArgumentError, "rating must be 1..4" unless (1..4).cover?(rating)

      state = State.new(
        state: state[:state]&.to_sym || :new,
        stability: state[:stability],
        difficulty: state[:difficulty],
        remaining_steps: state[:remaining_steps] || 0,
        last_review: state[:last_review]
      )
      lapsed = false

      case state.state
      when :new, :learning
        state, interval, lapsed = schedule_learning(state, rating, now)
      when :review
        state, interval, lapsed = schedule_review(state, rating, now)
      when :relearning
        state, interval, lapsed = schedule_relearning(state, rating, now)
      else
        raise ArgumentError, "unknown state #{state.state}"
      end

      interval = fuzz_interval(interval) if enable_fuzz && state.state == :review
      Result.new(state: state, due: now + interval, interval: interval).tap do |r|
        r.define_singleton_method(:lapsed?) { lapsed }
      end
    end

    # Retrievability now: probability of recall given time since last review.
    def retrievability(state, now: Time.now.utc)
      return 0.0 if state[:last_review].nil? || state[:stability].nil?

      elapsed_days = [ [ (now - state[:last_review]) / 1.day, 0 ].max, 0 ].max.floor
      (1 + @factor * elapsed_days / state[:stability])**@decay
    end

    # The interval (days) a card with this stability is scheduled at, at the
    # desired retention. Used for button previews; rounds like py-fsrs.
    def next_interval(stability)
      interval = (stability / @factor) * (desired_retention**(1.0 / @decay) - 1.0)
      interval = interval.round
      interval.clamp(1, maximum_interval)
    end

    private

    def schedule_learning(state, rating, now)
      # First rating of a new card: seed memory state from the rating.
      if state.stability.nil? || state.difficulty.nil?
        state = State.new(
          state: :learning,
          stability: clamp_stability(@parameters[rating - 1]),
          difficulty: initial_difficulty(rating),
          remaining_steps: learning_steps.size,
          last_review: state.last_review
        )
      else
        # Subsequent learning reviews update memory like py-fsrs does
        # (same-day short-term, or long-term when a day has passed).
        state = update_memory(state, rating, now)
      end

      return graduate(state, now) if learning_steps.empty?

      case rating
      when 1 # again: back to the first step
        state = with(state, remaining_steps: learning_steps.size)
        [ state, learning_steps.first, false ]
      when 2 # hard: stay on the current step
        [ state, hard_interval(step_index(state, learning_steps), learning_steps), false ]
      when 3 # good: advance; graduate after the last step
        remaining = state.remaining_steps - 1
        if remaining <= 0
          graduate(state, now)
        else
          [ with(state, remaining_steps: remaining),
            learning_steps[learning_steps.size - remaining], false ]
        end
      when 4 # easy: graduate immediately
        graduate(state, now)
      end
    end

    def schedule_review(state, rating, now)
      state = update_memory(state, rating, now)

      if rating == 1 && !relearning_steps.empty?
        state = with(state, state: :relearning, remaining_steps: relearning_steps.size)
        [ state, relearning_steps.first, true ]
      else
        graduate(state, now)
      end
    end

    def schedule_relearning(state, rating, now)
      state = update_memory(state, rating, now)

      return graduate(state, now) if relearning_steps.empty?

      case rating
      when 1
        state = with(state, remaining_steps: relearning_steps.size)
        [ state, relearning_steps.first, true ]
      when 2
        [ state, hard_interval(step_index(state, relearning_steps), relearning_steps), false ]
      when 3
        remaining = state.remaining_steps - 1
        if remaining <= 0
          graduate(state, now)
        else
          [ with(state, remaining_steps: remaining),
            relearning_steps[relearning_steps.size - remaining], false ]
        end
      when 4
        graduate(state, now)
      end
    end

    # Update S/D for a learning/relearning/review card that already has a
    # memory state, using the long-term or same-day path as appropriate.
    def update_memory(state, rating, now)
      stability, difficulty =
        if state.last_review && (now - state.last_review) < 1.day
          [ short_term_stability(state.stability, rating),
            next_difficulty(state.difficulty, rating) ]
        else
          r = retrievability(to_hash(state), now: now)
          [ next_stability(state.difficulty, state.stability, r, rating),
            next_difficulty(state.difficulty, rating) ]
        end
      with(state, stability: stability, difficulty: difficulty)
    end

    def graduate(state, now)
      state = with(state, state: :review, remaining_steps: 0)
      [ state, next_interval(state.stability).days, false ]
    end

    def hard_interval(index, steps)
      if index.zero? && steps.size == 1
        steps.first * 1.5
      elsif index.zero? && steps.size >= 2
        (steps[0] + steps[1]) / 2.0
      else
        steps[index]
      end
    end

    def step_index(state, steps)
      # remaining_steps counts the current step too; index from the front.
      [ steps.size - state.remaining_steps, 0 ].max
    end

    def to_hash(state)
      { state: state.state, stability: state.stability, difficulty: state.difficulty,
        remaining_steps: state.remaining_steps, last_review: state.last_review }
    end

    def with(state, **changes)
      State.new(
        state: changes.fetch(:state, state.state),
        stability: changes.fetch(:stability, state.stability),
        difficulty: changes.fetch(:difficulty, state.difficulty),
        remaining_steps: changes.fetch(:remaining_steps, state.remaining_steps),
        last_review: changes.fetch(:last_review, state.last_review)
      )
    end

    # --- FSRS-6 core math --------------------------------------------------

    def initial_difficulty(rating, clamp: true)
      d = @parameters[4] - Math.exp(@parameters[5] * (rating - 1)) + 1
      clamp ? clamp_difficulty(d) : d
    end

    def next_difficulty(difficulty, rating)
      delta = -@parameters[6] * (rating - 3)
      damped = difficulty + (10 - difficulty) * delta / 9.0
      reverted = @parameters[7] * initial_difficulty(4, clamp: false) +
                 (1 - @parameters[7]) * damped
      clamp_difficulty(reverted)
    end

    def next_stability(difficulty, stability, retrievability, rating)
      s = if rating == 1
            forget_stability(difficulty, stability, retrievability)
          else
            recall_stability(difficulty, stability, retrievability, rating)
          end
      clamp_stability(s)
    end

    def forget_stability(difficulty, stability, retrievability)
      long_term = @parameters[11] * difficulty**(-@parameters[12]) *
                  ((stability + 1)**@parameters[13] - 1) *
                  Math.exp((1 - retrievability) * @parameters[14])
      short_term = stability / Math.exp(@parameters[17] * @parameters[18])
      [ long_term, short_term ].min
    end

    def recall_stability(difficulty, stability, retrievability, rating)
      hard_penalty = rating == 2 ? @parameters[15] : 1.0
      easy_bonus = rating == 4 ? @parameters[16] : 1.0
      stability * (1 + Math.exp(@parameters[8]) * (11 - difficulty) *
                   stability**(-@parameters[9]) *
                   (Math.exp((1 - retrievability) * @parameters[10]) - 1) *
                   hard_penalty * easy_bonus)
    end

    def short_term_stability(stability, rating)
      increase = Math.exp(@parameters[17] * (rating - 3 + @parameters[18])) *
                 stability**(-@parameters[19])
      increase = [ increase, 1.0 ].max if rating >= 2
      clamp_stability(stability * increase)
    end

    # --- Fuzz (Anki-like) ---------------------------------------------------

    def fuzz_interval(interval)
      days = interval / 1.day
      return interval if days < 2.5

      delta = 1.0
      FUZZ_RANGES.each do |range|
        delta += range[:factor] *
                 [ [ [ days, range[:end] ].min - range[:start], 0 ].max, 0 ].max
      end
      min_ivl = [ 2, (days - delta).round ].max
      max_ivl = [ (days + delta).round, maximum_interval ].min
      min_ivl = [ min_ivl, max_ivl ].min

      fuzzed = min_ivl + Random.rand * (max_ivl - min_ivl + 1)
      [ fuzzed.floor, maximum_interval ].min.days
    end

    def clamp_difficulty(d)
      d.clamp(MIN_DIFFICULTY, MAX_DIFFICULTY)
    end

    def clamp_stability(s)
      [ s, STABILITY_MIN ].max
    end
  end
end
