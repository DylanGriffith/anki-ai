class AddImageConfigToAiSettings < ActiveRecord::Migration[8.1]
  def change
    # OpenAI-compatible image-generation API for the agent's generate_image
    # tool — configured separately from the chat API via
    # `rake ai:image_config[base_url,api_key,model]` (key encrypted at rest
    # like the chat key; base/model plain because they are not secrets).
    add_column :ai_settings, :image_base_url, :string
    add_column :ai_settings, :image_api_key_ciphertext, :text
    add_column :ai_settings, :image_model, :string
  end
end
