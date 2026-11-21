Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots without any exceptions, or 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root "decks#index"

  get  "login"  => "sessions#new",     as: :login
  post "login"  => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout

  resources :decks, only: [ :index, :new, :create, :show, :destroy ]
end
