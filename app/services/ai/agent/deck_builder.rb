module Ai
  module Agent
    # "New AI Deck": builds a brand-new deck from a topic prompt. Everything
    # — the agent loop, the note/card tools, the card limit — comes from
    # Base; this subclass only adds the create_deck tool (the only way this
    # mode obtains a deck) and its workflow prompt.
    class DeckBuilder < Base
      def initial_deck
        nil
      end

      def offered_tools
        %w[create_deck] + super
      end

      def role_prompt
        "You are a flashcard deck builder for a spaced-repetition study app (Anki-style). " \
          "The user gives you a topic; you build a study deck with well-crafted cards."
      end

      def workflow_prompt
        "Workflow: create_deck once, upsert_note_type (usually one 'Basic' type with " \
          "Front/Back fields), then add_note for each card. Use list_notes to review your " \
          "work and update_note/delete_note to fix problems. Call finish when done."
      end

      private

      def require_deck_message
        "create the deck first (create_deck) before using this tool"
      end

      def create_deck(args)
        return [ { error: "deck already created for this generation" }, true ] if @deck

        @deck = Deck.create!(user: @user, name: args.fetch("name").to_s.strip,
                             description: args["description"].to_s.strip)
        @generation.update!(deck: @deck)
        @generation.log!(type: "status", text: "deck created", deck: @deck.name)
        [ { deck_id: @deck.id, name: @deck.name }, false ]
      end
    end
  end
end
