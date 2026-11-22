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
      agent_class(generation).new(generation).call
    end

    private

    # Both modes share the agent loop (Ai::Agent::Base); only the deck setup
    # and the create_deck tool differ.
    def agent_class(generation)
      generation.add_cards? ? Agent::CardAdder : Agent::DeckBuilder
    end
  end
end
