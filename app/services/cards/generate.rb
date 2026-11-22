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
      if note_type.occlusion?
        occlusion_ords(note).then { |ords| ords.empty? ? [ 0 ] : ords }
      elsif note_type.cloze?
        numbers = note.fields.join.scan(/\{\{c(\d+)::/).map { |m| m[0].to_i }.uniq.sort
        numbers.take(note_type.templates.size)
      else
        templates_satisfied(note)
      end
    end

    # One card per derived mask: the front covers mask N, the answer reveals
    # it. Notes whose image has no masks fall back to a single plain card.
    def self.occlusion_ords(note)
      image = note.field("Image").to_s
      filename = image[/src=["']([^"']+)["']/, 1]
      media = filename && note.deck.media_files.find_by(filename: filename.strip)
      count = Array(media&.masks).length
      (0...count).to_a
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
