class DecksController < ApplicationController
  before_action :require_login
  before_action :set_deck, only: [ :show, :destroy, :export, :edit, :update ]
  before_action :require_owner, only: [ :destroy, :edit, :update ]

  def index
    @decks = current_user.decks.order(:name)
    @ai_configured = Ai::Setting.current.configured?
    @due_counts, @new_counts = deck_counts(@decks)
  end

  # Everyone's public decks (excluding your own — those are on the main list),
  # with your own progress counts on them.
  def browse
    @ai_configured = Ai::Setting.current.configured?
    @decks = Deck.where(visibility: :public).where.not(user: current_user)
                 .order(:name).includes(:user)
    @due_counts, @new_counts = deck_counts(@decks)
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

  def edit
  end

  def update
    if @deck.update(deck_params)
      redirect_to @deck, notice: "Deck updated."
    else
      render :edit, status: :unprocessable_entity
    end
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

  # Public decks are readable (and studyable/exportable with YOUR progress)
  # by anyone; only the owner can destroy or modify them.
  def set_deck
    @deck = Deck.visible_to(current_user).find(params[:id])
  end

  def require_owner
    head :forbidden unless @deck.editable_by?(current_user)
  end

  # due-now and new-left counts per deck for the CURRENT user (works for
  # owned and public-studied decks alike — progress is always per-user).
  def deck_counts(decks)
    due_counts = CardState.joins(:card)
                          .where(user: current_user, state: [ :learning, :relearning, :review ])
                          .where("card_states.due <= ?", Time.now.utc)
                          .group("cards.deck_id").count
    introduced = CardState.where(user: current_user).where.not(state: :new).select(:card_id)
    new_counts = Card.where(deck: decks, suspended: false)
                     .where.not(id: introduced).group(:deck_id).count
    [ due_counts, new_counts ]
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
