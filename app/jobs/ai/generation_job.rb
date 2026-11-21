module Ai
  # Runs the deck-builder agent loop for one generation. Safe to re-run:
  # a generation that already finished is left alone (Solid Queue retries
  # or operator replays can't double-build).
  class GenerationJob < ApplicationJob
    queue_as :default

    def perform(generation_id)
      generation = Generation.find(generation_id)
      return if generation.finished?

      generation.update!(status: :running)
      Agent::DeckBuilder.new(generation).call
    end
  end
end
