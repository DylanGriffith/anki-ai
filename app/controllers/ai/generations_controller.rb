module Ai
  class GenerationsController < ApplicationController
    before_action :require_login
    before_action :require_ai_config

    def new
      @models = fetch_models
      @generation = current_user.ai_generations.new
    end

    def create
      @generation = current_user.ai_generations.new(
        model: params[:model].to_s.strip, prompt: params[:prompt].to_s.strip
      )
      if @generation.save
        Ai::GenerationJob.perform_later(@generation.id)
        redirect_to ai_generation_path(@generation), notice: "AI deck generation started."
      else
        redirect_to new_ai_generation_path, alert: @generation.errors.full_messages.to_sentence
      end
    end

    def show
      @generation = current_user.ai_generations.find(params[:id])
    end

    private

    # The button only appears in the UI when configured; this guard keeps
    # direct URLs honest too.
    def require_ai_config
      return if Ai::Setting.current.configured?

      redirect_to decks_path, alert: "AI is not configured yet — run " \
                                     "rake ai:config[base_url,api_key] on the server."
    end

    # Model list for the dropdown, cached in the settings row. Live fetch if
    # stale; cached list as fallback when the API is unreachable — the form
    # always renders (free-text model field when the list is empty).
    def fetch_models
      setting = Ai::Setting.current
      fresh = setting.models_fetched_at && setting.models_fetched_at > 10.minutes.ago
      return setting.models if fresh

      models = Ai::Client.new(base_url: setting.base_url, api_key: setting.api_key).models
      setting.update!(models: models, models_fetched_at: Time.current)
      models
    rescue Ai::Error
      setting.models
    end
  end
end
