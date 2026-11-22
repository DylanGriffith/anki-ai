module Ai
  module Agent
    # Shared agent loop and toolbox for the two generation modes:
    # DeckBuilder ("New AI Deck", adds the create_deck tool) and CardAdder
    # ("Add AI cards to an existing deck"). The model gets a small set of
    # ActiveRecord-backed operations scoped to one deck (its note types and
    # notes); every step is journaled to the generation's transcript so the
    # status page can poll.
    #
    # The loop is deliberately simple and bounded:
    #   system+user prompt -> model response -> run tool calls ->
    #   append results -> repeat, until `finish`, the card limit, or the
    #   turn budget.
    # Tool errors are returned as results (error: true) so the model can
    # recover; only infrastructure errors (API down, invalid JSON) fail the
    # generation.
    class Base
      MAX_TURNS = 24
      DEFAULT_CARD_LIMIT = 20

      # Tool schemas keyed by name; TOOL_ORDER keeps a stable prompt.
      # Subclasses widen #offered_tools (DeckBuilder adds create_deck).
      TOOL_SCHEMA = {
        "create_deck" => {
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
        "upsert_note_type" => {
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
        "add_note" => {
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
        "update_note" => {
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
        "delete_note" => {
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
        "list_notes" => {
          type: "function",
          function: {
            name: "list_notes",
            description: "List the deck's notes (id, note type, fields, tags) to review what you built.",
            parameters: { type: "object", properties: {} }
          }
        },
        "finish" => {
          type: "function",
          function: {
            name: "finish",
            description: "Call when you are done: ends the generation. Prefer quality over quantity.",
            parameters: {
              type: "object",
              properties: {
                summary: { type: "string", description: "One sentence about what you built." }
              }
            }
          }
        }
      }.freeze
      TOOL_ORDER = %w[create_deck upsert_note_type add_note update_note delete_note list_notes finish].freeze

      # Card-writing rules shared by both modes; mode prompts are composed
      # from these blocks.
      CARD_RULES = <<~RULES
        Card-writing rules (they matter):
        - Atomic: one fact, name, or question per card.
        - The front asks a specific question the back answers directly.
        - Cloze notes use {{c1::…}} deletions in the Text field (kind: 'cloze').
        - No markdown in field values; plain text and simple HTML only.
      RULES

      DB_WARNING = <<~WARNING
        You are writing cards to a real database — your tool calls have
        side effects. Recover from tool errors by calling the tool again with
        corrected arguments.
      WARNING

      def initialize(generation, client: nil)
        @generation = generation
        @user = generation.user
        @client = client || default_client
        @deck = initial_deck
        @messages = [
          { role: "system", content: system_prompt },
          { role: "user", content: generation.prompt }
        ]
        @finished = false
        @cards_added = 0
      end

      attr_reader :deck, :cards_added

      def call
        @generation.log!(type: "status", text: "starting", model: @generation.model)
        MAX_TURNS.times do |turn|
          @generation.update!(turn_count: turn + 1)
          reply = @client.chat(model: @generation.model, messages: @messages, tools: tools,
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
                           content: "Continue with your tool calls, or call finish when you are done." }
            next
          end

          reply[:tool_calls].each do |call|
            result, error = run_tool(call[:name], call[:arguments])
            @messages << { role: "tool", tool_call_id: call[:id], content: JSON.generate(result) }
            @generation.log!(type: "tool", name: call[:name], arguments: call[:arguments],
                             result: result, error: error, at: Time.now.utc.to_i)
            break if @finished
          end

          if @finished
            break
          elsif limit_reached?
            # Deterministic stop: the run ends the moment card_limit cards
            # exist, whatever the model wanted to do next.
            @generation.log!(type: "status", text: "card limit reached",
                             cards: @cards_added, limit: card_limit)
            finish!(summary: "stopped at the card limit (#{card_limit} cards)")
            break
          end
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

      # The two modes differ in these hooks, and only these.
      def initial_deck
        nil # DeckBuilder has none until create_deck runs
      end

      def offered_tools
        %w[upsert_note_type add_note update_note delete_note list_notes finish]
      end

      def role_prompt
        "You are a flashcard card writer for a spaced-repetition study app (Anki-style)."
      end

      def workflow_prompt
        "" # subclasses replace
      end

      def tools
        TOOL_ORDER.filter_map { |name| TOOL_SCHEMA[name] if offered_tools.include?(name) }
      end

      def system_prompt
        [ role_prompt, workflow_prompt, CARD_RULES, limit_prompt, existing_deck_prompt, DB_WARNING ]
          .reject(&:blank?).join("\n\n")
      end

      # Mode hook: nothing to show in Base; CardAdder seeds a sample of the
      # deck's existing cards so the model is grounded even without calling
      # list_notes first.
      def existing_deck_prompt
        ""
      end

      def limit_prompt
        "Target about #{card_limit} cards (fewer is fine when quality demands it, " \
          "more is not — the run stops automatically at #{card_limit} cards)."
      end

      def card_limit
        @generation.card_limit || DEFAULT_CARD_LIMIT
      end

      def limit_reached?
        @cards_added >= card_limit
      end

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
        else                        [ { error: "unknown tool #{name.inspect}" }, true ]
        end
      rescue ActiveRecord::RecordInvalid => e
        [ { error: e.record.errors.full_messages.to_sentence }, true ]
      rescue StandardError => e
        [ { error: "#{e.class}: #{e.message}" }, true ]
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
        return [ { notice: "card limit already reached (#{card_limit}) — call finish" }, true ] if limit_reached?

        type = @deck.note_types.find_by!(name: args.fetch("note_type").to_s.strip)
        fields = Array(args.fetch("fields")).map(&:to_s)
        note = Note.create!(deck: @deck, note_type: type, fields: fields,
                            tags: args["tags"].to_s.strip, guid: SecureRandom.uuid)
        cards = Cards::Generate.call(note, position: note_position)
        @cards_added += cards.size
        [ { note_id: note.id, cards: cards.size, fields: note.fields, generated_cards: @cards_added }, false ]
      end

      # Queue position for the next generated card: appended behind
      # everything (max + 1), or — inserted up_next — allocated from below
      # the deck's current minimum by more than the whole batch limit so the
      # batch lands before every existing card while keeping its own order.
      def note_position
        if @generation.inserted_up_next?
          @frontier ||= (@deck.cards.minimum(:position) || 1) - card_limit - 1
          @frontier += 1
        else
          (@deck.cards.maximum(:position) || 0) + 1
        end
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
        finish!(summary: args["summary"].to_s)
        [ { done: true, notes: @deck ? @deck.notes.count : 0, cards_generated: @cards_added }, false ]
      end

      # Marks the generation done (also used by the automatic card-limit
      # stop, not just the finish tool).
      def finish!(summary:)
        @finished = true
        @generation.update!(status: :done, error: nil, finished_at: Time.now.utc)
        @generation.log!(type: "status", text: "finished", summary: summary.to_s)
      end

      def require_deck!
        raise Error, require_deck_message unless @deck
      end

      def require_deck_message
        "there is no deck to work with yet"
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
