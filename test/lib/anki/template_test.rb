require "test_helper"

class Anki::TemplateTest < ActiveSupport::TestCase
  def render(source, side: :question, fields: {}, context: {})
    Anki::Template.render(source, side: side, fields: fields, context: context)
  end

  test "substitutes fields as raw HTML" do
    assert_equal "Front: <b>bold</b>", render("Front: {{Front}}", fields: { "Front" => "<b>bold</b>" })
  end

  test "unknown fields render empty" do
    assert_equal "[]", render("[{{Missing}}]", fields: { "Front" => "x" })
  end

  test "sections render only when the field is present" do
    src = "{{#Front}}HAS{{/Front}}-{{^Back}}NOBACK{{/Back}}"
    assert_equal "HAS-NOBACK", render(src, fields: { "Front" => "x" })
    assert_equal "HAS-", render(src, fields: { "Front" => "x", "Back" => "y" })
    assert_equal "-NOBACK", render(src, fields: { "Front" => "  " }) # whitespace-only counts as empty
  end

  test "sections nest" do
    src = "{{#A}}a{{#B}}b{{/B}}{{/A}}"
    assert_equal "ab", render(src, fields: { "A" => "1", "B" => "2" })
    assert_equal "a", render(src, fields: { "A" => "1" })
    assert_equal "", render(src, fields: {})
  end

  test "ug-style conditional question template" do
    src = "{{#Capital}}<div class=\"value\">{{Country}}</div>{{/Capital}}<hr>{{^Capital}}no cap{{/Capital}}"
    out = render(src, fields: { "Country" => "England", "Capital" => "London" })
    assert_equal %(<div class="value">England</div><hr>), out
  end

  test "specials: Tags, Deck, Subdeck, Type, Card" do
    out = render("{{Tags}}|{{Deck}}|{{Subdeck}}|{{Type}}|{{Card}}", context: {
      tags: " vocab french ", deck: "French", subdeck: "French::Sub", note_type_name: "Basic", card_name: "Card 1"
    })
    assert_equal "vocab french|French|French::Sub|Basic|Card 1", out
  end

  test "Tags section works" do
    assert_equal "tagged", render("{{#Tags}}tagged{{/Tags}}", context: { tags: "a b" })
    assert_equal "", render("{{#Tags}}tagged{{/Tags}}", context: { tags: "" })
  end

  test "FrontSide passes through pre-rendered question" do
    assert_equal "Q-HTML<hr>", render("{{FrontSide}}<hr>", context: { front_side: "Q-HTML" })
  end

  test "cloze masks the current cloze on the question and reveals it on the answer" do
    fields = { "Text" => "Berlin is {{c1::the capital}} of {{c2::Germany}}" }
    q = render("{{cloze:Text}}", side: :question, fields: fields, context: { cloze_index: 1 })
    assert_equal "Berlin is [...] of [...]", q
    a = render("{{cloze:Text}}", side: :answer, fields: fields, context: { cloze_index: 1 })
    assert_equal %(Berlin is <span class="cloze">the capital</span> of [...]), a
    a2 = render("{{cloze:Text}}", side: :answer, fields: fields, context: { cloze_index: 2 })
    assert_equal "Berlin is [...] of <span class=\"cloze\">Germany</span>", a2
  end

  test "cloze with hint" do
    fields = { "Text" => "{{c1::Paris::capital of France}}" }
    q = render("{{cloze:Text}}", side: :question, fields: fields, context: { cloze_index: 1 })
    assert_equal "[capital of France]", q
  end

  test "hint renders a details element" do
    out = render("{{hint:Extra}}", fields: { "Extra" => "think rivers" })
    assert_equal %(<details class="hint"><summary>Show hint</summary>think rivers</details>), out
  end

  test "type filter renders an input on the question" do
    out = render("{{type:Back}}", side: :question, fields: { "Back" => "London" })
    assert_match %r{<input[^>]*class="typebox"}, out
  end

  test "type filter compares on the answer" do
    ok = render("{{type:Back}}", side: :answer, fields: { "Back" => "London" },
                context: { typed: "London" })
    assert_match %r{class="typed typed--ok">London<}, ok

    bad = render("{{type:Back}}", side: :answer, fields: { "Back" => "London" },
                 context: { typed: "Londn" })
    assert_match %r{class="typed typed--bad">Londn<}, bad
    assert_match %r{class="typed typed--correct">London<}, bad
  end

  test "unclosed section closes implicitly at end of template" do
    assert_equal "abc", render("{{#Front}}abc", fields: { "Front" => "x" })
  end

  test "stray close tag is kept literal" do
    assert_equal "a{{/Nope}}b", render("a{{/Nope}}b", fields: {})
  end

  test "tags tolerate inner spaces" do
    assert_equal "x", render("{{ Front }}", fields: { "Front" => "x" })
  end

  test "non-tag braces stay literal" do
    assert_equal "{{not-a-tag", render("{{not-a-tag", fields: {})
  end
end
