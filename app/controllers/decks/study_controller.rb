class Decks::StudyController < ApplicationController
  before_action :require_login
  before_action :set_deck

  # The study page renders the queue once; the client-side session
  # (app/javascript/study_session.js) runs the whole session from the
  # serialized data — reveal, rating, keyboard shortcuts — syncing each
  # review to POST /sync immediately, or through the offline outbox when
  # the network is unavailable. One code path for online and offline.
  def show
    queue = Reviewing::QueueBuilder.call(user: current_user, deck: @deck)
    @cards = queue[:cards]
    @counts = queue[:counts]
    return unless @cards.any?

    @session = Reviewing::SessionSerializer.call(user: current_user, deck: @deck, cards: @cards)
  end

  private

  def set_deck
    @deck = Deck.visible_to(current_user).find(params[:deck_id] || params[:id])
  end
end
