# frozen_string_literal: true

require "rbconfig"
require "shellwords"

module Lain
  module CLI
    class Up
      # The one recipe for a command a tmux pane can run: the environment a pane
      # does NOT inherit, then an exec of the launching binary. Its own object
      # so `/fork`'s window and `/btw`'s popup share the recipe without
      # depending on {Up}'s session management.
      #
      # Every value is read from the LAUNCHING process at call time, never
      # pinned as a literal, and every one is Shellwords-escaped: tmux
      # interprets this string with its OWN `$SHELL -c`, so this is the shell
      # boundary {Up}'s class comment promises nothing crosses unescaped.
      class PaneCommand
        # Every name {EnvDefaults} reads, and only those. Sorted, so the
        # exported preamble is byte-stable across runs. `up_spec` re-derives
        # this list from exe/lain and fails on drift -- a new env-backed flag
        # that never reached a pane would otherwise be invisible -- and that
        # check is an EXACT match, so a name no `EnvDefaults` call declares
        # cannot live here. {CONSENT_ENV} is the one such name.
        PANE_ENV = %w[
          LAIN_API_BASE LAIN_MAX_TOKENS LAIN_MODEL LAIN_NUM_BATCH LAIN_NUM_CTX
          LAIN_PROVIDER LAIN_SEED
          LAIN_SUMMARIZER_MAX_TOKENS LAIN_SUMMARIZER_MODEL LAIN_SUMMARIZER_PROVIDER
          LAIN_TEMPERATURE
        ].freeze

        # Whether this shell may interrupt the human at the desk -- a different
        # question from {PANE_ENV}'s, with a different reader and a different
        # rule, which is why it is a second list. {EnvDefaults} turns PANE_ENV
        # into Thor `default:` values an explicit flag always beats;
        # {Notify.consented?} reads LAIN_DESKTOP itself, where `1` and `0` FORCE
        # past `--desktop` and `--no-desktop` alike. Folding it into the first
        # list would demote a force to an unset-flag default and change what an
        # existing export means, silently.
        #
        # The split is also held by a spec rather than by taste: `up_spec`
        # asserts {PANE_ENV} matches exe/lain EXACTLY, so merging the two would
        # turn that check into a list of exceptions. (The suite's own
        # `EndpointEnv::LEAKS` answers the same question the other way, one
        # list, because nothing pins it against exe/lain.)
        #
        # Carried at all because a pane is where the answer gets lost: a shell
        # that exported LAIN_DESKTOP=0 hands `lain up` nothing, since the pane
        # inherits the tmux SERVER's environment, and the pane's own `--desktop`
        # then defaults ON and fires dunstify at a screen that said no.
        #
        # Exported VERBATIM, never filtered against {Notify::OVERRIDE}: the
        # pane's {Notify.for} must reach the verdict the launching shell's
        # would, and a copy of that grammar here would be a second place to keep
        # in step whose drift changes a pane's consent silently. It follows that
        # a shell exporting `=1` forces notifications ON in every pane it
        # launches -- the same sentence read forwards, worth writing down
        # because a force reaches past the run whoever typed it had in mind.
        CONSENT_ENV = %w[LAIN_DESKTOP].freeze

        # Names lain sets on ITSELF that a pane would be poisoned by.
        # {ChatLaunch::PREFLIGHT_ENV} turns a `lain chat` into a construction
        # check that exits without conversing, and a tmux SERVER hands its own
        # environment to every pane it spawns -- measured: a pane on a server
        # started with LAIN_PREFLIGHT=1 reads back `1`, so the chat pane
        # pre-flighted and exited 0, which `remain-on-exit failed` does not
        # hold, taking the window, the session and the server with it in
        # silence.
        #
        # Scrubbed on the pane command rather than on `lain up`'s own
        # `new-session` because that is strictly stronger: a pane command
        # scrubs its own line whatever server it lands on, including one
        # poisoned before `lain up` ran.
        #
        # A method rather than a constant on load order, not taste: `lain.rb`
        # requires this subtree ahead of {ChatLaunch}, so a constant body would
        # resolve the name at load time and die.
        #
        # @return [Array<String>] the variables, in unset order
        def self.scrubbed = [ChatLaunch::PREFLIGHT_ENV].freeze

        # @return [String] the `unset` preamble, first thing on the line
        def self.scrubs = scrubbed.map { |name| "unset #{name}; " }.join

        # Composed per call, never a constant, because `$PROGRAM_NAME` must be
        # read when the exe runs -- under rspec it is not the lain binary.
        def self.call(*argv)
          "#{scrubs}#{gem_exports}#{lain_exports}exec #{$PROGRAM_NAME} #{Shellwords.join(argv)}"
        end

        # PATH alone is HALF a chruby, and the missing half made `lain up` die
        # instantly on macOS (2026-08-05, exit 7 in the chat pane) with
        # `Bundler::GemNotFound` listing every gem in the Gemfile.
        #
        # A pane inherits the tmux SERVER's environment and the server outlives
        # the shell that started it, so a server first started before chruby ran
        # hands every later pane an environment with no GEM_HOME however clean
        # the window that typed `lain up` was. Re-exporting PATH then finds the
        # right `ruby`, and that ruby computes its OWN default `Gem.dir` --
        # `~/.gem/ruby/4.0.0`, keyed on the ABI version rather than the 4.0.6
        # chruby points at. That directory exists and is empty, so
        # `bundler/setup` resolves nothing and the pane is dead before the
        # frontend draws.
        #
        # Read live from the launching process, so a pane lands in the same
        # bundle its parent did -- a `bundle config path` vendor directory
        # included. Both values come off the ONE `Gem.paths` rather than pairing
        # it with the `Gem.path` delegate, which is what keeps home and path
        # from ever disagreeing. The bindir comes from `RbConfig.ruby`, the
        # RUNNING interpreter, never a pinned version literal: the pin is a
        # moving floor (4.0.5 to 4.0.6 already happened, for a Ractor VM crash).
        #
        # PATH is the one INHERITED name tmux does not take from the server, so
        # the paragraph above is right about the failure and one step off about
        # the mechanism. Re-measured on 3.7b: set a name on the server AND on
        # the client asking for the window, and a pane reads the SERVER's value
        # -- except PATH, which tmux carves out and copies from the CLIENT.
        # (TERM, TMUX and TMUX_PANE answer to neither side: tmux synthesises
        # those, so they are outside the question a caller pushing a variable
        # is asking.) The
        # re-export stays necessary either way, because a client that never ran
        # chruby hands a pane the same half-PATH a stale server does. What the
        # carve-out changes is who else is exposed: a spec is a client, so a
        # pane opened from the suite inherits the RUNNER's PATH and can find a
        # binary production never sees. That trap has its own entry in
        # docs/toolchain-traps.md, because it makes a pane spec pass over a
        # defect.
        #
        # UNquoted and Shellwords-escaped rather than wrapped in double quotes:
        # those backslashes are only correct as a bare shell word, and inside
        # double quotes a backslash before anything but dollar, backtick,
        # double-quote or backslash becomes a literal character in PATH.
        def self.gem_exports
          paths = Gem.paths
          ["PATH=#{Shellwords.escape(File.dirname(RbConfig.ruby))}:$PATH",
           "GEM_HOME=#{Shellwords.escape(paths.home)}",
           "GEM_PATH=#{Shellwords.escape(paths.path.join(File::PATH_SEPARATOR))}"]
            .map { |assignment| "export #{assignment}; " }.join
        end

        # The stale-server trap {.gem_exports} documents, applied to the flag
        # defaults {EnvDefaults} reads, and strictly worse here: a pane runs
        # under tmux's NON-interactive `$SHELL -c`, so zsh reads `.zshenv` and
        # never `.zshrc`, direnv's hook does not run, and the pane cannot
        # re-derive these for itself. Measured 2026-08-06: a pane on a
        # pre-existing server read an EMPTY value even with the variable set on
        # the `tmux new-window` invocation itself, because tmux hands a pane the
        # SERVER's environment rather than the client's -- every name that
        # matters here, PATH being the single carve-out {.gem_exports} now
        # documents. Pushing one in at spawn time is not impossible though,
        # only unavailable through the shell prefix that measurement used:
        # `new-window -e NAME=value` does reach the pane on 3.7b. It still
        # could not replace this line, and the reason is harder than
        # ergonomics: `-e` can only SET. Measured against a server holding
        # LAIN_PREFLIGHT=1, `-e LAIN_PREFLIGHT=` leaves the pane an EMPTY
        # value rather than an unset one, and a bare `-e LAIN_PREFLIGHT` is
        # accepted and ignored -- so {.scrubbed}'s contract, the variables in
        # UNSET order, has no `-e` spelling at all. Not live today, because
        # the one reader tolerates an empty value; the next name added to that
        # list whose reader tests PRESENCE would be silently unscrubbed.
        # Keeping the recipe one opaque string every caller already passes,
        # rather than an argv every tmux surface would grow a parameter for,
        # is then the cheaper half of the answer rather than the whole of it.
        #
        # An explicit allowlist, NOT a `LAIN_` prefix sweep: the prefix is shared
        # with the suite's own controls (LAIN_INTEGRATION, LAIN_LIVE, LAIN_NVIM
        # and their kin), which are set on exactly the developer machines that
        # also run `lain up`, so a sweep would hand a live chat pane the test
        # wiring of whoever launched it.
        #
        # Deliberately no ANTHROPIC_API_KEY: a pane command is readable from
        # `tmux list-panes` and from the process table, so a secret exported
        # here would be legible to every process on the box. A key belongs in
        # the environment the tmux server is started from.
        #
        # Concatenated in a fixed order rather than merged and re-sorted, so the
        # preamble stays byte-stable and a reader of a live `tmux list-panes`
        # line can still see which list a name came from.
        def self.lain_exports(env = ENV)
          (PANE_ENV + CONSENT_ENV).filter_map do |name|
            value = env[name]
            "export #{name}=#{Shellwords.escape(value)}; " unless value.to_s.strip.empty?
          end.join
        end
      end
    end
  end
end
