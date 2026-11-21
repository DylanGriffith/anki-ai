class User < ApplicationRecord
  has_secure_password

  has_many :decks, dependent: :destroy
  has_many :card_states
  has_many :review_logs
  has_many :ai_generations, class_name: "Ai::Generation", dependent: :destroy

  validates :name, presence: true, uniqueness: { case_sensitive: false },
                   format: { with: /\A[a-zA-Z0-9_.-]+\z/, message: "letters, digits, ., -, _ only" }
  validates :password, length: { minimum: 8 }, allow_nil: true

  normalizes :name, with: ->(name) { name.strip }

  def self.authenticate(name, password)
    find_by(name: name)&.authenticate(password) || false
  end
end
