class DecksController < ApplicationController
  before_action :require_login
  before_action :set_deck, only: [ :show, :destroy, :export ]

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

  # Streams the deck as a schema-11 .apkg (Anki-importable, includes the
  # current user's progress). The archive is built into a tempfile which the
  # streaming body deletes once it has been sent.
  def export
    path = Decks::Export.call(user: current_user, deck: @deck)
    response.headers["Content-Disposition"] =
      %(attachment; filename="#{@deck.name.gsub(/["\\\/]/, "")}.apkg")
    response.headers["Content-Type"] = "application/octet-stream"
    response.headers["Content-Length"] = File.size(path).to_s
    self.response_body = ExportBody.new(path)
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
  rescue Decks::Import::DuplicateNameError => e
    flash.now[:alert] = "Import failed: #{e.message}"
    render :import_form, status: :unprocessable_entity
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

  # Streams the generated .apkg in chunks and deletes the tempfile once the
  # response has been fully sent (Rack calls #close on the body).
  class ExportBody
    CHUNK = 64.kilobytes

    def initialize(path)
      @path = path
    end

    def each
      File.open(@path, "rb") do |file|
        while (chunk = file.read(CHUNK))
          yield chunk
        end
      end
    ensure
      File.delete(@path) if File.exist?(@path)
    end
  end
end
