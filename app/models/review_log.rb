class ReviewLog < ApplicationRecord
  belongs_to :user
  belongs_to :card

  enum :rating, { again: 1, hard: 2, good: 3, easy: 4 }, prefix: :rated

  validates :rating, inclusion: 1..4
end
