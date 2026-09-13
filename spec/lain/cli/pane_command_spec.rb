# frozen_string_literal: true

require "open3"
require "rbconfig"

# The PATH/`--` argv split and the `--root`/`--cwd` flags are Thor's work, so
# `up_spec.rb` loads `exe/lain` for its own examples; this file only needs the
# EnvDefaults drift check below, which reads `exe/lain` as text rather than
# running it.

# {Lain::CLI::PaneCommand} -- the one recipe for a command a tmux pane can
# run, promoted out of {Lain::CLI::Up} because it has three production callers
# outside it: `Up`'s own default chat command and cockpit split pane, /fork's
# window, /btw's popup, and {Lain::CLI::FleetWindows}. {Lain::CLI::Up::Cockpit}
# and {Lain::CLI::Up::Hud} stay Up's children, exercised through `up_spec.rb`
# the way `up_spec.rb:646-655`'s comment records -- this class is the opposite
# case, so its examples live here instead.
RSpec.describe Lain::CLI::PaneCommand do
  describe ".call" do
    # The LAIN_ preamble is delegated rather than spelled out: it reads the
    # REAL environment, and this suite's own runner legitimately sets
    # LAIN_-prefixed variables, so a literal here would pass or fail depending
    # on how the developer invoked rspec. {.lain_exports} has its own examples
    # below, which drive an injected env and pin the bytes.
    it "composes the env re-exports, the launching binary, and the escaped argv" do
      expect(described_class.call("chat", "--fork", "a b"))
        .to eq("#{described_class.scrubs}" \
               "export PATH=#{File.dirname(RbConfig.ruby)}:$PATH; " \
               "export GEM_HOME=#{Gem.paths.home}; " \
               "export GEM_PATH=#{Gem.path.join(File::PATH_SEPARATOR)}; " \
               "#{described_class.lain_exports}exec #{$PROGRAM_NAME} chat --fork a\\ b")
    end

    # The blocker: `lain up` runs its pre-flight by exporting LAIN_PREFLIGHT
    # into a child, and a variable is inherited by everything downstream of
    # wherever it was set. A tmux SERVER carries it to every pane it spawns
    # (measured), so the chat pane pre-flighted instead of chatting, exited 0
    # -- which `remain-on-exit failed` does not hold -- and took the window,
    # the session and the server with it, saying nothing anywhere.
    #
    # Scrubbed HERE rather than on `new-session`, and that is the stronger
    # place: scrubbing the server lain starts protects only servers lain
    # started, while a pane command scrubs its own line whatever server it
    # lands on -- including one already tainted before `lain up` ran. /fork's
    # window and /btw's popup share the recipe, so they are covered too.
    #
    # Driven through a REAL `sh -c` with the variable exported, because what
    # is under test is what the pane's own shell does with the line, not what
    # the line looks like.
    it "unsets a stray LAIN_PREFLIGHT before the pane execs, so no pane ever runs as a pre-flight" do
      out, = Open3.capture3({ "LAIN_PREFLIGHT" => "1" }, "sh", "-c",
                            "#{described_class.scrubs}printenv LAIN_PREFLIGHT; echo status=$?")

      expect(out).to eq("status=1\n")
    end

    it "puts the scrub AHEAD of the exec, where it can still take effect" do
      expect(described_class.call("chat")).to start_with(described_class.scrubs)
    end

    # The regression this pair exists for, and the reason PATH alone was not
    # enough: a tmux SERVER outlives the shell that started it, so a pane can
    # inherit an environment with no GEM_HOME however clean the window that
    # typed `lain up` was. The re-exported PATH then finds the right ruby, and
    # that ruby defaults Gem.dir to the ABI-keyed `~/.gem/ruby/4.0.0` rather
    # than chruby's `4.0.6` -- an empty directory, so `bundler/setup` resolves
    # nothing and the pane dies in Bundler::GemNotFound with every gem named.
    # Observed on macOS 2026-08-05: `lain up` created the session and the chat
    # pane was dead (exit 7) before the frontend drew a frame.
    it "re-exports GEM_HOME and GEM_PATH, which a tmux server started before chruby does not carry" do
      command = described_class.call("chat")

      expect(command).to include("export GEM_HOME=#{Gem.paths.home}; ")
      expect(command).to include("export GEM_PATH=#{Gem.path.join(File::PATH_SEPARATOR)}; ")
    end

    # Same argument as the RbConfig.ruby stub below: the example above cannot
    # tell a live read from a literal that happens to match this box today. A
    # `bundle config path` vendor directory is the case that makes it matter --
    # the pane must land in the bundle its PARENT resolved, not in whatever the
    # spawned ruby would pick for itself.
    it "follows Gem.paths.home when it changes -- proving the gem home is read live" do
      allow(Gem).to receive(:paths)
        .and_return(instance_double(Gem::PathSupport, home: "/opt/vendor/bundle", path: ["/opt/vendor/bundle"]))

      expect(described_class.call("chat")).to include("export GEM_HOME=/opt/vendor/bundle; ")
    end

    # The pane's own `$SHELL -c` reads these, so a directory with a space in it
    # would split into two words and export a truncated GEM_HOME -- silently,
    # into the same Bundler::GemNotFound the whole fix is about.
    it "escapes a gem home containing a space, since tmux hands the line to a shell" do
      allow(Gem).to receive(:paths)
        .and_return(instance_double(Gem::PathSupport, home: "/opt/my bundle", path: ["/opt/my bundle"]))

      expect(described_class.call("chat")).to include('export GEM_HOME=/opt/my\ bundle; ')
    end

    # Not a general /ruby-\d+\.\d+\.\d+/ refusal -- RbConfig.ruby's bindir on
    # a ruby-install layout (this box, and CLAUDE.md's own toolchain note)
    # IS named "ruby-4.0.6", so a correct derivation legitimately contains a
    # version-shaped path segment. What must never reappear is the STALE
    # literal this fix removes.
    it "carries no stale hardcoded ruby-4.0.5 pin -- it re-exports the RUNNING interpreter's bindir" do
      expect(described_class.call("chat")).not_to include("ruby-4.0.5")
      expect(described_class.call("chat")).to include(File.dirname(RbConfig.ruby))
    end

    # The example above can't tell "derived live" from "a second hardcoded
    # literal that happens to match today's interpreter" -- a future
    # regression to a fresh pin (say "ruby-4.0.7") would sail through it
    # unnoticed. Stubbing RbConfig.ruby to an interpreter that could never be
    # this box's real one, and asserting the command follows the stub, is the
    # only way to prove the read is live rather than baked in.
    it "follows RbConfig.ruby when it changes -- proving the bindir is read live, not baked in" do
      allow(RbConfig).to receive(:ruby).and_return("/opt/totally-fake-ruby-9.9.9/bin/ruby")

      expect(described_class.call("chat")).to include("/opt/totally-fake-ruby-9.9.9/bin")
    end
  end

  # The direnv half of the same stale-server story GEM_HOME told, and a worse
  # one: a pane's `$SHELL -c` is NON-interactive, so zsh reads .zshenv and
  # never .zshrc, direnv's hook never fires, and the pane cannot re-derive
  # these for itself. Measured 2026-08-06 -- a pane on a pre-existing server
  # read an EMPTY value even with the variable set on the `tmux new-window`
  # call, because tmux hands a pane the SERVER's environment, not the client's.
  describe ".lain_exports" do
    it "carries the flag defaults direnv pinned, escaped and in a stable order" do
      env = { "LAIN_PROVIDER" => "ollama", "LAIN_MODEL" => "qwen3:4b" }

      expect(described_class.lain_exports(env))
        .to eq("export LAIN_MODEL=qwen3:4b; export LAIN_PROVIDER=ollama; ")
    end

    it "omits a name that is unset or blank, rather than exporting an empty string over it" do
      expect(described_class.lain_exports({ "LAIN_PROVIDER" => "", "LAIN_MODEL" => nil })).to eq("")
    end

    it "escapes a value the pane's shell would otherwise re-interpret" do
      expect(described_class.lain_exports({ "LAIN_MODEL" => "a b; touch /tmp/pwned" }))
        .to eq('export LAIN_MODEL=a\ b\;\ touch\ /tmp/pwned; ')
    end

    # The prefix is shared with this suite's own controls, and those are set on
    # exactly the machines that also run `lain up` -- a sweep would hand a live
    # chat pane the test wiring of whoever launched it.
    it "ignores LAIN_ names that are suite controls, not flag defaults" do
      env = { "LAIN_OLLAMA" => "1", "LAIN_INTEGRATION" => "1", "LAIN_NVIM" => "0", "LAIN_SPEC_BUDGET" => "30" }

      expect(described_class.lain_exports(env)).to eq("")
    end

    # Never a secret: a pane command is readable from `tmux list-panes` and the
    # process table, so an exported key would be legible to every process on
    # the box. This is the example that fails if someone "fixes" a missing-key
    # crash by forwarding the credential.
    it "never carries an API key into a command line the process table can read" do
      env = { "ANTHROPIC_API_KEY" => "sk-ant-secret", "AWS_SECRET_ACCESS_KEY" => "shh" }

      expect(described_class.lain_exports(env)).to eq("")
      expect(described_class::PANE_ENV).to all(start_with("LAIN_"))
    end

    # PANE_ENV is a hand-maintained list against a set that grows in ANOTHER
    # file, and the failure is silent: a new env-backed flag simply stops
    # reaching panes, which looks exactly like the direnv bug this fixes. So
    # re-derive the truth from exe/lain rather than trusting the copy.
    it "lists every name EnvDefaults actually reads -- no drift against exe/lain" do
      declared = File.read(File.expand_path("../../../exe/lain", __dir__))
                     .scan(/EnvDefaults\.(?:string|numeric)\(\s*"(LAIN_[A-Z_]+)"/).flatten.uniq

      expect(declared).not_to be_empty
      expect(described_class::PANE_ENV).to match_array(declared)
    end

    # The desktop notifier LAIN_DESKTOP was the consent for is deleted, so the
    # name has no reader anywhere in the tree and a pane exporting it would be
    # carrying a variable nothing consults. The second list went with it, which
    # puts PANE_ENV's exactness against exe/lain -- the drift check above, that a
    # name no `EnvDefaults` call declares would have turned into a list of
    # exceptions -- back to being the whole rule.
    it "keeps ONE list, every name of which exe/lain declares as a flag default" do
      expect(described_class).not_to be_const_defined(:CONSENT_ENV)
      expect(described_class.lain_exports({ "LAIN_DESKTOP" => "0" })).to eq("")
    end
  end
end
