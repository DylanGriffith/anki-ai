class CreateDecks < ActiveRecord::Migration[8.1]
  def change
    create_table :decks do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.integer :visibility, null: false, default: 0
      t.integer :new_per_day, null: false, default: 20
      t.integer :reviews_per_day, null: false, default: 200
      t.timestamps
    end
    add_index :decks, :visibility
    add_index :decks, [ :user_id, :name ], unique: true
  end
end
