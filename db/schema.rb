# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_21_162000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "card_states", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "card_id", null: false
    t.integer "state", default: 0, null: false
    t.float "stability"
    t.float "difficulty"
    t.datetime "due"
    t.datetime "last_reviewed_at"
    t.integer "reps", default: 0, null: false
    t.integer "lapses", default: 0, null: false
    t.integer "remaining_steps", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["card_id"], name: "index_card_states_on_card_id"
    t.index ["user_id", "card_id"], name: "index_card_states_on_user_id_and_card_id", unique: true
    t.index ["user_id", "state", "due"], name: "index_card_states_on_user_id_and_state_and_due"
    t.index ["user_id"], name: "index_card_states_on_user_id"
  end

  create_table "cards", force: :cascade do |t|
    t.integer "note_id", null: false
    t.integer "deck_id", null: false
    t.integer "template_ord", default: 0, null: false
    t.integer "position", default: 0, null: false
    t.boolean "suspended", default: false, null: false
    t.string "anki_subdeck", default: "", null: false
    t.bigint "anki_card_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["anki_card_id"], name: "index_cards_on_anki_card_id"
    t.index ["deck_id", "position"], name: "index_cards_on_deck_id_and_position"
    t.index ["deck_id"], name: "index_cards_on_deck_id"
    t.index ["note_id", "template_ord"], name: "index_cards_on_note_id_and_template_ord", unique: true
    t.index ["note_id"], name: "index_cards_on_note_id"
  end

  create_table "decks", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "name", null: false
    t.text "description"
    t.integer "visibility", default: 0, null: false
    t.integer "new_per_day", default: 20, null: false
    t.integer "reviews_per_day", default: 200, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "name"], name: "index_decks_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_decks_on_user_id"
    t.index ["visibility"], name: "index_decks_on_visibility"
  end

  create_table "media_files", force: :cascade do |t|
    t.integer "deck_id", null: false
    t.string "filename", null: false
    t.string "content_type", null: false
    t.integer "byte_size", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["deck_id", "filename"], name: "index_media_files_on_deck_id_and_filename", unique: true
    t.index ["deck_id"], name: "index_media_files_on_deck_id"
  end

  create_table "note_types", force: :cascade do |t|
    t.integer "deck_id", null: false
    t.string "name", null: false
    t.integer "kind", default: 0, null: false
    t.json "field_names", null: false
    t.json "templates", null: false
    t.json "card_requirements", null: false
    t.text "css"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["deck_id", "name"], name: "index_note_types_on_deck_id_and_name", unique: true
    t.index ["deck_id"], name: "index_note_types_on_deck_id"
  end

  create_table "notes", force: :cascade do |t|
    t.integer "deck_id", null: false
    t.integer "note_type_id", null: false
    t.json "fields", null: false
    t.string "tags", default: "", null: false
    t.string "guid", null: false
    t.bigint "anki_note_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["anki_note_id"], name: "index_notes_on_anki_note_id"
    t.index ["deck_id", "guid"], name: "index_notes_on_deck_id_and_guid"
    t.index ["deck_id"], name: "index_notes_on_deck_id"
    t.index ["note_type_id"], name: "index_notes_on_note_type_id"
  end

  create_table "review_logs", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "card_id", null: false
    t.integer "rating", null: false
    t.datetime "reviewed_at", null: false
    t.integer "duration_ms", default: 0, null: false
    t.string "sync_op_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["card_id", "reviewed_at"], name: "index_review_logs_on_card_id_and_reviewed_at"
    t.index ["card_id"], name: "index_review_logs_on_card_id"
    t.index ["sync_op_id"], name: "index_review_logs_on_sync_op_id", unique: true, where: "sync_op_id IS NOT NULL"
    t.index ["user_id", "reviewed_at"], name: "index_review_logs_on_user_id_and_reviewed_at"
    t.index ["user_id"], name: "index_review_logs_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "name", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_users_on_name", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "card_states", "cards"
  add_foreign_key "card_states", "users"
  add_foreign_key "cards", "decks"
  add_foreign_key "cards", "notes"
  add_foreign_key "decks", "users"
  add_foreign_key "media_files", "decks"
  add_foreign_key "note_types", "decks"
  add_foreign_key "notes", "decks"
  add_foreign_key "notes", "note_types"
  add_foreign_key "review_logs", "cards"
  add_foreign_key "review_logs", "users"
end
