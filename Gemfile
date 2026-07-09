# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in lain.gemspec
gemspec

gem "rake", "~> 13.0"
gem "rake-compiler"

group :development do
  gem "debug", "~> 1.11"  # rdbg --open, for stepping the agent loop from another pane
  gem "irb"
  gem "neovim", "~> 0.10" # msgpack-RPC frontend (M4)
  gem "rubocop", "~> 1.21"
end

group :test do
  gem "rantly", "~> 3.0" # property tests for the algebra: monoid/semilattice laws
  gem "rspec", "~> 3.0"
  gem "webmock", "~> 3.0" # HTTP isolation for unit specs; integration specs hit the real API
end

# `ruby_llm` is an optional runtime dependency of the gem (see lain.gemspec), but we
# install it in development so the provider-parity suite can exercise both providers.
group :development, :test do
  gem "ruby_llm", "~> 1.16"
end
