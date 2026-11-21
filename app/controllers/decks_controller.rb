class DecksController < ApplicationController
  before_action :require_login
  before_action :set_deck, only: [ :show, :destroy ]

  def index
    @decks = current_user.decks.order(:name)
    @due_counts = CardState.joins(:card)
                           .where(user: current_user, state: [ :learning, :relearning, :review ])
                           .where("card_states.due <= ?", Time.now.utc)
                           .group("cards.deck_id").count
    introduced = CardState.where(user: current_user).where.not(state: :new).select(:card_id)
    @new_counts = Card.where(deck: @decks, suspended: false)
                       .where.not(id: introduced).group(:deck_id).count
  end

  def new
    @deck = current_user.decks.new
  end

  def create
    @deck = current_user.decks.new(deck_params)
    if @deck.save
      redirect_to @deck, notice: "Deck created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def destroy
    @deck.destroy!
    redirect_to decks_path, notice: "Deck deleted."
  end

  def import_form
  end

  def import
    upload = params[:file]
    if upload.blank? || !upload.respond_to?(:tempfile)
      flash.now[:alert] = "Choose a .apkg file to import."
      return render :import_form, status: :unprocessable_entity
    end

    deck = Decks::Import.call(current_user, upload.tempfile.path, name: params[:name].presence)
    redirect_to deck, notice: "Imported “#{deck.name}”: #{deck.cards.count} cards, " \
                              "#{deck.media_files.count} media files."
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = "Import failed: you already have a deck named " \
                        "“#{e.record.name}”. Import again with a different name."
    render :import_form, status: :unprocessable_entity
  rescue Anki::Apkg::Error => e
    flash.now[:alert] = "Import failed: #{e.message}"
    render :import_form, status: :unprocessable_entity
  end

  private

  def set_deck
    @deck = current_user.decks.find(params[:id])
  end

  def deck_params
    params.require(:deck).permit(:name, :description, :visibility, :new_per_day, :reviews_per_day)
  end
end
