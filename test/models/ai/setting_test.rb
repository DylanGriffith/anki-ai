require "test_helper"

class Ai::SettingTest < ActiveSupport::TestCase
  test "api key round-trips and is not stored in plaintext" do
    setting = Ai::Setting.current
    setting.base_url = "https://api.openai.com/v1"
    setting.api_key = "sk-super-secret"
    setting.save!

    reloaded = Ai::Setting.current
    assert_equal "sk-super-secret", reloaded.api_key
    assert_not_includes reloaded.api_key_ciphertext, "sk-super-secret"
    raw = ActiveRecord::Base.connection.select_value("SELECT api_key_ciphertext FROM ai_settings LIMIT 1").to_s
    assert_not_includes raw, "sk-super-secret"
  end

  test "configured? needs both base url and key" do
    setting = Ai::Setting.new(base_url: "https://api.openai.com/v1")
    assert_not setting.configured?
    setting.api_key = "k"
    assert setting.configured?
  end

  test "current is the singleton row (created on first save)" do
    Ai::Setting.current.update!(base_url: "https://x.test/v1", api_key: "k")
    assert_equal Ai::Setting.first, Ai::Setting.current
    assert_equal 1, Ai::Setting.count
  end

  test "base_url must be an http(s) url" do
    setting = Ai::Setting.new(api_key: "k")
    setting.base_url = "not a url"
    assert_not setting.valid?
    setting.base_url = "https://api.openai.com/v1"
    assert setting.valid?
  end

  test "models serialize as JSON" do
    setting = Ai::Setting.current
    setting.models = %w[a b]
    setting.base_url = "https://x.test"
    setting.api_key = "k"
    setting.save!
    assert_equal %w[a b], Ai::Setting.current.models
  end
end
