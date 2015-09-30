Sidekiq.configure_server do |config|
  config.redis = { :url => 'localhost', :namespace => 'sunlight' }
end

Sidekiq.configure_client do |config|
  config.redis = { :url => 'localhost', :namespace => 'sunlight' }
end
