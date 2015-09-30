source 'https://rubygems.org'

gem 'rails'
gem 'activeresource'

gem 'cassandra-driver'

gem 'bson_ext'
gem 'rinruby'

gem "colorize"

# Gems used only for assets and not required
# in production environments by default.
group :assets do
  gem 'sass-rails'
  gem 'coffee-rails'

  # See https://github.com/sstephenson/execjs#readme for more supported runtimes
  gem 'therubyracer', :platforms => :ruby

  gem 'uglifier'
end

gem 'jquery-rails'

# To use ActiveModel has_secure_password
# gem 'bcrypt-ruby', '~> 3.0.0'

# To use Jbuilder templates for JSON
gem 'jbuilder'

# Use unicorn as the app server
# gem 'unicorn'

# Deploy with Capistrano
# gem 'capistrano'

# To use debugger
# gem 'debugger'

gem "kaminari"
gem "haml"
gem 'unicorn'
# dependence on debugger that's not supported
gem 'gmail', github: 'johnnyshields/gmail'
gem 'faraday'
gem 'faraday_middleware'
gem 'net-http-persistent'
gem 'multi_json'
gem 'oj'
gem 'execjs'
gem 'capybara'
gem 'selenium-webdriver'
gem 'capybara-webkit'
gem 'sidekiq'
# if you require 'sinatra' you get the DSL extended to Object
gem 'sinatra', '>= 1.3.0', :require => false
gem "mechanize"
gem "nokogiri"

gem "redis"
gem "hiredis"

gem 'whenever', :require => false

gem 'descriptive_statistics'
gem 'ruby-prof'

gem 'devise'

group :development, :test do
  gem 'rspec-rails'
  gem 'factory_girl'
  gem 'pry'
  gem 'jazz_hands', github: 'nixme/jazz_hands', branch: 'bring-your-own-debugger'
  gem 'pry-byebug'
end
