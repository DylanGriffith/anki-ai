class NoteType < ApplicationRecord
  belongs_to :deck
  has_many :notes, dependent: :destroy

  enum :kind, { standard: 0, cloze: 1, occlusion: 2 }

  before_validation do
    self.card_requirements ||= []
    self.templates ||= []
  end

  validates :name, presence: true, uniqueness: { scope: :deck_id }
  validates :field_names, presence: true
  validates :templates, presence: true

  def template(ord)
    templates.fetch(ord) { templates.first }
  end
end
