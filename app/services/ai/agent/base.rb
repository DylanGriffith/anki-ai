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
        "generate_image" => {
          type: "function",
          function: {
            name: "generate_image",
            description: "Generate a picture or diagram and attach it to the deck as a " \
                         "media file. OPTIONAL and slow: call it ONLY when the user's " \
                         "request explicitly asks for an image, picture, or diagram — " \
                         "not on your own initiative. The result's `usage` shows the " \
                         "exact <img> tag to put in a field value.",
            parameters: {
              type: "object",
              properties: {
                filename: { type: "string",
                            description: "Simple snake-case file name ending in .png/.jpg/.jpeg/.webp, e.g. 'neuron.png'." },
                prompt: { type: "string",
                          description: "What the image should show, e.g. 'Simple labeled diagram of a neuron: soma, dendrites, axon, myelin sheath, synapse. Clean flat style, no watermark'." },
                occlusion: { type: "boolean",
                             description: "true only when the user explicitly asked for image " \
                                          "occlusion — a labeled diagram studied by recalling " \
                                          "what each label names ('labels of parts of a " \
                                          "neuron'): auto-derives one mask per label, and " \
                                          "generates one occlusion card per mask from a single " \
                                          "occlusion note. Otherwise omit it." }
              },
              required: %w[filename prompt]
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
            description: "List the deck's first notes (up to 50: id, note type, fields, tags) " \
                         "to review what you built. Use search_notes to find specific " \
                         "content beyond the first 50.",
            parameters: { type: "object", properties: {} }
          }
        },
        "search_notes" => {
          type: "function",
          function: {
            name: "search_notes",
            description: "Search the deck's notes for a text snippet (case-insensitive, " \
                         "fields and tags) — e.g. to check whether a card already exists " \
                         "before adding it. Returns up to 25 matches.",
            parameters: {
              type: "object",
              properties: {
                query: { type: "string", description: "Text to search for, e.g. 'mitose' or 'Biology::Cell'." }
              },
              required: %w[query]
            }
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
      TOOL_ORDER = %w[create_deck upsert_note_type generate_image add_note update_note delete_note list_notes search_notes finish].freeze

      # Card-writing rules shared by both modes; mode prompts are composed
      # from these blocks.
      CARD_RULES = <<~RULES
        Card-writing rules (they matter):
        - Atomic: one fact, name, or question per card.
        - The front asks a specific question the back answers directly.
        - Cloze notes use {{c1::…}} deletions in the Text field (kind: 'cloze').
        - No markdown in field values; plain text and simple HTML only.
        - An <img> belongs in exactly ONE field of a note. The back template
          already re-renders the front side, so repeating the same <img> in
          the answer field shows the picture twice at full height.
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
        @images_generated = 0
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
        tools = %w[upsert_note_type add_note update_note delete_note list_notes search_notes finish]
        tools << "generate_image" if images_configured?
        tools
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
        [ role_prompt, workflow_prompt, CARD_RULES, limit_prompt, existing_deck_prompt,
          images_prompt, DB_WARNING ].reject(&:blank?).join("\n\n")
      end

      # Mode hook: nothing to show in Base; CardAdder seeds a sample of the
      # deck's existing cards so the model is grounded even without calling
      # list_notes first.
      def existing_deck_prompt
        ""
      end

      # Prompt guidance for the optional image tool; only when the image API
      # is configured (rake ai:image_config[...]).
      def images_prompt
        return "" unless images_configured?

        "The generate_image tool creates a picture or diagram and attaches it to the " \
          "deck as a media file (at most #{IMAGES_PER_RUN} per run). It is OPTIONAL and " \
          "slower than everything else: call it ONLY when the user's request explicitly " \
          "asks for a picture, diagram, image, or visual — never on your own " \
          "initiative, and never for decks that are fine as plain text cards. When you " \
          "do use it, reference the generated file in field values as " \
          "<img src='filename.png'> (never remote or data URLs), and write cards around " \
          "what the image shows.\n" \
          "Occlusion: when the user explicitly asks for image occlusion (a labeled " \
          "diagram studied by recalling what each label names, e.g. 'labels of parts " \
          "of a neuron'), pass occlusion: true to " \
          "generate_image, then create one occlusion note type (kind 'occlusion', fields " \
          "['Image', 'Notes'], front template '{{Image}}', back template " \
          "'{{Image}}<hr>{{Notes}}') and exactly ONE occlusion note whose Image field " \
          "holds the <img>. The app derives one mask per label and generates one card " \
          "per mask — the front covers one label, the answer reveals it. Do not add " \
          "several notes for the same occlusion image."
      end

      def images_configured?
        Setting.current.image_configured?
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
        when "create_deck"      then create_deck(args)
        when "upsert_note_type" then upsert_note_type(args)
        when "generate_image"   then generate_image(args)
        when "add_note"         then add_note(args)
        when "update_note"      then update_note(args)
        when "delete_note"      then delete_note(args)
        when "list_notes"       then list_notes
        when "search_notes"     then search_notes(args)
        when "finish"           then finish(args)
        else                        [ { error: "unknown tool #{name.inspect}" }, true ]
        end
      rescue ActiveRecord::RecordInvalid => e
        [ { error: e.record.errors.full_messages.to_sentence }, true ]
      rescue StandardError => e
        [ { error: "#{e.class}: #{e.message}" }, true ]
      end

      # Bounds for the optional image tool: a run may generate a few low-cost
      # images, never an unbounded gallery.
      IMAGES_PER_RUN = 4
      IMAGE_FILENAME = /\A[a-z0-9][a-z0-9_-]*\.(png|jpe?g|webp)\z/i
      # The editing prompt that turns a labeled diagram into its label-free
      # twin, so the pixel diff can localize every label.
      OCCLUSION_UNLABEL_PROMPT = "Remove ALL text labels and their thin pointer lines " \
                                 "from this diagram. Keep the drawing EXACTLY identical — " \
                                 "same position, same shapes, same colors. Erase the text " \
                                 "and pointer lines to the plain background."

      # Generates one image via the configured Images API and attaches it as
      # a deck media file; the model then embeds <img src="..."> in a field.
      # API/network failures are recoverable tool errors, like every tool.
      def generate_image(args)
        require_deck!
        if @images_generated >= IMAGES_PER_RUN
          return [ { error: "the run already generated #{IMAGES_PER_RUN} images — " \
                           "that is the limit" }, true ]
        end

        filename = args.fetch("filename", "").to_s.strip
        unless filename.match?(IMAGE_FILENAME)
          return [ { error: "filename must be a simple name like 'neuron.png' (got #{filename.inspect})" }, true ]
        end
        prompt = args.fetch("prompt", "").to_s.strip
        return [ { error: "prompt is required" }, true ] if prompt.empty?
        if @deck.media_files.exists?(filename: filename)
          return [ { error: "a media file named #{filename} already exists — pick " \
                            "another name" }, true ]
        end

        setting = Setting.current
        client = ImagesClient.new(base_url: setting.image_base_url,
                                  api_key: setting.image_api_key)
        image = client.generate(prompt: prompt,
                                model: setting.image_model.presence || ImagesClient::DEFAULT_MODEL)

        media = @deck.media_files.create!(
          filename: filename,
          content_type: image[:content_type].presence || MediaFile.content_type_for(filename)
        )
        begin
          attach_image_bytes(media, image[:bytes])
          if args["occlusion"]
            media.update!(masks: occlusion_masks(client, setting, image))
          end
        rescue StandardError
          media.destroy!
          raise
        end

        @images_generated += 1
        @generation.log!(type: "status", text: "image generated", image: filename)
        result = { media: filename, images_left: IMAGES_PER_RUN - @images_generated,
                   usage: %(<img src="#{filename}">) }
        if args["occlusion"]
          result[:masks] = media.masks.size
          result[:usage] += " — use an occlusion note type (kind 'occlusion'); one note " \
                           "referencing this image generates one card per mask"
        end
        [ result, false ]
      end

      # The label-free twin is a throwaway: edit, diff, discard.
      def occlusion_masks(client, setting, image)
        clean = client.edit(prompt: OCCLUSION_UNLABEL_PROMPT,
                            image_bytes: image[:bytes],
                            model: setting.image_model.presence || ImagesClient::DEFAULT_MODEL,
                            size: image[:size])
        masks = Ai::PixelDiff.masks(labeled_bytes: image[:bytes], clean_bytes: clean[:bytes])
        @generation.log!(type: "status", text: "occlusion masks derived", masks: masks.size)
        masks
      end

      # MediaFile#attach_from uploads from a path; hand it a Tempfile.
      def attach_image_bytes(media, bytes)
        file = Tempfile.new([ "ai-image", ".bin" ])
        file.binmode
        file.write(bytes)
        file.flush
        media.attach_from(file.path)
      ensure
        file&.close!
      end

      def upsert_note_type(args)
        require_deck!
        name = args.fetch("name").to_s.strip
        kind = %w[cloze occlusion].include?(args["kind"]) ? args["kind"].to_sym : :standard
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

      # Caps that keep tool results (and the model's context) bounded even
      # on decks with tens of thousands of cards.
      LIST_NOTES_LIMIT = 50
      SEARCH_NOTES_LIMIT = 25

      def list_notes
        require_deck!
        total = @deck.notes.count
        result = { notes: notes_payload(@deck.notes.order(:id).limit(LIST_NOTES_LIMIT)),
                   total_notes: total }
        if total > LIST_NOTES_LIMIT
          result[:notice] = "showing the first #{LIST_NOTES_LIMIT} of #{total} notes — " \
                            "use search_notes to find specific content"
        end
        [ result, false ]
      end

      # Case-insensitive substring search over fields (JSON) and tags — the
      # bounded way to check a big deck for near-duplicates, since list_notes
      # only shows the first 50 notes.
      def search_notes(args)
        require_deck!
        query = args.fetch("query", "").to_s.strip
        return [ { error: "query is required" }, true ] if query.empty?

        pattern = "%#{query.gsub(/[\\%_]/) { |ch| "\\#{ch}" }}%"
        scope = @deck.notes
                    .where("fields LIKE :p ESCAPE '\\' OR tags LIKE :p ESCAPE '\\'", p: pattern)
                    .order(:id)
        total = scope.count
        result = { query: query, notes: notes_payload(scope.limit(SEARCH_NOTES_LIMIT)),
                   matches: total }
        if total > SEARCH_NOTES_LIMIT
          result[:notice] = "showing the first #{SEARCH_NOTES_LIMIT} of #{total} matches — " \
                            "make the query more specific"
        end
        [ result, false ]
      end

      def note_payload(note)
        { note_id: note.id, note_type: note.note_type.name,
          fields: note.fields, tags: note.tags_list }
      end

      def notes_payload(scope)
        scope.map { |note| note_payload(note) }
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
        return [ [ 0, "any", fields ] ] if kind == :cloze || kind == :occlusion

        shown = fields.select { |f| front.to_s.match?(/\{\{#{Regexp.escape(f)}\}\}/) }
        shown = [] if fields.empty?
        [ [ 0, "any", shown ] ]
      end
    end
  end
end
