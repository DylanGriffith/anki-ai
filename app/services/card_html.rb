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
    html = sanitize(raw)
    html = occlusion_mask(html, card) if note_type.occlusion? && side == :question
    rewrite_media(html, media_url).html_safe
  end

  # Occlusion cards: the question side wraps the labeled image and covers one
  # label rectangle (the card's mask), which the answer side reveals. The
  # markup is server-generated after sanitization, so its inline styles
  # (positions in % of the image dimensions) are safe by construction.
  def self.occlusion_mask(html, card)
    html.gsub(/<img\b[^>]*\bsrc=["']([^"']+)["'][^>]*>/i) do |img|
      media = card.deck.media_files.find_by(filename: Regexp.last_match(1).strip)
      masks = Array(media&.masks)
      next img if masks.empty?
      m = masks[card.template_ord % masks.size] || masks.first
      box = %(<span class="occl-mask" style="left:#{(m["x"].to_f * 100)}%;) +
            %(top:#{(m["y"].to_f * 100)}%;width:#{(m["w"].to_f * 100)}%;) +
            %(height:#{(m["h"].to_f * 100)}%"></span>)
      %(<span class="occl-wrap">#{img}#{box}</span>)
    end
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
