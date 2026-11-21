require "test_helper"

class Fsrs::V6Test < ActiveSupport::TestCase
  # Expected values below were computed independently (Python) from the
  # published FSRS-6 formulas and default parameters, mirroring py-fsrs.
  def sched(**kwargs)
    Fsrs::V6.new(enable_fuzz: false, **kwargs)
  end

  def state(**kwargs)
    { state: kwargs.fetch(:state, :new), stability: kwargs[:stability],
      difficulty: kwargs[:difficulty], remaining_steps: kwargs.fetch(:remaining_steps, 0),
      last_review: kwargs[:last_review] }
  end

  test "initial stability and difficulty are seeded from the first rating" do
    s = sched
    result = s.schedule(state: state(state: :new), rating: 3, now: Time.utc(2026, 1, 1))
    assert_equal :learning, result.state.state
    assert_in_delta 2.3065, result.state.stability, 1e-6
    assert_in_delta 2.118104, result.state.difficulty, 1e-6
    assert_equal 1, result.state.remaining_steps # good advanced past step 1
  end

  test "new card: good walks learning steps, second good graduates at I(S0(3))" do
    s = sched
    now = Time.utc(2026, 1, 1, 10)

    first = s.schedule(state: state(state: :new), rating: 3, now: now)
    assert_equal :learning, first.state.state
    assert_equal 1, first.state.remaining_steps
    assert_equal now + 10.minutes, first.due

    second = s.schedule(state: { state: :learning, stability: first.state.stability,
                                 difficulty: first.state.difficulty,
                                 remaining_steps: 1, last_review: now },
                        rating: 3, now: now + 10.minutes)
    assert_equal :review, second.state.state
    assert_equal 2.days, second.interval # round(I(2.3065)) == 2
  end

  test "new card: easy graduates immediately at I(S0(4))" do
    s = sched
    result = s.schedule(state: state(state: :new), rating: 4, now: Time.utc(2026, 1, 1))
    assert_equal :review, result.state.state
    assert_in_delta 8.2956, result.state.stability, 1e-6
    assert_equal 8.days, result.interval
  end

  test "new card: again repeats the first learning step" do
    s = sched
    result = s.schedule(state: state(state: :new), rating: 1, now: Time.utc(2026, 1, 1))
    assert_equal :learning, result.state.state
    assert_equal 2, result.state.remaining_steps
    assert_equal 60, result.interval
    assert_in_delta 0.212, result.state.stability, 1e-6
    assert_in_delta 6.4133, result.state.difficulty, 1e-6
  end

  test "review card rated good after 10 days matches reference math" do
    s = sched
    last = Time.utc(2026, 1, 1)
    now = last + 10.days
    input = state(state: :review, stability: 10.0, difficulty: 5.0, last_review: last)

    assert_in_delta 0.9, s.retrievability(input, now: now), 1e-6

    result = s.schedule(state: input, rating: 3, now: now)
    assert_equal :review, result.state.state
    assert_in_delta 32.026729, result.state.stability, 1e-4
    assert_in_delta 4.990228, result.state.difficulty, 1e-6
    assert_equal 32.days, result.interval
  end

  test "hard and easy apply penalty/bonus; again lapses to relearning" do
    s = sched
    last = Time.utc(2026, 1, 1)
    now = last + 10.days
    base = state(state: :review, stability: 10.0, difficulty: 5.0, last_review: last)

    hard = s.schedule(state: base, rating: 2, now: now)
    assert_in_delta 23.246875, hard.state.stability, 1e-4

    easy = s.schedule(state: base, rating: 4, now: now)
    assert_in_delta 51.253862, easy.state.stability, 1e-4

    again = s.schedule(state: base, rating: 1, now: now)
    assert_equal :relearning, again.state.state
    assert_in_delta 1.391987, again.state.stability, 1e-4
    assert_equal 600, again.interval # relearning step: 10 minutes
    assert again.lapsed?

    # Relearning good graduates back to review
    relearned = state(state: :relearning, stability: again.state.stability,
                      difficulty: again.state.difficulty, remaining_steps: 1,
                      last_review: now)
    good = s.schedule(state: relearned, rating: 3, now: now + 10.minutes)
    assert_equal :review, good.state.state
  end

  test "same-day reviews use short-term stability" do
    s = sched
    last = Time.utc(2026, 1, 1, 10)
    now = last + 20.minutes
    base = state(state: :review, stability: 10.0, difficulty: 5.0, last_review: last)

    good = s.schedule(state: base, rating: 3, now: now)
    assert_in_delta 10.0, good.state.stability, 1e-6 # increase clamped to >= 1

    again = s.schedule(state: base, rating: 1, now: now)
    assert_in_delta 3.051249, again.state.stability, 1e-4
  end

  test "difficulty updates include damping, mean reversion and clamping" do
    s = sched
    # rating again pushes difficulty up: D'=next_difficulty(5,1) = 8.341762
    result = s.schedule(
      state: state(state: :review, stability: 10.0, difficulty: 5.0,
                   last_review: Time.utc(2026, 1, 1)),
      rating: 1, now: Time.utc(2026, 1, 11)
    )
    assert_in_delta 8.341762, result.state.difficulty, 1e-4

    # Extreme values clamp into [1, 10]
    low = s.schedule(state: state(state: :review, stability: 10.0, difficulty: 1.0,
                                  last_review: Time.utc(2026, 1, 1)),
                     rating: 4, now: Time.utc(2026, 1, 11))
    assert low.state.difficulty >= 1.0
  end

  test "higher ratings produce longer intervals from the same state" do
    s = sched
    base = state(state: :review, stability: 5.0, difficulty: 5.0,
                 last_review: Time.utc(2026, 1, 1))
    intervals = [ 2, 3, 4 ].map do |g|
      s.schedule(state: base, rating: g, now: Time.utc(2026, 1, 8)).interval
    end
    assert_equal intervals.sort, intervals
    assert intervals.first < intervals.last
  end

  test "intervals respect minimum 1 day and maximum_interval" do
    s = sched(maximum_interval: 100)
    assert_equal 1, s.next_interval(0.05)
    assert_equal 100, s.next_interval(1_000_000)
  end

  test "retrievability at t == S is 90%" do
    s = sched
    input = state(state: :review, stability: 10.0, difficulty: 5.0,
                  last_review: Time.utc(2026, 1, 1))
    assert_in_delta 0.9, s.retrievability(input, now: Time.utc(2026, 1, 1) + 10.days), 1e-6
    assert_in_delta 1.0, s.retrievability(input, now: Time.utc(2026, 1, 1)), 1e-6 # t=0 -> 100%
    assert_equal 0.0, s.retrievability({ state: :new }, now: Time.utc(2026, 1, 1))
  end

  test "fuzz keeps intervals inside the documented ranges" do
    s = Fsrs::V6.new(enable_fuzz: true)
    30.times do
      interval = s.schedule(
        state: state(state: :review, stability: 30.0, difficulty: 5.0,
                     last_review: Time.utc(2026, 1, 1)),
        rating: 3, now: Time.utc(2026, 2, 1)
      ).interval
      # Base from an unfuzzed schedule with identical inputs
      base = sched.schedule(
        state: state(state: :review, stability: 30.0, difficulty: 5.0,
                     last_review: Time.utc(2026, 1, 1)),
        rating: 3, now: Time.utc(2026, 2, 1)
      ).interval
      base_days = base / 1.day
      assert interval >= (base_days * 0.9 - 2).days, "#{interval} below fuzz range"
      assert interval <= (base_days * 1.1 + 2).days, "#{interval} above fuzz range"
    end
  end

  test "learning card left overnight (>= 1 day) uses long-term update" do
    s = sched
    overnight = s.schedule(
      state: state(state: :learning, stability: 2.3065, difficulty: 2.118104,
                   remaining_steps: 1, last_review: Time.utc(2026, 1, 1, 10)),
      rating: 3, now: Time.utc(2026, 1, 2, 23)
    )
    # Elapsed > 1 day -> stability no longer 2.3065 (long-term path applied)
    assert_not_equal 2.3065, overnight.state.stability
    assert_equal :review, overnight.state.state
  end
end
