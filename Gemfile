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
  gem "rubocop", "~> 1.21"
  gem "rubocop-performance", "~> 1.25"
  gem "rubocop-rake", "~> 0.7"
  gem "rubocop-rspec", "~> 3.7"
  # Keeps the doc comments honest against the code they document. `MismatchName` is
  # the one that earns it: a `@param` naming a parameter that has since been renamed
  # is a doc that reads as authoritative and is wrong, and nothing else we run sees it
  # -- plain RuboCop does not parse docstrings, and `yard stats` counts coverage, not
  # agreement.
  gem "rubocop-yard", "~> 1.3"
  # The one extension that pulls its weight beyond style: we run Ractors, an async
  # out-of-process core, and parallel_tests. `ClassInstanceVariable` and
  # `MutableClassInstanceVariable` catch the shared-mutable-state bugs that
  # `Ractor.shareable?` asserts against -- statically, at every site, rather than at
  # the one a spec thought to check.
  gem "rubocop-thread_safety", "~> 0.7"
  # Renders the Agent's state machine to mermaid SOURCE text (no Node toolchain: the
  # renderer is pure Ruby). A spec regenerates it and diffs it against the committed
  # README block, because a checked-in diagram that silently diverges from the code is
  # worse than no diagram.
  gem "state_machines-mermaid", "~> 0.1"
  gem "yard", "~> 0.9" # our doc comments are already YARD-shaped (@param, @return)
end

group :test do
  # The correctness ORACLES, and nothing else: `Provider::AnthropicRaw` and
  # `Provider::BedrockRaw` carry both hosted paths over the vendored Faraday
  # transport, and are byte-diffed against the official SDK's `#encode` by the
  # parity specs. The oracle classes live in spec/support/provider_oracles/, so
  # a `gem install lain` never fetches or loads either of these.
  #
  # aws-sdk-core rides along because the SDK's BedrockMantleClient requires it
  # eagerly, BEFORE branching on auth mode -- even bearer-token auth, which
  # never touches SigV4, cannot construct a client without it.
  gem "anthropic", "~> 1.55"
  gem "aws-sdk-core", "~> 3"
  # `rake pspec` / pre-commit: one worker per core over a suite that is
  # parallel-safe by construction (tmpdirs, per-pid sockets, injected env).
  # Roughly halves the wall clock every commit hook pays.
  gem "parallel_tests", "~> 5.0"
  gem "rantly", "~> 3.0" # property tests for the algebra: monoid/semilattice laws
  gem "rspec", "~> 3.0"
  # Suite profiling lenses, dormant until their env vars ask: TEST_STACK_PROF=1
  # (flamegraphs, via stackprof), TAG_PROF=type, EVENT_PROF=... -- required from
  # spec_helper, a no-op on a plain run.
  gem "stackprof", "~> 0.2"
  gem "test-prof", "~> 1.4"
  # ActiveModel validation matchers; integrated :rspec + :active_model only (no Rails).
  gem "shoulda-matchers", "~> 6.0"
  # A REVIEW LENS, NEVER A GATE. Used while reviewing a branch to find untested
  # branches -- error paths, the `else` on a stop_reason case. No minimum-coverage
  # threshold is committed: in a codebase whose invariants are property-tested, a
  # coverage number is reassurance, not evidence.
  gem "simplecov", "~> 0.22", require: false
  # Structural diffs on failure output only -- never changes matching semantics.
  gem "super_diff", "~> 0.16"
  # Hooks into the webmock we already have. Configured in spec/support/ with safe
  # defaults: network blocked, `record: :none`, LAIN_RECORD=1 to record.
  gem "vcr", "~> 6.4"
  gem "webmock", "~> 3.0" # HTTP isolation for unit specs; integration specs hit the real API
end

group :development, :test do
  # Iseq/load-path caching for the suite AND its fresh-ruby subprocess boots
  # (the prelude invariant spec pays a full `require "lain"` per run). Setup is
  # spec/bootsnap_setup.rb -- the top of spec_helper and the subprocess both
  # require it before "lain"; the cache lives under gitignored tmp/cache.
  gem "bootsnap", "~> 1.18"
  # Loads ANTHROPIC_API_KEY from a gitignored .env, so the key never enters the shell
  # profile -- where Claude Code would silently prefer it over the subscription.
  gem "dotenv", "~> 3.2"
end
