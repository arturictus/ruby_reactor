Rails.application.routes.draw do
  post 'webhooks/receive', to: 'webhooks#receive'
  resources :reactors, only: [:index, :show, :create, :update]
  mount RubyReactor::Web::Application => '/ruby_reactor'
end
