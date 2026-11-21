class CreateAiTables < ActiveRecord::Migration[8.1]
  def change
    # Singleton configuration for the OpenAI-compatible API (set via
    # `rake ai:config[base_url,api_key]`). The API key is encrypted at rest
    # with a key derived from the app's secret_key_base.
    create_table :ai_settings do |t|
      t.string :base_url, null: false
      t.text :api_key_ciphertext
      t.text :models_json
      t.datetime :models_fetched_at
      t.timestamps
    end

    # One row per "New AI Deck" request: the prompt, the model, the running
    # transcript of the agent loop (JSON journal the status page polls), and
    # the finished deck once the agent calls `finish`.
    create_table :ai_generations do |t|
      t.references :user, null: false, foreign_key: true
      t.references :deck, foreign_key: true
      t.integer :status, null: false, default: 0
      t.string :model, null: false
      t.text :prompt, null: false
      t.text :transcript, null: false, default: "[]"
      t.text :error
      t.integer :turn_count, null: false, default: 0
      t.datetime :finished_at
      t.timestamps
    end

    add_index :ai_generations, :status
  end
end
