# frozen_string_literal: true

require_relative "lib/lain/version"

Gem::Specification.new do |spec|
  spec.name = "lain"
  spec.version = Lain::VERSION
  spec.authors = ["Joel Johnson"]
  spec.email = ["johnson.joel.b@gmail.com"]

  spec.summary = "An agent harness built as a study bench for LLM orchestration and tool design."
  spec.description = <<~DESC
    Lain is a hand-rolled agentic loop for Claude, built so that context strategies, tool
    designs, and orchestration tactics are swappable, observable, and comparable. Conversations
    are a content-addressed Merkle DAG, so forking and time-travel are cheap and prompt-cache
    breaks are localizable. Tool calls are effects interpreted by a composable Rack-style
    middleware stack, so deterministic replay is just a recorded handler. It ships a bench that
    replays recorded sessions under different strategies and reports distributions, not anecdotes.
  DESC
  spec.homepage = "https://github.com/joeljohnson/lain"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.required_rubygems_version = ">= 3.3.11"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/lain/extconf.rb"]

  # ActiveModel brings declarative validations (and ActiveSupport's core
  # extensions with it). Used for tool-input *shape*. Note: validations are not a
  # security boundary -- a regex over a shell string loses to $(), backticks, and
  # ${IFS}. Safety comes from structured tools, the approval gate, and OS
  # confinement, never from a format validator.
  spec.add_dependency "activemodel", "~> 8.0"
  # The official SDK is kept as a correctness ORACLE, not as the default path: the
  # forked transport is byte-diffed against `Provider::Anthropic#encode`, and one
  # live differential run must produce an identical Lain::Response. It is retired
  # only once the forked path has held. Retiring it costs us the dry-diff.
  spec.add_dependency "anthropic", "~> 1.55"
  # The transport. Lain forks RubyLLM's HTTP layer (see lib/lain/provider/http/),
  # so Faraday is ours directly. The adapter is pinned rather than inferred, because
  # a bench that silently changed its HTTP client would silently change its timings.
  spec.add_dependency "faraday", "~> 2.14"
  spec.add_dependency "faraday-net_http", "~> 3.4"
  # Not merely a retry: pointed at Anthropic's `anthropic-ratelimit-*-reset` headers
  # it IS the rate limiter, and its `retry_block` / `exhausted_retries_block` make
  # retries visible to the Journal. A silent retry hides real spend that never
  # appears in Usage -- on a bench whose headline metric is token cost, that gap
  # must be visible, not eliminated.
  spec.add_dependency "faraday-retry", "~> 2.4"
  # Chef's Mixlib::ShellOut. Handles stdout/stderr capture, environment, cwd, timeout,
  # and live_stdout/live_stderr streaming for the `bash` tool. It is not a sandbox --
  # isolation arrives later via the out-of-process Rust exec boundary.
  spec.add_dependency "mixlib-shellout", "~> 3.4"
  # Terminal primitives for Frontend::TTY. `reline` (stdlib) does line editing and
  # history. Only the frontend may touch the terminal; see spec/output_discipline_spec.rb.
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "rb_sys", "~> 0.9.91"
  # Declarative state machines. Chosen over `statesman`, which is built around a
  # persisted transition store -- the Timeline already is one, content-addressed
  # and replayable, and a second would only diverge from it.
  spec.add_dependency "state_machines", "~> 0.201"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "tty-cursor", "~> 0.7"
  spec.add_dependency "tty-screen", "~> 0.8"

  # `ruby_llm` is deliberately NOT a dependency, optional or otherwise.
  #
  # We vendor a slice of its HTTP layer instead (lib/lain/provider/http/, MIT,
  # (c) 2025 Carmine Paolino -- see VENDOR.md). Depending on it was tried and
  # reversed: `parse_completion_response` joins all text blocks into one String,
  # joins all thinking blocks, and keeps only the FIRST thinking block's signature.
  # Correctness gate 1 requires committing every content block, and extended-thinking
  # signatures must be echoed back verbatim. That cannot be satisfied through their
  # Message. We emit Lain::Response instead.
end
