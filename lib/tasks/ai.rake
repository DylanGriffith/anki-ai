namespace :ai do
  desc "Configure the OpenAI-compatible API, e.g. rake ai:config[https://api.openai.com/v1,sk-...]"
  task :config, [ :base_url, :api_key ] => :environment do |_t, args|
    abort "usage: rake ai:config[base_url,api_key]" if args[:base_url].blank? || args[:api_key].blank?

    setting = Ai::Setting.current
    setting.assign_attributes(base_url: args[:base_url], api_key: args[:api_key])
    if setting.save
      puts "AI API configured (#{setting.base_url})."
    else
      abort setting.errors.full_messages.to_sentence
    end
  end

  # Optional: enables the agent's generate_image tool. The key is encrypted
  # at rest like the chat key. Runs after ai:config (the settings row also
  # holds the chat configuration).
  desc "Configure the image-generation API, e.g. rake ai:image_config[https://api.openai.com/v1,sk-...,gpt-image-1]"
  task :image_config, [ :base_url, :api_key, :model ] => :environment do |_t, args|
    abort "usage: rake ai:image_config[base_url,api_key,model]" if args[:base_url].blank? || args[:api_key].blank?

    setting = Ai::Setting.current
    setting.assign_attributes(image_base_url: args[:base_url], image_api_key: args[:api_key],
                              image_model: args[:model].presence || Ai::ImagesClient::DEFAULT_MODEL)
    if setting.save
      puts "Image API configured (#{setting.image_base_url}, model #{setting.image_model}, " \
           "quality: low)."
    else
      abort setting.errors.full_messages.to_sentence + " — run rake ai:config first if " \
              "the chat API is not set up yet"
    end
  end

  desc "Fetch and cache the model list (also refreshes what the New AI Deck form shows)"
  task models: :environment do
    setting = Ai::Setting.current
    abort "not configured — run rake ai:config[base_url,api_key] first" unless setting.configured?

    models = Ai::Client.new(base_url: setting.base_url, api_key: setting.api_key).models
    setting.update!(models: models, models_fetched_at: Time.current)
    puts models.join("\n")
  end
end
