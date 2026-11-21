module Cards
  # Generates the cards for a note, mirroring Anki's rules:
  # - standard note type: one card per template whose card_requirements
  #   ("req") are satisfied ("any"/"all" of the listed fields non-empty);
  #   with no req info, every template gets a card.
  # - cloze note type: one card per distinct {{cN::...}} number found in the
  #   fields (capped by available templates, like Anki).
  class Generate
    MAX_CLOZE_CARDS = 4

    def self.call(note, position:)
      note.transaction do
        ords = card_ords(note)
        ords.map do |ord|
          Card.create!(note: note, deck: note.deck, template_ord: ord, position: position)
        end
      end
    end

    def self.card_ords(note)
      note_type = note.note_type
      if note_type.cloze?
        numbers = note.fields.join.scan(/\{\{c(\d+)::/).map { |m| m[0].to_i }.uniq.sort
        numbers.take(note_type.templates.size)
      else
        templates_satisfied(note)
      end
    end

    def self.templates_satisfied(note)
      note_type = note.note_type
      return (0...note_type.templates.size).to_a if note_type.card_requirements.blank?

      values = note_type.field_names.zip(note.fields).to_h
      note_type.card_requirements.filter_map do |(ord, kind, fields)|
        present = fields.map { |f| values[f].to_s.strip.present? }
        satisfied = case kind
                    when "all" then present.all?
                    when "none" then true
                    else present.any?
                    end
        ord if satisfied
      end
    end
  end
end
