class CreateAnkiCore < ActiveRecord::Migration[8.1]
  def change
    create_table :note_types do |t|
      t.references :deck, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :kind, null: false, default: 0 # 0 standard, 1 cloze
      t.json :field_names, null: false
      t.json :templates, null: false # [{ "name", "front", "back" }] ordered by ord
      t.json :card_requirements, null: false # Anki "req": [[ord, "any"|"all", [fields]]]
      t.text :css
      t.timestamps
    end
    add_index :note_types, [ :deck_id, :name ], unique: true

    create_table :notes do |t|
      t.references :deck, null: false, foreign_key: true
      t.references :note_type, null: false, foreign_key: true
      t.json :fields, null: false
      t.string :tags, null: false, default: ""
      t.string :guid, null: false
      t.bigint :anki_note_id
      t.timestamps
    end
    add_index :notes, [ :deck_id, :guid ], unique: true
    add_index :notes, :anki_note_id

    create_table :cards do |t|
      t.references :note, null: false, foreign_key: true
      t.references :deck, null: false, foreign_key: true
      t.integer :template_ord, null: false, default: 0
      t.integer :position, null: false, default: 0 # new-card order within the deck
      t.boolean :suspended, null: false, default: false
      t.string :anki_subdeck, null: false, default: "" # originating Anki subdeck path
      t.bigint :anki_card_id
      t.timestamps
    end
    add_index :cards, [ :deck_id, :position ]
    add_index :cards, [ :note_id, :template_ord ], unique: true
    add_index :cards, :anki_card_id

    # FSRS scheduling state, per user per card ("content global, progress per-user").
    create_table :card_states do |t|
      t.references :user, null: false, foreign_key: true
      t.references :card, null: false, foreign_key: true
      t.integer :state, null: false, default: 0 # 0 new, 1 learning, 2 review, 3 relearning
      t.float :stability   # days
      t.float :difficulty  # FSRS 1..10
      t.datetime :due
      t.datetime :last_reviewed_at
      t.integer :reps, null: false, default: 0
      t.integer :lapses, null: false, default: 0
      t.integer :remaining_steps, null: false, default: 0
      t.timestamps
    end
    add_index :card_states, [ :user_id, :card_id ], unique: true
    add_index :card_states, [ :user_id, :state, :due ]

    create_table :review_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :card, null: false, foreign_key: true
      t.integer :rating, null: false # 1 again, 2 hard, 3 good, 4 easy
      t.datetime :reviewed_at, null: false
      t.integer :duration_ms, null: false, default: 0
      t.string :sync_op_id # idempotency key for offline sync (unique when present)
      t.timestamps
    end
    add_index :review_logs, [ :user_id, :reviewed_at ]
    add_index :review_logs, [ :card_id, :reviewed_at ]
    add_index :review_logs, :sync_op_id, unique: true, where: "sync_op_id IS NOT NULL"

    create_table :media_files do |t|
      t.references :deck, null: false, foreign_key: true
      t.string :filename, null: false # identity used by [sound:...] and <img src=...>
      t.string :content_type, null: false
      t.integer :byte_size, null: false, default: 0
      t.timestamps
    end
    add_index :media_files, [ :deck_id, :filename ], unique: true
  end
end
