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

  spec.add_dependency "anthropic", "~> 1.55"
  spec.add_dependency "rb_sys", "~> 0.9.91"
  spec.add_dependency "thor", "~> 1.3"

  # `ruby_llm` is a SUPPORTED OPTIONAL dependency, deliberately not declared here.
  #
  # Lain::Provider::RubyLLM requires it lazily and raises a helpful LoadError when absent.
  # Declaring it as a hard dependency would force it on every user of the Anthropic path,
  # which is the reference implementation. To use the multi-provider path:
  #
  #     gem install ruby_llm
  #
  # See README.md, "Providers".
end
