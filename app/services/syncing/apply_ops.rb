module Syncing
  # Applies a batch of client-submitted review ops idempotently.
  #
  # Every op carries a client-generated unique op_id. Applying an op records a
  # sync_ops ledger row in the same transaction as its effects, and the unique
  # index on op_id makes replays (dropped connections, double flushes,
  # retries) no-ops. Per-op failures are reported, not raised: one bad op
  # never blocks the rest of a batch, and the client drops anything the
  # server has definitively handled (applied / duplicate / invalid).
  class ApplyOps
    MAX_OPS_PER_BATCH = 1000

    class InvalidOp < StandardError; end

    Status = Struct.new(:op_id, :status, :error, keyword_init: true)

    def self.call(user:, ops:)
      new(user: user, ops: ops).call
    end

    def initialize(user:, ops:)
      @user = user
      @ops = ops
    end

    def call
      ops = Array(@ops)
      results = ops.first(MAX_OPS_PER_BATCH).map { |op| apply_one(op) }
      results + overflow_statuses(ops)
    end

    private

    def apply_one(op)
      return Status.new(op_id: nil, status: "invalid", error: "malformed op") unless op.is_a?(Hash)
      op_id = op["op_id"].to_s
      return Status.new(op_id: nil, status: "invalid", error: "missing op_id") if op_id.blank? || op_id.length > 100

      return Status.new(op_id: op_id, status: "duplicate") if SyncOp.exists?(op_id: op_id)

      return Status.new(op_id: op_id, status: "invalid", error: "unknown op kind") unless op["kind"] == "review"

      apply_review(op_id, op["payload"])
    rescue ActiveRecord::RecordNotUnique
      # A concurrent request applied the same op_id first.
      Status.new(op_id: op_id, status: "duplicate")
    rescue InvalidOp => e
      Status.new(op_id: op_id, status: "invalid", error: e.message)
    end

    def apply_review(op_id, payload)
      raise InvalidOp.new("missing payload") unless payload.is_a?(Hash)

      rating = payload["rating"].to_i
      raise InvalidOp.new("rating must be 1..4") unless (1..4).cover?(rating)

      reviewed_at = parse_time(payload["reviewed_at"])
      duration_ms = payload["duration_ms"].is_a?(Integer) ? payload["duration_ms"].clamp(0, 3_600_000) : 0

      card = Card.joins(:deck).merge(Deck.visible_to(@user)).find_by(id: payload["card_id"])
      raise InvalidOp.new("unknown card") unless card

      ActiveRecord::Base.transaction do
        SyncOp.create!(op_id: op_id, user: @user, kind: "review",
                       payload: payload.slice("card_id", "rating", "reviewed_at", "duration_ms"),
                       applied_at: Time.now.utc)
        Reviewing::Apply.call(user: @user, card: card, rating: rating,
                              reviewed_at: reviewed_at, duration_ms: duration_ms,
                              sync_op_id: op_id)
      end
      Status.new(op_id: op_id, status: "applied")
    end

    def parse_time(value)
      time = Time.iso8601(value.to_s).utc
      # Trust the client's clock only backwards; clamp future timestamps.
      time > Time.now.utc ? Time.now.utc : time
    rescue ArgumentError, TypeError
      raise InvalidOp.new("bad reviewed_at")
    end

    def overflow_statuses(ops)
      ops.drop(MAX_OPS_PER_BATCH).map do |op|
        Status.new(op_id: op.is_a?(Hash) ? op["op_id"].to_s : nil,
                   status: "invalid", error: "batch too large")
      end
    end
  end
end
