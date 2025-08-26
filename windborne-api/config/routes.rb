# Rails.application.routes.draw do
#   # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

#   # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
#   # Can be used by load balancers and uptime monitors to verify that the app is live.
#   get "up" => "rails/health#show", as: :rails_health_check

#   # Defines the root path route ("/")
#   # root "posts#index"
# end
Rails.application.routes.draw do
  match "/healthz", to: proc { [200, {"Content-Type"=>"text/plain"}, ["ok"]] }, via: [:get, :head]
  get "/", to: proc {
    body = { name: "WindBorne API",
             endpoints: ["/api/constellation?no_meteo=1", "/api/constellation?meteo_cap=40"],
             status: "ok" }.to_json
    [200, {"Content-Type"=>"application/json"}, [body]]
  }
  namespace :api, defaults: { format: :json } do
    get "constellation", to: "constellation#index"
  end
end
