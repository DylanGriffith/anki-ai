class Deck < ApplicationRecord
  belongs_to :user

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
