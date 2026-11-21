class SyncOp < ApplicationRecord
  belongs_to :user

  validates :op_id, presence: true, uniqueness: true
  validates :kind, presence: true
end
