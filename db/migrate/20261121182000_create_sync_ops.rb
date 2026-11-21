# The idempotency ledger for offline sync: every operation a client submits
# carries a client-generated unique op_id; applying it records the ledger
# row in the same transaction, so replays (retries, double-syncs) are
# detected and skipped instead of double-applying.
class CreateSyncOps < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_ops do |t|
      t.string :op_id, null: false
      t.integer :user_id, null: false
      t.string :kind, null: false
      t.json :payload, null: false
      t.datetime :applied_at, null: false
      t.timestamps
    end
    add_index :sync_ops, :op_id, unique: true
    add_index :sync_ops, [ :user_id, :applied_at ]
    add_foreign_key :sync_ops, :users
  end
end
