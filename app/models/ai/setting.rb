module Ai
  # Singleton row holding the OpenAI-compatible API configuration. Set via
  # `rake ai:config[base_url,api_key]`; the API key is encrypted at rest
  # (ActiveSupport::MessageEncryptor keyed from the app's secret_key_base, so
  # no extra credentials setup is needed).
  class Setting < ApplicationRecord
    self.table_name = "ai_settings"

    validates :base_url, presence: true, format: { with: %r{\Ahttps?://\S+\z} }
    validate :api_key_presence

    # The one settings row (created on first use).
    def self.current
      first || new
    end

    def configured?
      base_url.present? && api_key_ciphertext.present?
    end

    # Encrypts on write, decrypts on read. Derived key changes only if
    # secret_key_base changes (documented in README).
    def api_key
      return nil if api_key_ciphertext.blank?

      encryptor.decrypt_and_verify(api_key_ciphertext)
    end

    def api_key=(key)
      self.api_key_ciphertext = key.present? ? encryptor.encrypt_and_sign(key.to_s) : nil
    end

    def models
      JSON.parse(models_json || "[]")
    end

    def models=(list)
      self.models_json = JSON.generate(Array(list))
    end

    private

    def api_key_presence
      errors.add(:api_key, "can't be blank") if api_key_ciphertext.blank?
    end

    def encryptor
      @encryptor ||= begin
        secret = Rails.application.secret_key_base
        key = ActiveSupport::KeyGenerator.new(secret).generate_key("ai-settings", 32)
        ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
      end
    end
  end
end
