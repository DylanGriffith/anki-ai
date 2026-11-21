class DecksController < ApplicationController
  before_action :require_login
  before_action :set_deck, only: [ :show, :destroy ]

  def index
    @decks = current_user.decks.order(:name)
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

  private

  def set_deck
    @deck = current_user.decks.find(params[:id])
  end

  def deck_params
    params.require(:deck).permit(:name, :description, :visibility, :new_per_day, :reviews_per_day)
  end
end
