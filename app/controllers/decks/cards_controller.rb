class Decks::CardsController < ApplicationController
  before_action :require_login
  before_action :set_deck
  before_action :require_owner, only: [ :new, :create ]

  before_action :set_note_types, only: [ :new, :create ]
  before_action :set_note_type, only: [ :new, :create ]

  PAGE_SIZE = 100

  def index
    @cards = @deck.cards.includes(note: :note_type).order(:position, :id)
                   .offset(params[:offset].to_i).limit(PAGE_SIZE + 1)
    @more = @cards.size > PAGE_SIZE
    @cards = @cards.first(PAGE_SIZE)
    @offset = params[:offset].to_i
  end

  def new
    @note = @deck.notes.new(note_type: @note_type)
    @note.fields = Array.new(@note_type.field_names.size, "")
  end

  def create
    @note = @deck.notes.new(
      note_type: @note_type,
      fields: fields_values,
      tags: params[:tags].to_s.strip,
      guid: SecureRandom.uuid
    )
    if @note.save
      Cards::Generate.call(@note, position: next_position(params[:add_to_next] == "1"))
      redirect_to cards_deck_path(@deck), notice: "Card added."
    else
      @note.fields = fields_values
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_deck
    # Public decks are browsable read-only; the write actions are guarded
    # separately by require_owner.
    @deck = Deck.visible_to(current_user).find(params[:id])
  end

  def require_owner
    head :forbidden unless @deck.editable_by?(current_user)
  end

  def set_note_types
    @note_types = @deck.note_types.order(:name)
  end

  def set_note_type
    requested = params[:note_type_id]
    @note_type = requested.present? ? @note_types.find_by(id: requested) : @note_types.first
    if @note_type.nil?
      @note_type = NoteType.create!(
        deck: @deck, name: "Basic", kind: :standard,
        field_names: %w[Front Back],
        templates: [ { "name" => "Card 1", "front" => "{{Front}}",
                       "back" => "{{FrontSide}}<hr id=answer>{{Back}}" } ],
        card_requirements: []
      )
      @note_types = [ @note_type ]
    end
  end

  def fields_values
    raw = params[:fields].to_unsafe_h
    @note_type.field_names.map { |name| raw[name].to_s }
  end

  # "Add to next" jumps the new-card queue (position below the current
  # minimum); otherwise append at the end.
  def next_position(add_to_next)
    if add_to_next
      (@deck.cards.minimum(:position) || 1) - 1
    else
      (@deck.cards.maximum(:position) || 0) + 1
    end
  end
end
