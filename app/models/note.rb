class Note < ApplicationRecord
  belongs_to :deck
  belongs_to :note_type
  has_many :cards, dependent: :destroy

  validates :guid, presence: true

  # Fields is a JSON array in Anki's field order. Access by name:
  def field(name)
    index = note_type.field_names.index(name)
    index && fields[index].to_s
  end

  def tags_list
    tags.to_s.split(/\s+/).reject(&:blank?)
  end
end
