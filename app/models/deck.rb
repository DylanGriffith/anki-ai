class Deck < ApplicationRecord
  belongs_to :user
  has_many :note_types, dependent: :destroy
  has_many :notes, dependent: :destroy
  has_many :cards, dependent: :destroy
  has_many :media_files, dependent: :destroy
  # The AI generation that built this deck (nil for imported decks); it goes
  # with the deck — otherwise the deck_id foreign key blocks deck.destroy!.
  has_many :ai_generations, class_name: "Ai::Generation", dependent: :destroy

  enum :visibility, { private: 0, public: 1 }, prefix: :is

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :new_per_day, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 9999 }
  validates :reviews_per_day, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 9999 }

  scope :visible_to, ->(user) {
    where(visibility: :public).or(where(user: user))
  }

  def editable_by?(user)
    user_id == user.id
  end
end
