# Anki does not enforce GUID uniqueness in a collection: converting notes
# with "Change Note Type" keeps their GUIDs, so a collection can legitimately
# hold distinct notes (EN->FR and FR->EN of the same word) sharing a GUID.
# Our per-deck unique index therefore rejected valid Anki data — and Rails
# 8.1's insert_all silently skips such rows (ON CONFLICT DO NOTHING), which
# surfaced as cards "referencing unknown notes". Keep the index for lookups,
# but drop the uniqueness.
class RemoveGuidUniquenessOnNotes < ActiveRecord::Migration[8.1]
  def change
    remove_index :notes, name: "index_notes_on_deck_id_and_guid"
    add_index :notes, [ :deck_id, :guid ]
  end
end
