require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "authenticates with correct password" do
    user = User.create!(name: "alice", password: "password123")
    assert_equal user, User.authenticate("alice", "password123")
  end

  test "rejects wrong password and unknown user" do
    User.create!(name: "alice", password: "password123")
    assert_not User.authenticate("alice", "wrong")
    assert_not User.authenticate("bob", "password123")
  end

  test "name is unique case-insensitively and normalized" do
    User.create!(name: "alice", password: "password123")
    user = User.new(name: "  Alice ", password: "password123")
    assert_not user.valid?
    assert_includes user.errors[:name], "has already been taken"
  end

  test "requires 8+ character password" do
    user = User.new(name: "carol", password: "short")
    assert_not user.valid?
  end
end
