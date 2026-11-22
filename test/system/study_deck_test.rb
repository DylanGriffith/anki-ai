require "application_system_test_case"

class StudyDeckTest < ApplicationSystemTestCase
  include StudySystemHelpers

  test "full study session: reveal, rate, progress and audio" do
    deck = login_and_import

    # Deck page shows study stats
    assert_text "0 due now"
    assert_text "3 new left today"
    click_on "Study"

    # Card 1: question side, then reveal the answer
    assert_text "hello"
    assert_no_text "bonjour"
    # Show Answer sits in the bottom-pinned answer bar
    assert_selector ".answer-bar button", text: "Show Answer"
    assert_equal "fixed", page.evaluate_script(
      "getComputedStyle(document.querySelector('.answer-bar')).position"
    )
    # ...and spans the full bar width (padding aside)
    spans_bar = page.evaluate_script(<<~JS)
      (() => {
        const bar = document.querySelector(".answer-bar").getBoundingClientRect();
        const btn = document.querySelector(".answer-bar .btn--block").getBoundingClientRect();
        return bar.width - btn.width < 26;
      })()
    JS
    assert spans_bar, "Show Answer should span the full answer bar width"
    show_h = page.evaluate_script(
      "document.querySelector('.answer-bar .btn--block').getBoundingClientRect().height"
    )
    evidence("step3_study_question")

    click_submit("Show Answer")
    assert_text "hello"
    assert_text "bonjour"
    assert_selector "button[name='rating'][value='1']", text: /Again/
    assert_selector "button[name='rating'][value='3']", text: /Good/
    # Four rating buttons in one row, pinned to the bottom (Anki app style)
    assert_selector ".answer-bar button[name='rating']", count: 4
    one_row = page.evaluate_script(<<~JS)
      (() => {
        const btns = [...document.querySelectorAll(".answer-bar button[name='rating']")];
        const tops = btns.map(b => Math.round(b.getBoundingClientRect().top));
        return btns.length === 4 && tops.every(t => t === tops[0]);
      })()
    JS
    assert one_row, "rating buttons should share a single row in the answer bar"
    # ...at the same height as Show Answer, so nothing shifts between pages
    equal_height = page.evaluate_script(<<~JS, show_h)
      (() => {
        const h = arguments[0];
        return [...document.querySelectorAll(".answer-bar button[name='rating']")]
          .every(b => Math.abs(b.getBoundingClientRect().height - h) < 1);
      })()
    JS
    assert equal_height, "answer bar buttons should all be the same height"
    evidence("step3_study_answer")

    # Rate Good: card moves to learning (10 min), next card shows
    click_rating(3)
    assert_text "dog"
    assert_no_text "chien"

    # Rate Easy: graduates immediately, next card has audio
    click_submit("Show Answer")
    click_rating(4)
    assert_text "water"
    click_submit("Show Answer")
    assert_text "l'eau"
    assert_selector "audio[data-autoplay][src*='water.mp3']", count: 1
    evidence("step3_study_answer_audio")

    # Finish the session: rating the last card Good leaves it in learning
    # (due in ~10 minutes), so the study page shows its waiting state.
    click_rating(3)
    assert_text "No cards ready right now"
    assert_text "3 reviews, 3 new cards"
    evidence("step3_study_done")

    # Reloading shows the same waiting state with today's counts
    visit study_deck_path(deck)
    assert_text "No cards ready right now"
    assert_text "3 reviews, 3 new cards"
  end

  test "add card with add-to-next jumps the new-card queue" do
    deck = login_and_import

    # Add a normal card first (position after imported cards)
    visit deck_path(deck)
    click_on "Add card"
    fill_in "fields[Front]", with: "normal card"
    fill_in "fields[Back]", with: "appended"
    click_submit("Add card")
    assert_text "Card added"

    # Add one with "add to next": should come FIRST in the new queue
    visit new_card_deck_path(deck)
    fill_in "fields[Front]", with: "urgent card"
    fill_in "fields[Back]", with: "next up"
    # Set via DOM: synthesized checkbox clicks suffer the same input-pipeline
    # drops as submit clicks, and a silently unchecked box would append the
    # card instead of jumping the queue. Nothing listens to this checkbox's
    # events, so setting .checked is equivalent.
    find("#add_to_next").execute_script("this.checked = true")
    click_submit("Add card")
    assert_text "urgent card", count: 1

    # The browse list orders by position: urgent card first
    visit cards_deck_path(deck)
    first_li = first(".deck-list li").text
    assert first_li.start_with?("urgent card"), "expected urgent card first, got: #{first_li}"
    evidence("step3_add_to_next_browse")

    # And it is the first new card in the study queue
    visit study_deck_path(deck)
    assert_text "urgent card"
    evidence("step3_add_to_next_study")
  end

  test "note-type CSS is injected via textContent and cannot break out of the style tag" do
    builder = AnkiApkgBuilder.new
      .add_model(id: 1600000000001, name: "Basic", fields: %w[Front Back],
                 templates: [ { name: "Card 1", front: "{{Front}}", back: "{{Back}}" } ],
                 css: ".card { color: red; }</style><script>window.__cssXss = 1</script>")
      .add_deck(id: 1650000000001, name: "Css Deck", desc: "css injection probe")
      .add_note(id: 1600000000101, guid: "g1", mid: 1600000000001, fields: [ "a", "b" ])
      .add_card(id: 1600000000201, nid: 1600000000101, did: 1650000000001, due: 1)
    User.create!(name: "student", password: "password123")
    sign_in_as("student", "password123")
    with_apkg(builder, "css-deck") do |path|
      visit decks_path
      click_on "Import .apkg"
      attach_file "file", path
      click_submit("Import")
    end

    click_on "Study"
    assert_selector "#study-card-css", visible: :all
    css = page.evaluate_script("document.getElementById('study-card-css').textContent")
    assert_includes css, ".card { color: red; }"
    # The payload is stored as inert text inside the style element and never runs.
    assert_nil page.evaluate_script("window.__cssXss")
  end
end
