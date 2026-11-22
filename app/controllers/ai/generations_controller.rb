module Ai
  class GenerationsController < ApplicationController
    before_action :require_login
    before_action :require_ai_config

    helper_method :status_tone

    def new
      setting = Ai::Setting.current
      @models = fetch_models
      @generation = current_user.ai_generations.new(
        mode: params[:deck_id] ? :add_cards : :create_deck,
        card_limit: DEFAULT_CARD_LIMIT
      )
      if params[:deck_id]
        @generation.deck = current_user.decks.find(params[:deck_id])
      end
      # Preselect the model used on the last creation (remembered globally
      # on the settings row); fall back to the first model when there is no
      # memory or it is no longer in the fetched list.
      @selected_model =
        if @models.any?
          setting.last_model.presence_in(@models) || @models.first
        else
          setting.last_model
        end
      render :new_cards if @generation.add_cards?
    end

    def create
      @generation = current_user.ai_generations.new(generation_params)
      if @generation.save
        # Global "what was selected last time" memory for the form.
        Ai::Setting.current.update!(last_model: @generation.model)
        Ai::GenerationJob.perform_later(@generation.id)
        redirect_to ai_generation_path(@generation), notice: "AI generation started."
      else
        redirect_to new_path_for, alert: @generation.errors.full_messages.to_sentence
      end
    end

    def show
      @generation = current_user.ai_generations.find(params[:id])
    end

    private

    # The forms ask for a card count; the agent stops at it no matter what.
    DEFAULT_CARD_LIMIT = 20

    # One param bag for both modes: a deck_id posts the "add cards to that
    # deck" form (owner-only via current_user.decks), otherwise a new deck
    # is built from scratch.
    def generation_params
      {
        mode: params[:deck_id].present? ? :add_cards : :create_deck,
        deck: params[:deck_id].present? ? current_user.decks.find(params[:deck_id]) : nil,
        model: params[:model].to_s.strip,
        prompt: params[:prompt].to_s.strip,
        card_limit: params[:card_limit].present? ? params[:card_limit].to_i : DEFAULT_CARD_LIMIT,
        insert_mode: params[:insert_mode] == "up_next" ? :up_next : :append
      }
    end

    def new_path_for
      if params[:deck_id]
        new_deck_ai_cards_path(params[:deck_id])
      else
        new_ai_generation_path
      end
    end

    # Color for the status dot on the generation page: orange while work is
    # in flight, green when done, red when failed.
    def status_tone
      return "done" if @generation.done?
      return "failed" if @generation.failed?

      "running"
    end

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
