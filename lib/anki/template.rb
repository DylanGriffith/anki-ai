module Anki
  # Renders Anki note templates (qfmt/afmt) to HTML.
  #
  # Supported syntax:
  #   {{Field}}            raw HTML field value
  #   {{#Field}}...{{/Field}}   section rendered when field is non-empty (nestable)
  #   {{^Field}}...{{/Field}}   section rendered when field is empty
  #   {{cloze:Field}}      cloze text (uses context[:cloze_index])
  #   {{hint:Field}}       collapsible hint (<details>)
  #   {{type:Field}}       type-in-answer input (question) / comparison (answer)
  #   {{Tags}} {{Deck}} {{Subdeck}} {{Type}} {{Card}} {{FrontSide}}
  #
  # The output is deck-author HTML and must be sanitized by the caller (CardHtml).
  class Template
    TAG = /\{\{([^{}]*)\}\}/.freeze
    CLOZE = /\{\{c(\d+)::(.*?)\}\}/m.freeze

    def self.render(source, side:, fields: {}, context: {})
      fields = fields.to_h.transform_keys(&:to_s)
      new(source.to_s).render(context.merge(side: side, fields: fields))
    end

    def initialize(source)
      @source = source
    end

    def render(context)
      render_nodes(parse(@source), context)
    end

    private

    # --- Parsing -----------------------------------------------------------

    # Returns an array of nodes:
    #   [:text, str]
    #   [:field, name]           (fields + builtins)
    #   [:section, name, negated, children]
    #   [:cloze, name] [:hint, name] [:type, name]
    # Unclosed sections are closed implicitly; stray closers become text.
    def parse(source)
      root = []
      stack = [ [ nil, root ] ]
      pos = 0
      while (m = TAG.match(source, pos))
        append_text(stack.last[1], source[pos...m.begin(0)])
        tag = m[1].strip
        case tag
        when /\A#(.+)\z/m         then open_section(stack, Regexp.last_match(1).strip, false)
        when /\A\^(.+)\z/m        then open_section(stack, Regexp.last_match(1).strip, true)
        when %r{\A/(.+)\z}m       then close_section(stack, Regexp.last_match(1).strip, source, m)
        when /\Acloze:(.+)/m      then stack.last[1] << [ :cloze, Regexp.last_match(1).strip ]
        when /\Ahint:(.+)/m       then stack.last[1] << [ :hint, Regexp.last_match(1).strip ]
        when /\Atype:(.+)/m       then stack.last[1] << [ :type, Regexp.last_match(1).strip ]
        else                           stack.last[1] << [ :field, tag ]
        end
        pos = m.end(0)
      end
      append_text(stack.last[1], source[pos..]) if pos < source.length
      root
    end

    def open_section(stack, name, negated)
      children = []
      stack.last[1] << [ :section, name, negated, children ]
      stack.push([ name, children ])
    end

    def close_section(stack, name, source, match)
      depth = stack.rindex { |open_name, _| open_name == name }
      if depth.nil? || depth.zero?
        append_text(stack.last[1], match[0]) # unbalanced: keep literal
      else
        stack.slice!(depth..)
      end
    end

    def append_text(nodes, text)
      nodes << [ :text, text ] unless text.empty?
    end

    # --- Rendering ---------------------------------------------------------

    def render_nodes(nodes, context)
      nodes.map { |node| render_node(node, context) }.join
    end

    def render_node(node, context)
      case node[0]
      when :text    then node[1]
      when :field   then render_field(node[1], context)
      when :section
        name, negated, children = node[1], node[2], node[3]
        present = section_present?(name, context)
        (negated ? !present : present) ? render_nodes(children, context) : ""
      when :cloze   then render_cloze(field_value(node[1], context), context)
      when :hint    then render_hint(field_value(node[1], context))
      when :type    then render_type(node[1], context)
      end
    end

    def render_field(name, context)
      case name
      when "Tags"      then escape(context[:tags].to_s.split(/\s+/).reject(&:empty?).join(" "))
      when "Deck"      then escape(context[:deck].to_s)
      when "Subdeck"   then escape(context[:subdeck].to_s)
      when "Type"      then escape(context[:note_type_name].to_s)
      when "Card"      then escape(context[:card_name].to_s)
      when "FrontSide" then context[:front_side].to_s
      else field_value(name, context) # raw: field values are HTML by design
      end
    end

    def section_present?(name, context)
      return context[:tags].to_s.strip.present? if name == "Tags"
      field_value(name, context).strip.present?
    end

    def field_value(name, context)
      context.dig(:fields, name).to_s
    end

    def render_cloze(text, context)
      index = context[:cloze_index] || 1
      text.gsub(CLOZE) do
        n = Regexp.last_match(1).to_i
        content = Regexp.last_match(2).to_s
        answer, hint = content.split("::", 2)
        if n == index
          if context[:side] == :question
            hint.present? ? "[#{hint}]" : "[...]"
          else
            %(<span class="cloze">#{answer}</span>)
          end
        else
          "[...]"
        end
      end
    end

    def render_hint(value)
      %(<details class="hint"><summary>Show hint</summary>#{value}</details>)
    end

    def render_type(name, context)
      if context[:side] == :question
        %(<input type="text" name="typed" class="typebox" autocomplete="off" ) +
          %(autocapitalize="off" autocorrect="off" spellcheck="false" aria-label="Type the answer">)
      else
        typed = context[:typed].to_s
        correct = field_value(name, context)
        if typed == correct
          %(<div class="typed typed--ok">#{escape(typed)}</div>)
        else
          %(<div class="typed typed--bad">#{escape(typed)}</div>) +
            %(<div class="typed typed--correct">#{escape(correct)}</div>)
        end
      end
    end

    def escape(html)
      CGI.escapeHTML(html)
    end
  end
end
