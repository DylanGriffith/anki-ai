class AddModeToAiGenerations < ActiveRecord::Migration[8.1]
  def change
    # Generations now do two jobs: 0 = build a new deck (create_deck), 1 = add
    # cards to an existing deck (deck_id set up front).
    add_column :ai_generations, :mode, :integer, null: false, default: 0
    # Hard stop for the agent: no more than card_limit cards are generated.
    add_column :ai_generations, :card_limit, :integer
    # add_cards mode: 0 = append the new cards at the back of the new-card
    # queue, 1 = queue them up next (they become the next new cards).
    add_column :ai_generations, :insert_mode, :integer, null: false, default: 0
  end
end
