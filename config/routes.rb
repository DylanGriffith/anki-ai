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

  resources :decks, only: [ :index, :new, :create, :show, :destroy ] do
    member do
      get "media/:filename", to: "decks/media#show", as: :media, constraints: { filename: %r{[^/]+} }
    end
  end
end
