module Ai
  module Agent
    # "Add AI cards to an existing deck": same toolbox as the builder minus
    # create_deck — the deck (generation.deck) already exists and may hold
    # cards and note types the agent stays consistent with. The generation's
    # insert mode decides where the new cards land in the new-card queue
    # (Base#note_position).
    class CardAdder < Base
      def initial_deck
        @generation.deck or raise Error, "generation has no deck to add cards to"
      end

      def role_prompt
        "You are a flashcard card writer for a spaced-repetition study app (Anki-style). " \
          "The user already has the deck \"#{deck.name}\" and wants additional cards for it."
      end

      def workflow_prompt
        "Workflow: list_notes to see the deck's existing note types and cards, then " \
          "add_note for each new card (upsert_note_type if the deck needs another note " \
          "type). Use update_note/delete_note to fix problems. Call finish when done. " \
          "Keep new cards consistent with the deck's existing style and do not duplicate " \
          "cards it already has."
      end
    end
  end
end
