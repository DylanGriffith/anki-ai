Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots without any exceptions, or 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root "decks#index"

  get  "login" => "sessions#new", as: :login
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout

  # Import routes must precede resources so "import" is not matched as an id.
  get  "decks/import" => "decks#import_form", as: :import_decks_form
  post "decks/import" => "decks#import", as: :import_decks
  get  "decks/browse" => "decks#browse", as: :browse_decks

  # Offline sync: idempotent batch of client-generated review ops.
  post "sync", to: "sync#create"

  # AI deck generation: the form enqueues a job; the status page polls.
  # The deck-scoped pair below is "add AI cards to an existing deck".
  namespace :ai do
    resources :generations, only: [ :new, :create, :show ]
  end
  get  "decks/:deck_id/ai_cards/new", to: "ai/generations#new", as: :new_deck_ai_cards
  post "decks/:deck_id/ai_cards", to: "ai/generations#create", as: :deck_ai_cards

  resources :decks, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    member do
      get "media/:filename", to: "decks/media#show", as: :media, constraints: { filename: %r{[^/]+} }
      get "study", to: "decks/study#show", as: :study
      get "cards", to: "decks/cards#index", as: :cards
      get "cards/new", to: "decks/cards#new", as: :new_card
      post "cards", to: "decks/cards#create", as: :create_card
      get "export", to: "decks#export", as: :export
    end
  end
end
