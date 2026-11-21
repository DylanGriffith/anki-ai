class CardState < ApplicationRecord
  belongs_to :user
  belongs_to :card

  # Prefixed because the "new" value would clash with ActiveRecord's .new.
  enum :state, { new: 0, learning: 1, review: 2, relearning: 3 }, prefix: :state
end
