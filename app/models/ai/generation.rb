module Ai
  # One "New AI Deck" request. The generation job walks the agent loop and
  # appends to `transcript` (a JSON journal) after every step, so the status
  # page is a simple poll-and-render.
  class Generation < ApplicationRecord
    self.table_name = "ai_generations"

    # Transcript caps: a short tail of the live stream, a longer tail for
    # finished entries — the journal must stay small no matter what the
    # model does.
    STREAM_TAIL = 400
    ENTRY_TAIL = 2_000

    belongs_to :user
    belongs_to :deck, optional: true

    enum :status, { pending: 0, running: 1, done: 2, failed: 3 }

    validates :model, presence: true
    validates :prompt, presence: true

    scope :recent_first, -> { order(created_at: :desc, id: :desc) }

    # Append one journal entry and save. Entries are small hashes:
    #   { "type" => "assistant"|"tool"|"status", ... }
    def log!(entry)
      self.transcript = JSON.generate(journal << entry.as_json)
      save!
    end

    # While the model streams, replace the in-progress assistant entry in
    # place (no entry spam) at most once per second. Only a short TAIL of
    # the streamed text/thinking is journaled — the status page needs a
    # live glimpse, not the full buffer (a looping model would otherwise
    # grow the row — and every poll's render — without bound). `chars`
    # carries the true streamed size for the UI counter.
    def log_stream!(text:, thinking: nil, tool_calls: [], chars: nil)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_stream_at && (now - @last_stream_at) < 1.0

      @last_stream_at = now
      entries = journal
      entries.pop if entries.last&.dig("streaming")
      entries << { "type" => "assistant", "text" => tail(text, STREAM_TAIL),
                   "thinking" => tail(thinking, STREAM_TAIL), "chars" => chars,
                   "tool_calls" => tool_calls, "streaming" => true }
      update!(transcript: JSON.generate(entries))
    end

    # The final assistant entry replaces any streaming placeholder. Text is
    # capped the same way — pathological monologues must not bloat the
    # transcript (the full text never goes to the UI anyway).
    def log_assistant!(entry)
      entry = entry.dup
      entry[:text] = tail(entry[:text], ENTRY_TAIL)
      entry[:thinking] = tail(entry[:thinking], ENTRY_TAIL)
      entries = journal
      entries.pop if entries.last&.dig("streaming")
      self.transcript = JSON.generate(entries << entry.as_json)
      save!
    end

    def journal
      JSON.parse(transcript || "[]")
    end

    def finished?
      done? || failed?
    end

    # Drop the in-progress streaming placeholder — used when a turn aborts:
    # a failed generation should not keep claiming to think.
    def clear_stream!
      entries = journal
      return unless entries.last&.dig("streaming")

      entries.pop
      update!(transcript: JSON.generate(entries))
    end

    private

    # Last `max` characters, marked with a leading ellipsis when cut.
    def tail(text, max)
      return if text.nil?

      text = text.to_s
      text.length <= max ? text : "…" + text.last(max)
    end
  end
end
