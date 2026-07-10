# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in lain.gemspec
gemspec

gem "rake", "~> 13.0"
gem "rake-compiler"

group :development do
  gem "benchmark-ips", "~> 2.15" # M4 claims fork is O(1) and that Rust beats Ruby; claims get measured
  gem "debug", "~> 1.11"         # rdbg --open, for stepping the agent loop from another pane
  gem "irb"
  gem "neovim", "~> 0.10" # msgpack-RPC frontend (M4)
  gem "rubocop", "~> 1.21"
  # Renders the Agent's state machine to mermaid SOURCE text (no Node toolchain: the
  # renderer is pure Ruby). A spec regenerates it and diffs it against the committed
  # README block, because a checked-in diagram that silently diverges from the code is
  # worse than no diagram.
  gem "state_machines-mermaid", "~> 0.1"
  gem "yard", "~> 0.9" # our doc comments are already YARD-shaped (@param, @return)
end

group :test do
  gem "rantly", "~> 3.0" # property tests for the algebra: monoid/semilattice laws
  gem "rspec", "~> 3.0"
  # A REVIEW LENS, NEVER A GATE. Used while reviewing a branch to find untested
  # branches -- error paths, the `else` on a stop_reason case. No minimum-coverage
  # threshold is committed: in a codebase whose invariants are property-tested, a
  # coverage number is reassurance, not evidence.
  gem "simplecov", "~> 0.22", require: false
  # Hooks into the webmock we already have. Configured in spec/support/ with safe
  # defaults: network blocked, `record: :none`, LAIN_RECORD=1 to record.
  gem "vcr", "~> 6.4"
  gem "webmock", "~> 3.0" # HTTP isolation for unit specs; integration specs hit the real API
end

group :development, :test do
  # Loads ANTHROPIC_API_KEY from a gitignored .env, so the key never enters the shell
  # profile -- where Claude Code would silently prefer it over the subscription.
  gem "dotenv", "~> 3.2"
end
