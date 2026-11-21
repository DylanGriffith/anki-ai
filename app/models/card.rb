class Card < ApplicationRecord
  belongs_to :note, inverse_of: :cards
  belongs_to :deck
  has_many :card_states, dependent: :destroy
  has_many :review_logs, dependent: :destroy

  validates :template_ord, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def state_for(user)
    card_states.find_by(user: user)
  end

  # Front/back template of this card's note type for this ord.
  def template
    note.note_type.template(template_ord)
  end
end
