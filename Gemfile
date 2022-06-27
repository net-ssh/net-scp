source 'https://rubygems.org'

# Specify your gem's dependencies in mygem.gemspec
gemspec

# TODO: add to gemspec
gem "bundler", ">= 1.11", "< 3"
gem "rake", "~> 12.0"

gem "jeweler", group: %i[development test]
gem "test-unit", group: %i[development test]
gem "mocha", group: %i[development test]
gem "net-ssh", group: %i[development test]

gem 'byebug', group: %i[development test] if !Gem.win_platform? && RUBY_ENGINE == "ruby"

if ENV["CI"]
  gem 'codecov', require: false, group: :test
  gem 'simplecov', require: false, group: :test
end
