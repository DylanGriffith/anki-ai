require "application_system_test_case"

class LoginDecksTest < ApplicationSystemTestCase
  test "login, create a deck, and sign out" do
    User.create!(name: "dylan", password: "password123")

    # Root requires login
    visit root_path
    assert_selector "h1", text: "Sign in"
    evidence("step1_login_page")

    # Wrong password is rejected
    fill_in "Username", with: "dylan"
    fill_in "Password", with: "nope-wrong"
    click_on "Sign in"
    assert_text "Invalid name or password."
    assert_selector "h1", text: "Sign in"

    # Correct password signs in and lands on empty deck list
    fill_in "Password", with: "password123"
    click_on "Sign in"
    assert_selector "h1", text: "Decks"
    assert_text "No decks yet."
    evidence("step1_empty_decks")

    # Create a deck
    click_on "New deck"
    fill_in "Name", with: "Japanese Vocabulary"
    fill_in "Description", with: "Core words from Genki I"
    click_on "Create deck"
    assert_selector "h1", text: "Japanese Vocabulary"
    assert_text "private"
    assert_text "Daily limits: 20 new, 200 reviews."
    evidence("step1_deck_created")

    # Deck shows in the list
    visit decks_path
    assert_selector ".deck-list li", text: "Japanese Vocabulary"
    evidence("step1_deck_list")

    # Sign out returns to login
    click_on "Sign out"
    assert_selector "h1", text: "Sign in"
  end

  test "cannot access decks without logging in" do
    visit decks_path
    assert_selector "h1", text: "Sign in"
  end
end
