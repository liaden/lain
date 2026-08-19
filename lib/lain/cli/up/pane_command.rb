# frozen_string_literal: true

require "rbconfig"
require "shellwords"

module Lain
  module CLI
    class Up
      # The one recipe for a command a tmux pane can run: the environment a
      # pane does NOT inherit, then an exec of the launching binary.
      #
      # Its own object because that is a different question from {Up}'s. Up
      # knows tmux -- sessions, windows, options, when to attach. This knows
      # what a spawned pane is missing and how to hand it back safely, which is
      # a question about environments and shell quoting that Up never asks. The
      # split is also what lets `/fork`'s window and `/btw`'s popup share the
      # recipe without depending on session management.
      #
      # Every value is read from the LAUNCHING process at call time, never
      # pinned as a literal, and every one of them is Shellwords-escaped: tmux
      # interprets this string with its OWN `$SHELL -c`, so this is the
      # shell boundary {Up}'s class comment promises nothing crosses unescaped.
      class PaneCommand
        # The environment {.lain_exports} carries into a pane: every name
        # {EnvDefaults} reads, and only those. Sorted, so the exported preamble
        # is byte-stable across runs for the same reason {Canonical} sorts keys.
        # `up_spec` re-derives this list from exe/lain and fails on drift -- a
        # new env-backed flag that never reached a pane would be invisible.
        PANE_ENV = %w[
          LAIN_API_BASE LAIN_MAX_TOKENS LAIN_MODEL LAIN_NUM_BATCH LAIN_NUM_CTX
          LAIN_PROVIDER LAIN_SEED
          LAIN_SUMMARIZER_MAX_TOKENS LAIN_SUMMARIZER_MODEL LAIN_SUMMARIZER_PROVIDER
          LAIN_TEMPERATURE
        ].freeze

        # Names lain sets on ITSELF that a pane must never inherit. The
        # counterpart to {PANE_ENV}, and the harder direction: that list is
        # about values a pane is missing, this one about a value a pane would
        # be poisoned by.
        #
        # {ChatLaunch::PREFLIGHT_ENV} turns a `lain chat` into a construction
        # check that exits without conversing. `lain up` sets it on the child
        # it runs deliberately -- but a variable is inherited by everything
        # downstream of wherever it was set, and a tmux SERVER hands its own
        # environment to every pane it spawns. Measured: a pane on a server
        # started with LAIN_PREFLIGHT=1 reads back `1`. The chat pane then
        # pre-flighted instead of chatting and exited 0, which
        # `remain-on-exit failed` does not hold, so the window, the session and
        # the server went with it and nothing was printed anywhere -- a worse
        # failure than the dead-pane banner the pre-flight exists to route
        # around, because the banner at least eats only one line.
        #
        # Scrubbed here rather than on `lain up`'s own `new-session`, because
        # here is strictly stronger: scrubbing the server lain starts protects
        # only servers lain started, while a pane command scrubs its own line
        # whatever server it lands on -- including one already poisoned before
        # `lain up` ran.
        #
        # A method rather than a constant, and that is load order rather than
        # taste: `lain.rb` requires this subtree with {Up}, ahead of
        # {ChatLaunch}, so a constant body would resolve the name at load time
        # and die. Read at call time it is still the one authority, named once.
        #
        # @return [Array<String>] the variables, in unset order
        def self.scrubbed = [ChatLaunch::PREFLIGHT_ENV].freeze

        # @return [String] the `unset` preamble, first thing on the line
        def self.scrubs = scrubbed.map { |name| "unset #{name}; " }.join

        # Composed per call, never a constant, because `$PROGRAM_NAME` must be
        # read when the exe runs (under rspec it is not the lain binary).
        # Callers: `lain up`'s chat window, its cockpit panes, /fork's window
        # and /btw's popup.
        def self.call(*argv)
          "#{scrubs}#{gem_exports}#{lain_exports}exec #{$PROGRAM_NAME} #{Shellwords.join(argv)}"
        end

        # PATH alone is HALF a chruby, and the missing half is what made `lain
        # up` die instantly on macOS (2026-08-05, exit 7 in the chat pane):
        # `Bundler::GemNotFound` listing every gem in the Gemfile as missing.
        #
        # A pane inherits the tmux SERVER's environment, and the server outlives
        # the shell that started it -- so a server first started before chruby
        # ran (or from any shell that never sourced it) hands every later pane an
        # environment with no GEM_HOME, no matter how clean the iTerm window that
        # typed `lain up` was. Re-exporting PATH then finds the right `ruby`
        # binary, and that ruby computes its OWN default `Gem.dir` --
        # `~/.gem/ruby/4.0.0`, keyed on the ABI version, not the `4.0.6` chruby
        # points at. That directory exists and is empty, so `bundler/setup`
        # resolves nothing and the pane is dead before the frontend draws.
        #
        # Read live from the launching process: these are whatever actually
        # resolved the gems that got us here, including a `bundle config path`
        # vendor directory, so a pane lands in the same bundle its parent did.
        # Both come off the ONE `Gem.paths` rather than pairing it with
        # `Gem.path` -- that is its own delegate (`rubygems.rb`: `Gem.path` is
        # `Gem.paths.path`), and reading the pair from one object is what keeps
        # home and path from ever disagreeing.
        #
        # The bindir is read from `RbConfig.ruby` (the RUNNING interpreter),
        # never a pinned version literal -- CLAUDE.md's toolchain note is
        # explicit that the pinned version is a moving floor (4.0.5 -> 4.0.6
        # already happened once for a Ractor VM crash), and a spawned pane must
        # always land on whatever ruby actually launched it.
        #
        # UNquoted and Shellwords-escaped, not wrapped in `"..."` --
        # Shellwords.escape's backslashes are only correct as a bare shell word;
        # nested inside double quotes, a backslash before anything but dollar,
        # backtick, double-quote or backslash stops being an escape and becomes
        # a literal character in PATH.
        def self.gem_exports
          paths = Gem.paths
          ["PATH=#{Shellwords.escape(File.dirname(RbConfig.ruby))}:$PATH",
           "GEM_HOME=#{Shellwords.escape(paths.home)}",
           "GEM_PATH=#{Shellwords.escape(paths.path.join(File::PATH_SEPARATOR))}"]
            .map { |assignment| "export #{assignment}; " }.join
        end

        # The same stale-server trap {.gem_exports} documents, applied to the
        # flag defaults {EnvDefaults} reads -- and here it is strictly worse. A
        # pane runs under tmux's `$SHELL -c`, which is NON-interactive: zsh reads
        # `.zshenv` and never `.zshrc`, so direnv's hook does not run and the
        # pane cannot re-derive these for itself. Without this, `lain up` from a
        # directory direnv has pinned gets a chat on whatever the tmux SERVER was
        # started with -- which is the bug c69de39 ("read the endpoint from the
        # environment, so direnv can pin a project's model") was meant to fix
        # everywhere but panes.
        #
        # Measured 2026-08-06: a pane on a pre-existing server read an EMPTY
        # value even when the variable was set on the `tmux new-window`
        # invocation itself, because tmux hands a pane the SERVER's environment
        # rather than the client's -- there is no pushing one in at spawn time.
        #
        # An explicit allowlist, NOT a `LAIN_` prefix sweep. The prefix is shared
        # with the suite's own controls -- LAIN_OLLAMA, LAIN_INTEGRATION,
        # LAIN_LIVE, LAIN_SPIKE, LAIN_NVIM, LAIN_SPEC_BUDGET -- which are set on
        # exactly the developer machines that also run `lain up`, so a sweep
        # would hand a live chat pane the test wiring of whoever launched it.
        #
        # Deliberately no ANTHROPIC_API_KEY. A pane command is readable from
        # `tmux list-panes -F '#{pane_start_command}'` and from the process
        # table, so a secret exported here would be legible to every process on
        # the box. These are flag defaults, not credentials; a key belongs in the
        # environment the tmux server is started from.
        def self.lain_exports(env = ENV)
          PANE_ENV.filter_map do |name|
            value = env[name]
            "export #{name}=#{Shellwords.escape(value)}; " unless value.to_s.strip.empty?
          end.join
        end
      end
    end
  end
end
