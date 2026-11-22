module Ai
  # One "New AI Deck" request. The generation job walks the agent loop and
  # appends to `transcript` (a JSON journal) after every step, so the status
  # page is a simple poll-and-render.
  class Generation < ApplicationRecord
    self.table_name = "ai_generations"

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
    # place (no entry spam) at most once per second.
    def log_stream!(text:, tool_calls: [])
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_stream_at && (now - @last_stream_at) < 1.0

      @last_stream_at = now
      entries = journal
      entries.pop if entries.last&.dig("streaming")
      entries << { "type" => "assistant", "text" => text, "tool_calls" => tool_calls,
                   "streaming" => true }
      update!(transcript: JSON.generate(entries))
    end

    # The final assistant entry replaces any streaming placeholder.
    def log_assistant!(entry)
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
  end
end
