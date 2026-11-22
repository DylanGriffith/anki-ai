module Ai
  module Agent
    # The deck-builder agent loop. The model gets a small toolbox of
    # ActiveRecord-backed operations scoped to this one generation (its own
    # new deck, its own note types/notes); every step is journaled to the
    # generation's transcript so the UI can poll.
    #
    # The loop is deliberately simple and bounded:
    #   system+user prompt -> model response -> run tool calls ->
    #   append results -> repeat, until `finish` or the turn budget.
    # Tool errors are returned as results (error: true) so the model can
    # recover; only infrastructure errors (API down, invalid JSON) fail the
    # generation.
    class DeckBuilder
      MAX_TURNS = 24

      TOOL_SCHEMA = [
        {
          type: "function",
          function: {
            name: "create_deck",
            description: "Create the flashcard deck. Call this exactly once, before adding note types or notes.",
            parameters: {
              type: "object",
              properties: {
                name: { type: "string", description: "Deck name, e.g. 'French A1 Verbs'." },
                description: { type: "string", description: "Short deck description (optional)." }
              },
              required: %w[name]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "upsert_note_type",
            description: "Create (or update) a note type the deck's notes will use. " \
                         "Default to one shared type like Basic (Front/Back).",
            parameters: {
              type: "object",
              properties: {
                name: { type: "string", description: "Note type name, e.g. 'Basic'." },
                kind: { type: "string", enum: %w[standard cloze],
                        description: "'cloze' for {{c1::…}} deletion notes; otherwise 'standard'." },
                fields: { type: "array", items: { type: "string" },
                          description: "Field names in order, e.g. ['Front', 'Back']." },
                front_template: { type: "string",
                                  description: "Front (question) template, e.g. '{{Front}}'." },
                back_template: { type: "string",
                                 description: "Back (answer) template, e.g. '{{FrontSide}}<hr>{{Back}}'." },
                css: { type: "string", description: "Optional card CSS." }
              },
              required: %w[name fields front_template back_template]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "add_note",
            description: "Add one note (one flashcard item) to the deck, using an existing note type.",
            parameters: {
              type: "object",
              properties: {
                note_type: { type: "string", description: "Name of an existing note type." },
                fields: { type: "array", items: { type: "string" },
                          description: "Field values, in the note type's field order." },
                tags: { type: "string", description: "Space-separated tags (optional)." }
              },
              required: %w[note_type fields]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "update_note",
            description: "Update an existing note's field values or tags.",
            parameters: {
              type: "object",
              properties: {
                note_id: { type: "integer", description: "The note id from add_note/list_notes." },
                fields: { type: "array", items: { type: "string" },
                          description: "New field values (all fields, in order)." },
                tags: { type: "string" }
              },
              required: %w[note_id]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "delete_note",
            description: "Delete a note (and its cards) from the deck.",
            parameters: {
              type: "object",
              properties: {
                note_id: { type: "integer", description: "The note id from add_note/list_notes." }
              },
              required: %w[note_id]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "list_notes",
            description: "List the deck's notes (id, note type, fields, tags) to review what you built.",
            parameters: { type: "object", properties: {} }
          }
        },
        {
          type: "function",
          function: {
            name: "finish",
            description: "Call when the deck is complete: ends the generation. Prefer quality over quantity.",
            parameters: {
              type: "object",
              properties: {
                summary: { type: "string", description: "One sentence about what you built." }
              }
            }
          }
        }
      ].freeze

      SYSTEM_PROMPT = <<~PROMPT
        You are a flashcard deck builder for a spaced-repetition study app (Anki-style).
        The user gives you a topic; you build a study deck with well-crafted cards.

        Workflow: create_deck once, upsert_note_type (usually one 'Basic' type with
        Front/Back fields), then add_note for each card. Use list_notes to review your
        work and update_note/delete_note to fix problems. Call finish when done.

        Card-writing rules (they matter):
        - Atomic: one fact, name, or question per card.
        - The front asks a specific question the back answers directly.
        - Include 8-20 cards for a typical topic unless the user asks otherwise.
        - Cloze notes use {{c1::…}} deletions in the Text field (kind: 'cloze').
        - No markdown in field values; plain text and simple HTML only.

        You are building a real deck in a real database — your tool calls have
        side effects. Recover from tool errors by calling the tool again with
        corrected arguments.
      PROMPT

      def initialize(generation, client: nil)
        @generation = generation
        @user = generation.user
        @client = client || default_client
        @messages = [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: generation.prompt }
        ]
        @deck = nil
        @finished = false
      end

      attr_reader :deck

      def call
        @generation.log!(type: "status", text: "starting", model: @generation.model)
        MAX_TURNS.times do |turn|
          @generation.update!(turn_count: turn + 1)
          reply = @client.chat(model: @generation.model, messages: @messages, tools: TOOL_SCHEMA,
                               on_delta: ->(state) {
                                 @generation.log_stream!(text: state[:content],
                                                         thinking: state[:thinking],
                                                         tool_calls: state[:tool_calls],
                                                         chars: state[:content].length +
                                                                state[:thinking].length)
                               })

          @messages << { role: "assistant", content: history_content(reply[:content]),
                         tool_calls: reply[:tool_calls].map { |c| { id: c[:id], type: "function",
                                                                   function: { name: c[:name],
                                                                               arguments: JSON.generate(c[:arguments]) } } } }
          log_assistant(reply)

          if reply[:tool_calls].empty?
            # The model replied without acting — nudge it back to tools; the
            # next iteration's budget check ends the loop if it keeps this up.
            @messages << { role: "user",
                           content: "Continue with your tool calls, or call finish when the deck is done." }
            next
          end

          reply[:tool_calls].each do |call|
            result, error = run_tool(call[:name], call[:arguments])
            @messages << { role: "tool", tool_call_id: call[:id], content: JSON.generate(result) }
            @generation.log!(type: "tool", name: call[:name], arguments: call[:arguments],
                             result: result, error: error, at: Time.now.utc.to_i)
            break if @finished
          end

          break if @finished
        end

        unless @finished
          raise Error, "the model did not call finish within #{MAX_TURNS} turns"
        end
      rescue Error => e
        @generation.clear_stream!
        @generation.update!(status: :failed, error: e.message, finished_at: Time.now.utc)
        @generation.log!(type: "status", text: "failed", error: e.message)
        :failed
      else
        :done
      end

      private

      def default_client
        setting = Setting.current
        Client.new(base_url: setting.base_url, api_key: setting.api_key)
      end

      # The model's own words go back into the chat history; cap pathological
      # monologues so a looping model cannot bloat (and slow) every later
      # request. Thinking is never sent back — providers ignore or reject it.
      HISTORY_TEXT_MAX = 8_000

      def history_content(text)
        return text if text.nil? || text.length <= HISTORY_TEXT_MAX

        "#{text.first(4_000)}\n…[truncated #{text.length - 6_000} characters]…\n#{text.last(2_000)}"
      end

      def log_assistant(reply)
        entry = { type: "assistant", turn: @generation.turn_count, at: Time.now.utc.to_i }
        entry[:text] = reply[:content] if reply[:content].present?
        entry[:thinking] = reply[:thinking] if reply[:thinking].present?
        entry[:tool_calls] = reply[:tool_calls].map { |c| c[:name] } if reply[:tool_calls].any?
        @generation.log_assistant!(entry)
      end

      # Executes one tool; returns [result_hash, error_flag]. Tool errors are
      # results the model can see and recover from, not exceptions.
      def run_tool(name, args)
        case name
        when "create_deck"     then create_deck(args)
        when "upsert_note_type" then upsert_note_type(args)
        when "add_note"        then add_note(args)
        when "update_note"     then update_note(args)
        when "delete_note"     then delete_note(args)
        when "list_notes"      then list_notes
        when "finish"          then finish(args)
        else                        [ { error: "unknown tool #{name}" }, true ]
        end
      rescue ActiveRecord::RecordInvalid => e
        [ { error: e.record.errors.full_messages.to_sentence }, true ]
      rescue StandardError => e
        [ { error: "#{e.class}: #{e.message}" }, true ]
      end

      def create_deck(args)
        return [ { error: "deck already created for this generation" }, true ] if @deck

        @deck = Deck.create!(user: @user, name: args.fetch("name").to_s.strip,
                             description: args["description"].to_s.strip)
        @generation.update!(deck: @deck)
        @generation.log!(type: "status", text: "deck created", deck: @deck.name)
        [ { deck_id: @deck.id, name: @deck.name }, false ]
      end

      def upsert_note_type(args)
        require_deck!
        name = args.fetch("name").to_s.strip
        kind = args["kind"] == "cloze" ? :cloze : :standard
        fields = Array(args.fetch("fields")).map(&:to_s)
        front = args.fetch("front_template").to_s
        back = args.fetch("back_template").to_s

        type = @deck.note_types.find_or_initialize_by(name: name)
        type.kind = kind
        type.field_names = fields
        type.templates = [ { "name" => name, "front" => front, "back" => back } ]
        type.card_requirements = requirements_for(front, fields, kind)
        type.css = args["css"].to_s
        type.save!
        [ { note_type: type.name, fields: type.field_names }, false ]
      end

      def add_note(args)
        require_deck!
        type = @deck.note_types.find_by!(name: args.fetch("note_type").to_s.strip)
        fields = Array(args.fetch("fields")).map(&:to_s)
        note = Note.create!(deck: @deck, note_type: type, fields: fields,
                            tags: args["tags"].to_s.strip, guid: SecureRandom.uuid)
        cards = Cards::Generate.call(note, position: @deck.notes.count)
        [ { note_id: note.id, cards: cards.size, fields: note.fields }, false ]
      end

      def update_note(args)
        require_deck!
        note = @deck.notes.find(args.fetch("note_id"))
        note.fields = args["fields"].map(&:to_s) if args.key?("fields")
        note.tags = args["tags"].to_s.strip if args.key?("tags")
        note.save!
        [ { note_id: note.id, updated: true }, false ]
      end

      def delete_note(args)
        require_deck!
        note = @deck.notes.find(args.fetch("note_id"))
        note.destroy!
        [ { deleted: note.id }, false ]
      end

      def list_notes
        require_deck!
        [ { notes: @deck.notes.order(:id).map do |note|
          { note_id: note.id, note_type: note.note_type.name,
            fields: note.fields, tags: note.tags_list }
        end }, false ]
      end

      def finish(args)
        @finished = true
        @generation.update!(status: :done, error: nil, finished_at: Time.now.utc)
        summary = args["summary"].to_s
        @generation.log!(type: "status", text: "finished", summary: summary)
        [ { done: true, notes: @deck ? @deck.notes.count : 0 }, false ]
      end

      def require_deck!
        raise Error, "create the deck first (create_deck) before using this tool" unless @deck
      end

      # Which fields make a card generatable: fields the front template
      # actually shows (same shape Anki stores for 'req', but with names).
      def requirements_for(front, fields, kind)
        return [ [ 0, "any", fields ] ] if kind == :cloze

        shown = fields.select { |f| front.to_s.match?(/\{\{#{Regexp.escape(f)}\}\}/) }
        shown = [] if fields.empty?
        [ [ 0, "any", shown ] ]
      end
    end
  end
end
