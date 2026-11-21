# Renders a Card to safe HTML: Anki template rendering, sanitization of the
# deck-author HTML, and rewriting of media references ([sound:...] and
# <img src="...">) to this deck's media route.
class CardHtml
  SANITIZER_CLASS = defined?(Rails::HTML5::SafeListSanitizer) ? Rails::HTML5::SafeListSanitizer : Rails::HTML4::SafeListSanitizer
  ALLOWED_TAGS = SANITIZER_CLASS::DEFAULT_ALLOWED_TAGS.to_a + %w[audio source details summary mark input]
  ALLOWED_ATTRIBUTES = SANITIZER_CLASS::DEFAULT_ALLOWED_ATTRIBUTES.to_a +
                       %w[controls preload autoplay loop muted playsinline open
                          autocomplete autocapitalize autocorrect spellcheck aria-label]

  # media_url: proc { |filename| url } used for [sound:...] and <img src=...>.
  def self.render(card, side:, typed: nil, front_side: nil, media_url:)
    note = card.note
    note_type = note.note_type
    fields = note_type.field_names.zip(note.fields).to_h
    template = note_type.template(card.template_ord)

    context = {
      tags: note.tags,
      deck: card.deck.name,
      subdeck: card.anki_subdeck,
      note_type_name: note_type.name,
      card_name: template["name"],
      cloze_index: note_type.cloze? ? card.template_ord + 1 : nil,
      typed: typed,
      front_side: front_side
    }

    source = side == :question ? template["front"] : template["back"]
    raw = Anki::Template.render(source, side: side, fields: fields, context: context)
    rewrite_media(sanitize(raw), media_url).html_safe
  end

  # Note-type CSS, lightly scrubbed (CSS cannot execute scripts; this just
  # keeps it from breaking out of its <style> container).
  def self.css(note_type)
    note_type.css.to_s
             .gsub(%r{</style}, "")
             .gsub(/<!--|-->/, "")
             .gsub(/expression\s*\(/i, "")
             .gsub(%r{javascript:}i, "")
  end

  def self.sanitize(html)
    @sanitizer ||= SANITIZER_CLASS.new
    @sanitizer.sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
  end

  def self.rewrite_media(html, media_url)
    # [sound:file.mp3] -> audio element on this deck's media route (autoplay
    # attempts like Anki; browsers may refuse without a gesture).
    html = html.gsub(/\[sound:([^\]\[]+)\]/) do
      %(<audio controls data-autoplay preload="auto" src="#{url_attr(media_url, Regexp.last_match(1))}"></audio>)
    end
    # <img src="relative.png"> -> deck media route (absolute/remote URLs untouched)
    html = html.gsub(/(<img\b[^>]*\bsrc=")(?!https?:|data:|\/)([^"]*)(")/i) do
      Regexp.last_match(1) + url_attr(media_url, Regexp.last_match(2)) + Regexp.last_match(3)
    end
    html = html.gsub(/(<img\b[^>]*\bsrc=')(?!https?:|data:|\/)([^']*)(')/i) do
      Regexp.last_match(1) + url_attr(media_url, Regexp.last_match(2)) + Regexp.last_match(3)
    end
    html
  end

  def self.url_attr(media_url, filename)
    CGI.escapeHTML(media_url.call(filename.strip).to_s)
  end
end
