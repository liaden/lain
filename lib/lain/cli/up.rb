# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # `lain up`: create (idempotently) or attach to the "lain" tmux session and
    # give it the session-scoped HUD -- status-right/status-interval reading the
    # published state file via jq, `monitor-bell` on the chat window.
    #
    # Session-scoped, never global: tmux's session-beats-global inheritance is
    # what keeps the theme plugin's globals untouched, so this needs zero
    # tmux.conf changes. Idempotent because #call probes `has-session` first, so
    # a second `lain up` re-applies the same harmless option writes rather than
    # spawning a duplicate.
    #
    # Every tmux/jq invocation goes through Mixlib::ShellOut with an ARGV array,
    # never a command string, so nothing here quotes against a shell of ours.
    # The ONE place a shell reappears is the `#(...)` job tmux embeds in
    # `status-right` and interprets with its OWN `$SHELL -c` at render time --
    # {Up::Hud} escapes that string for a POSIX shell, not for us.
    class Up
      # tmux missing outright, or any tmux failure other than has-session's
      # expected "no session yet" nonzero. Named so the exe's Lain::Error to
      # Thor::Error mapping shows a clean message rather than a raw Errno or
      # Mixlib backtrace on a demo machine.
      class TmuxUnavailable < Error; end

      # A chat `lain up` will not open a session for, in chat's own words: the
      # message is the child's stderr VERBATIM, so the operator reads exactly
      # what the pane would have shown -- and, unlike the pane, with its first
      # line intact.
      class ChatRefused < Error; end

      # A chat pane that died before `lain up` could attach, in the pane's own
      # words. {ChatRefused} is what `chat` could be ASKED beforehand; this is
      # what only running it reveals. {PaneCorpse} composes the message.
      class ChatDied < Error; end

      # The PATH argument, expanded and checked ONCE. Both panes' tmux `-c`, the
      # nvim socket's hash and the HUD's state file all read this one result: a
      # PATH honoured by only some of them would leave the cockpit in the
      # project the user asked for beside a status bar reading the shell's --
      # and since the feed moved into XDG state, that bar has nothing to read at
      # all rather than something stale.
      class Workdir
        # Refused BY NAME rather than left to tmux, whose answer to `-c <file>`
        # is a pane that dies before anything reaches the screen -- and rather
        # than falling back to the shell's directory, which would open a session
        # somewhere the user did not ask for and say nothing about it.
        class NotADirectory < Error
          def initialize(path)
            super("#{path} is not a directory -- `lain up [PATH]` opens the project directory you name")
          end
        end

        # nil is "wherever the shell is" and yields NO keyword at all, so
        # {Up#initialize}'s own default stays the single place the working
        # directory is read.
        #
        # @param path [String, nil]
        # @return [Hash] the `cwd:` keyword this PATH makes, or none
        # @raise [NotADirectory]
        def self.option(path) = path.nil? ? {} : { cwd: new(path).to_s }

        def initialize(path)
          @path = File.expand_path(path)
          raise NotADirectory, path unless File.directory?(@path)
        end

        def to_s = @path
      end

      DEFAULT_SESSION = "lain"
      CHAT_WINDOW = "chat"

      # The size a CREATED session is built at. tmux sizes a client-less session
      # from `default-size`, 80x24 out of the box, and everything `lain up` does
      # happens before anyone attaches -- the window is opened, split, and nvim
      # boots in the left pane while the exe is still on its way to `attach`. At
      # tmux's default that made the cockpit two 40-column panes, which is what
      # nvim then computes its own layout against.
      #
      # NOT a fix for a break: review reproduced neither half of the claim that
      # 40x24 harms nvim -- `nvim --clean --listen` in a real 40x24 pane serves
      # RPC and answers `&columns` at once (0.12.4), and four `botright vsplit`s
      # succeed at 40 columns with no E36. The hang where an nvim RPC never
      # answered has no established cause and is still open. This widens the
      # session only because a 40-column editor pane is not a usable cockpit.
      #
      # 200x50 rather than a guess at the terminal, because the operator's real
      # client resizes the window on attach (`window-size latest`), so this only
      # has to fit the layout that boots before anyone is there. The invariant
      # is "true at CREATION", not "true whenever detached": once an 80x24
      # client has attached the window stays 80x24, and detaching does not
      # restore this (measured). Harmless, since everything that reads the
      # geometry has already run.
      #
      # `-x`/`-y` on `new-session` is recorded as `default-size` ON THAT SESSION
      # -- measured: a sibling session keeps its own and the server's global
      # stays 80x24 -- so this needs no `-g` write and cannot reach the
      # operator's sessions. That part is ASSERTED as well as measured, because
      # a global write is the one outcome worse than the defect and is invisible
      # to every argv assertion. Nothing states geometry on the REATTACH path
      # either: a session lain did not create may have a human attached, and
      # resizing it would shrink their terminal to fix our layout.
      DETACHED_WIDTH = 200
      DETACHED_HEIGHT = 50

      Report = Data.define(:session, :created, :warnings, :state_path)

      # `created` is what makes a second `lain up` read as "reattaching" rather
      # than "duplicating"; `warnings` carries the jq-missing notice the exe
      # says before attaching, so a degraded HUD is never a silent one.
      class Report
        # The Report's own knowledge: it already carries exactly the two fields
        # that decide the line, so the exe just says what comes back.
        def announcement
          created ? "created tmux session '#{session}'" : "reattaching to '#{session}'"
        end

        # The one place a human is told where the state feed is. The file sits in
        # a directory named by twelve hex characters of a hash, and the degraded
        # HUD line names no path at all -- so without this, nothing anywhere
        # answers "which file is my status bar reading" and a stuck HUD is
        # undiagnosable rather than merely unhelpful.
        def hud_line = "HUD state: #{state_path}"

        # Print order: warnings first, so a degraded HUD is explained before
        # anything scrolls past.
        def messages = warnings + [hud_line, announcement]
      end

      # {#launch_plan}'s return shape: what to print, in print order, then
      # exactly the `Kernel.exec` array {#attach_command} composed.
      LaunchPlan = Data.define(:messages, :argv)

      # Kept as the established public seam so /fork's window and /btw's popup
      # still reach {PaneCommand} under the name they already use.
      def self.pane_command(*argv) = PaneCommand.call(*argv)

      # The `up` flags as this class's constructor keywords. It earns its keep
      # by keeping one translation in one place: two flags decide `nvim:`, and
      # the exe has no business knowing which combination makes which value.
      class Flags
        # `--no-nvim` with `--nvim-socket`. Refused rather than resolved either
        # way: dropping the socket loses a request the user made, and letting it
        # turn the cockpit back on overrides the one they made more explicitly.
        # Two flags that cancel are a typo, and the useful answer names both.
        class SocketWithoutCockpit < Error
          def initialize(socket)
            super("--no-nvim turns the cockpit off, so --nvim-socket #{socket.inspect} has nothing to " \
                  "listen on -- drop whichever of the two you did not mean")
          end
        end

        # @param options [Hash] `up`'s parsed flags
        # @option options [String] :session tmux session name
        # @option options [String, nil] :socket tmux socket (-L), default socket when nil
        # @option options [Boolean] :nvim open the nvim + chat cockpit
        # @option options [String, nil] :nvim_socket an explicit nvim socket; derived when unset
        def initialize(options)
          @options = options
        end

        # @return [Hash] the keywords {Up#initialize} takes
        # @raise [SocketWithoutCockpit]
        def to_h = { session: @options[:session], socket: @options[:socket], nvim: }

        private

        # nil is off; "" is {Cockpit}'s derive sentinel, so an absent flag and an
        # empty one arrive as the same value, deliberately.
        def nvim
          socket = @options[:nvim_socket]
          raise SocketWithoutCockpit, socket if socket && !@options[:nvim]

          @options[:nvim] ? socket.to_s : nil
        end
      end

      # Every tmux invocation `lain up` makes, on the socket it was told to use,
      # turning a real tmux failure into a named Lain error. This is the seam
      # `shell_out_factory` was always injected for.
      #
      # {TmuxSurface} carries a private `act`/`run`/`socket_flag` trio this
      # duplicates almost exactly, `socket_flag` byte-for-byte. Sharing the two
      # is the real cleanup; this extraction only bought {Up} the ten lines the
      # ClassLength cop wanted.
      class Tmux
        # @param socket [String, nil] tmux's `-L`; the default socket when nil
        # @param shell_out_factory [#call] `Mixlib::ShellOut.new`, or a double
        def initialize(socket:, shell_out_factory:)
          @socket = socket
          @shell_out_factory = shell_out_factory
        end

        # Composed but not run: {Up#attach_command} hands this to `Kernel.exec`,
        # which has to replace the process rather than spawn a child.
        def argv(*) = ["tmux", *socket_flag, *]

        # TOLERATES a nonzero exit, which two callers need: `has-session`'s "no
        # such session" is an answer, and {Up#keep_failed_pane} is best-effort.
        def run(*)
          @shell_out_factory.call(*argv(*)).tap(&:run_command)
        rescue Errno::ENOENT
          raise TmuxUnavailable, "tmux not found on PATH -- install it (or fix PATH) before `lain up`"
        end

        # Every MUTATING call goes through here, so a broken or sandboxed tmux
        # fails loudly instead of leaving a half-configured session and no
        # error anywhere.
        def act(*args)
          shell_out = run(*args)
          return shell_out if shell_out.exitstatus.zero?

          raise TmuxUnavailable, "tmux #{args.first} failed: #{shell_out.stderr.strip}"
        end

        private

        # Private since {#argv} exists: composing an argv on this socket is
        # something this object does for callers, not a flag it lends them.
        def socket_flag = @socket ? ["-L", @socket] : []
      end

      # Asks `chat` whether it would refuse, before a session exists to hide the
      # answer in: a missing API key or a bad `--num-ctx` used to reach the
      # operator only from inside a dying pane, where tmux's dead-pane banner
      # scrolls the content up by exactly one line and eats the line naming the
      # cause.
      #
      # It asks by RUNNING chat in a child, with the argv {Up} built and never
      # read. Chat's flags are declared in `exe/lain` and validated by chat, so
      # the check has to be chat's too -- reproducing the refusals here would be
      # a second copy of an existing surface. {ChatLaunch::PREFLIGHT_ENV} makes
      # that child a check rather than a chat.
      #
      # It will NOT refuse when it could not RUN: a check that cannot answer
      # must not close the cockpit, so that degrades to a warning. And it runs
      # only where a pane is about to be spawned, since reattaching respawns
      # nothing and a refusal would lock an operator out of a running session.
      #
      # KNOWN RESIDUAL: the child inherits `lain up`'s OWN environment while the
      # pane inherits the tmux SERVER's, plus {PaneCommand}'s re-exports, which
      # deliberately exclude ANTHROPIC_API_KEY. So the missing-key refusal can
      # differ between the two, in both directions.
      class ChatPreflight
        # Bounded because `lain up` must not hang on a check, and generous
        # against a cold bootsnap cache (~3.6s to load lain) plus `--num-ctx`'s
        # own 2s probe.
        #
        # It is not the whole wait: Mixlib escalates before it kills (TERM,
        # wait, KILL) at a flat ~3.1s, so the overshoot is ADDITIVE rather than
        # proportional. Measured against a TERM-ignoring child at three
        # settings -- 3s to 6.1s, 8s to 11.3s, 15s to 18.2s -- which is what
        # tells the two laws apart, where a single reading at 3s reads as
        # "about double".
        TIMEOUT = 15

        # What the child's stderr may spend on the operator's terminal. A
        # refusal is a line or two, and this is the one message on the path
        # that lain did not write.
        MAX_LINES = 20
        MAX_BYTES = 4_000

        # A backtrace frame's PREFIX, in both of Ruby's spellings, matching a
        # bare `-e` or an eval'd name as readily as a `.rb` path.
        #
        # A prefix rather than a line, which is the whole of {#deframed}:
        # Ruby's FIRST backtrace line is `path:n:in 'method': MESSAGE (Class)`,
        # so the frame and the cause share it. Dropping it whole would satisfy
        # "no frames" by taking with it the one sentence this check exists to
        # deliver.
        FRAME = /\A\s*(from\s+)?\S+:\d+:in\s+('[^']*'|`[^']*'|\S+)(:[ \t]*)?/

        # @param shell_out_factory [#call] `Mixlib::ShellOut.new`, or a double
        # @param cwd [String] where the chat pane will run, so a project-shaped
        #   refusal (`--root`, `--cwd`, a skill that will not load) is decided
        #   against the directory `lain up PATH` named rather than the shell's
        # @param executable [String] the launching binary, read live for
        #   {PaneCommand}'s reason -- it is whatever actually got us here.
        #   Expanded when it names a path, since `cwd:` would otherwise
        #   resolve a relative one against the wrong directory
        def initialize(shell_out_factory:, cwd:, executable: $PROGRAM_NAME)
          @shell_out_factory = shell_out_factory
          @cwd = cwd
          @executable = executable.include?(File::SEPARATOR) ? File.expand_path(executable) : executable
        end

        # @param chat_args [Array<String>] the exe's `-- ARGS` capture, passed
        #   through untouched -- one process argument per element, so nothing
        #   here needs a shell and nothing here reads a flag
        # @return [Array<String>] warnings; empty when chat accepted the argv
        # @raise [ChatRefused] when chat refused it
        def call(chat_args)
          answer = @shell_out_factory.call(@executable, "chat", *chat_args,
                                           cwd: @cwd, timeout: TIMEOUT,
                                           env: { ChatLaunch::PREFLIGHT_ENV => "1" })
          answer.run_command
          return [] if answer.exitstatus&.zero?
          # No status at all is a SIGNALLED child: neither a refusal nor an
          # acceptance, so it degrades rather than guessing.
          return [unchecked("`lain chat` was killed before it could answer")] if answer.exitstatus.nil?

          raise ChatRefused, refusal(answer)
        rescue Errno::ENOENT, Mixlib::ShellOut::CommandTimeout => e
          [unchecked(e.message)]
        end

        private

        # stderr is where Thor prints a refusal; stdout is the fallback and the
        # exit status the last resort, because a child that refused silently is
        # still a refusal and "exit 3" beats an empty line.
        def refusal(answer)
          said = [answer.stderr, answer.stdout].map { |text| legible(text) }.find { |text| !text.empty? }
          said.to_s.empty? ? "`lain chat` refused these arguments (exit #{answer.exitstatus})" : said
        end

        # Scrubbed, de-framed and capped, in that order: everything after the
        # encoding pass is line and byte arithmetic on bytes a child was free to
        # make invalid. `force_encoding` then `scrub`, NOT `encode` -- a String
        # already tagged UTF-8 is its own target encoding, so `encode` returns
        # it unchanged and the invalid bytes sail through. Scrubbed again after
        # the byte cap, which can land mid-character.
        def legible(text)
          text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
              .each_line.lazy.filter_map { |line| deframed(line) }.first(MAX_LINES).join.strip
              .byteslice(0, MAX_BYTES).scrub("?")
        end

        # The frame off, the cause kept. A line that never looked like a frame
        # is returned untouched, blank ones included: spacing a child chose is
        # not this object's to edit.
        def deframed(line)
          return line unless line.match?(FRAME)

          rest = line.sub(FRAME, "")
          rest unless rest.strip.empty?
        end

        def unchecked(reason)
          "could not pre-flight the chat arguments (#{reason}) -- opening the cockpit unchecked, " \
            "so a refusal will surface in the chat pane instead"
        end
      end

      # Reads the chat pane back shortly after it was given its command and
      # answers what it died of -- or nothing, which is the ordinary case.
      # {ChatPreflight} covers only what `chat` will REFUSE; a pane that fails
      # to exec, or whose login shell exits, is discovered by running it.
      #
      # THE SCROLLBACK, NOT THE VISIBLE REGION. tmux draws its own `Pane is
      # dead` banner INTO the pane, scrolling the content up by exactly one
      # line -- and the first line is where a refusal names its cause. Measured
      # on tmux 3.7b: a plain `capture-pane -p` comes back without it, `-S -`
      # still has it.
      #
      # The grace is counted from when the pane was given its command, not from
      # when the check starts, because tmux reaps an exited pane on its own
      # event loop -- measured 11-20ms after `respawn-pane` over 15 reps,
      # including the polling client's round trip. Every tmux call {Up} makes in
      # between is time already spent, so a loaded box spends the grace on work
      # rather than sleeping, and a confirmed death ends the wait at once: only
      # a HEALTHY launch pays, and only for the remainder.
      #
      # A death slower than {GRACE} loses nothing but the message --
      # `remain-on-exit failed` still holds the corpse on screen -- which is
      # what makes a small bound a trade rather than a compromise.
      #
      # Best-effort throughout, on {Up#keep_failed_pane}'s rule: a diagnostic
      # that cannot tell must never close a cockpit that would otherwise open.
      class PaneCorpse
        # Seconds from the pane's spawn: ~7x the 11-20ms reap latency measured
        # above, which is the only thing the wait is here to outlast.
        GRACE = 0.15

        # Fine enough to report a confirmed death promptly, coarse enough that
        # the poll costs a handful of tmux round trips rather than a spin.
        CADENCE = 0.01

        # Larger than {ChatPreflight}'s caps because this is a SCREEN rather
        # than a refusal, and it keeps backtrace frames: a refusal that needs a
        # frame to explain itself is a bug, while an unexpected crash IS the
        # frames.
        MAX_LINES = 40
        MAX_BYTES = 4_000

        # tmux's OWN format syntax, single-quoted so it reaches tmux byte for
        # byte. `display-message -p` resolves it against the window's ACTIVE
        # pane, which is the chat pane in both shapes `lain up` builds.
        # rubocop:disable Lint/InterpolationCheck
        FORMAT = '#{pane_dead} #{pane_dead_status}'
        # rubocop:enable Lint/InterpolationCheck

        # Built where the pane is handed its command, because the grace it
        # measures is the PANE's life: there is no constructing one early and
        # arming it later, and no corpse for a pane that was never spawned.
        #
        # @param tmux [Tmux] the same server {Up} built the session on
        # @param target [String] the chat window, `session:chat`
        # @param session [String] the session that will survive the pane, named
        #   separately because the advice is spelled in tmux's own words and
        #   `kill-session` takes a session rather than a window
        # @param clock [#call] the monotonic source the grace is measured
        #   against, defaulted from {RunClock::MONOTONIC} because that constant
        #   is spec'd to have exactly one site -- and because it lets a spec pin
        #   the poll in probe counts rather than in wall time
        def self.watching(tmux:, target:, session:, clock: RunClock::MONOTONIC) = new(tmux:, target:, session:, clock:)

        def initialize(tmux:, target:, session:, clock: RunClock::MONOTONIC)
          @tmux = tmux
          @target = target
          @session = session
          @clock = clock
          @spawned_at = @clock.call
        end

        # @return [String, nil] what the pane died of, or nil -- which covers
        #   both "it is alive" and "tmux would not say", deliberately: the two
        #   have the same consequence, which is that `lain up` attaches.
        def call
          deadline = @spawned_at + GRACE
          verdict = probe
          verdict = wait_and_probe while verdict == :alive && @clock.call < deadline
          verdict.is_a?(String) ? report(verdict) : nil
        end

        private

        def wait_and_probe
          sleep(CADENCE)
          probe
        end

        # The breadth of `rescue StandardError` is the point. {Tmux#run} names
        # only `Errno::ENOENT`, and every other way asking can fail -- EACCES on
        # the binary, EMFILE out of fork -- would escape past `exe/lain`'s
        # `rescue Lain::Error`, putting a backtrace on the operator's terminal
        # AND killing a launch that was working. The rescue is on the BEHAVIOUR
        # rather than on a list of errnos, because the list is what was wrong.
        #
        # @return [String, :alive, :unanswerable] the pane's exit status when
        #   it is dead
        def probe
          answer = @tmux.run("display-message", "-p", "-t", @target, FORMAT)
          return :unanswerable unless answer.exitstatus&.zero?

          dead, status = answer.stdout.strip.split(" ", 2)
          dead == "1" ? status.to_s : :alive
        rescue StandardError
          :unanswerable
        end

        # An empty status is tmux before 2.9, which has `pane_dead` but not
        # `pane_dead_status`, so the sentence has to survive knowing the death
        # and not the number.
        #
        # It names the SESSION and what a re-run does with it, because the
        # shorter "there is nothing to attach to" is true for exactly one
        # command: the session was built and {Up#keep_failed_pane} is holding
        # the corpse in it on purpose, so the next `lain up` reattaches straight
        # into that pane.
        def report(status)
          died = status.empty? ? "died" : "exited #{status}"
          "the chat pane #{died} moments after `lain up` started it, so this did not attach. " \
            "Session '#{@session}' survives with the dead pane in it: another `lain up` attaches to " \
            "it as it stands, `tmux kill-session -t #{@session}` clears it for a fresh start. " \
            "What #{@target} held:\n\n#{held}"
        end

        # Same breadth as {#probe}, the other way round: the pane IS dead by
        # here, so only the evidence can go missing, and losing the capture must
        # not lose the refusal.
        def held
          text = legible(@tmux.run("capture-pane", "-p", "-S", "-", "-t", @target).stdout)
          text.empty? ? "(nothing -- it died without writing a line)" : text
        rescue StandardError
          "(nothing -- tmux would not hand back the pane's screen)"
        end

        # Scrubbed first, because everything after is line and byte arithmetic
        # on text a terminal was free to fill with any bytes; scrubbed again
        # after the byte cap, which can land mid-character.
        #
        # The squeeze is where this parts company with {ChatPreflight#legible}.
        # A PANE is a fixed grid, so most of what comes back is tmux padding
        # rows -- measured end to end, twenty blank lines between the cause and
        # the dead-pane banner, which would also have been twenty of
        # {MAX_LINES}.
        #
        # It works because tmux strips a row's trailing whitespace, not because
        # the regexp guarantees anything: a whitespace-only row is not squeezed
        # at all, and a program's own double blank line is flattened to one.
        # Measured on a real `-S -` capture: 36 truly-blank rows, zero
        # whitespace-only ones. A tmux that padded with spaces would leave the
        # screenful back, which is cosmetic rather than wrong.
        def legible(text)
          text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").strip.gsub(/\n{3,}/, "\n\n")
              .each_line.first(MAX_LINES).join.byteslice(0, MAX_BYTES).scrub("?")
        end
      end

      # "Is this one installed, and does it answer?" -- asked of `jq` for the
      # HUD and of `nvim` for the cockpit. `--version` is the probe because it
      # is the one flag both have and neither does work for, and ENOENT is the
      # answer that matters: an absent binary is a DEGRADE here, never an error,
      # so the rescue is the point of the object rather than a guard on it.
      #
      # Extracted so {Up} owns no shell_out_factory of its own -- no ivar, no
      # call site -- and every subprocess `lain up` causes goes through an
      # object named for what it runs.
      class Binaries
        # @param shell_out_factory [#call] `Mixlib::ShellOut.new`, or a double
        def initialize(shell_out_factory:) = @shell_out_factory = shell_out_factory

        # @param binary [String] a command name, resolved against PATH
        # @return [Boolean]
        def present?(binary)
          @shell_out_factory.call(binary, "--version").tap(&:run_command).exitstatus.zero?
        rescue Errno::ENOENT
          false
        end
      end

      # @param options [Hash] `up`'s parsed flags; {Flags} is where they are read
      # @param chat_args [Array<String>] the flags after `--`, forwarded to `chat` verbatim
      # @param path [String, nil] the PATH argument: the project directory to open
      # @option options [String] :session tmux session name
      # @option options [String, nil] :socket tmux socket (-L), default socket when nil
      # @option options [Boolean] :nvim open the nvim + chat cockpit
      # @option options [String, nil] :nvim_socket an explicit nvim socket; derived when unset
      # @raise [Workdir::NotADirectory]
      # @raise [Flags::SocketWithoutCockpit]
      def self.from_options(options, chat_args:, path: nil)
        new(chat_args:, **Flags.new(options).to_h, **Workdir.option(path))
      end

      # The cockpit switch is `nvim:`: nil is off, "" derives the plugin's
      # deterministic socket, a non-empty String is that path used verbatim.
      #
      # `cwd:` is declared BEFORE `state_path:` so the HUD's default can read
      # it. The state file is a fact about the directory the PANES sit in, not
      # about the shell that typed `lain up PATH`: the chat pane publishes it
      # from its own cwd and both panes are pinned to `@cwd` with tmux's `-c`,
      # which is what makes writer and reader name one file. They HAVE to,
      # because the feed lives under `$XDG_STATE_HOME/lain` keyed by
      # `sha256(realpath(dir))[0, 12]`, so a HUD defaulted from a different
      # directory polls a path nothing writes rather than merely looking stale.
      # The realpath absorbs the difference between the PATH argument this class
      # expands and the kernel-resolved `Dir.pwd` the pane reads. {ProjectDir}
      # is a THIRD object both this class and {StatusFeed} name, never one
      # reaching into the other's private helper.
      #
      # `chat_preflight:` is injected for a reason a spec cannot get around: the
      # real one SPAWNS the launching binary, which under rspec is rspec. A
      # group driving real tmux hands in a no-op so it keeps measuring tmux.
      # `gc_schedule:` spawns the launching binary too, and declines to when
      # that binary is not lain.
      def initialize(session: DEFAULT_SESSION, socket: nil, cwd: Dir.pwd,
                     state_path: ProjectDir.new(root: cwd).state_path,
                     chat_command: nil, chat_args: [], status_interval: Hud::DEFAULT_INTERVAL,
                     nvim: nil, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new),
                     chat_preflight: ChatPreflight.new(shell_out_factory:, cwd:),
                     gc_schedule: GcSchedule.for(cwd:, paths:))
        @session = session
        @tmux = Tmux.new(socket:, shell_out_factory:)
        @cwd = cwd
        @hud = Hud.new(state_path:, interval: status_interval)
        @chat_args = chat_args
        @chat_command = chat_command || default_chat_command
        @cockpit = Cockpit.new(option: nvim, cwd:, paths:)
        @binaries = Binaries.new(shell_out_factory:)
        @chat_preflight = chat_preflight
        @gc_schedule = gc_schedule
      end

      # @return [Report]
      # @raise [TmuxUnavailable] no tmux on PATH, or a real tmux failure --
      #   never a bare Errno/Mixlib exception past this boundary.
      def call
        # Per call, so a second launch through one Up reports only its own.
        @warnings = []
        @gc_schedule.call
        created = !session_exists?
        created ? create_session : reattach_session
        configure_session
        Report.new(session: @session, created:, warnings: @warnings.dup, state_path: @hud.state_path)
      end

      # Everything the exe needs to finish `lain up`, in the order it needs it:
      # what to print, then what to exec. The sequencing is Up's own domain
      # knowledge rather than something to re-derive call site by call site.
      #
      # {PaneCorpse} hangs off HERE and not off `#call` by decision: `#call` was
      # asked to build a session and it built one, with a corpse in it, which is
      # what {#keep_failed_pane} is for. What a corpse changes is whether
      # ATTACHING is still the right next move -- this method's whole subject --
      # and it keeps the refusal off every other caller, none of which attaches.
      #
      # `@corpse` is nil by ABSENCE on the reattach path, since {#build_panes}
      # is its only writer. Deliberate twice over: there is no launch to judge,
      # and a corpse the operator came back to is evidence they are entitled to
      # attach to and read rather than something to lock them out of.
      #
      # @param nested [Boolean] forwarded to {#attach_command} unchanged
      # @return [LaunchPlan]
      # @raise [ChatDied] the chat pane died before anyone could attach to it
      def launch_plan(nested:)
        report = call
        died = @corpse&.call
        raise ChatDied, died if died

        LaunchPlan.new(messages: report.messages, argv: attach_command(nested:))
      end

      # `switch-client` when the CALLING shell is itself an attached tmux
      # client, plain `attach` otherwise. The branch has to happen BEFORE exec
      # rather than be caught after: tmux refuses a nested `attach`, and by then
      # `Kernel.exec` has already replaced the process, so the refusal comes out
      # raw past any rescue. `nested:` is the caller's OWN answer rather than
      # this class reading ENV, so a spec exercises the same branch a real
      # nested shell hits with no environment coupling.
      #
      # Known gap: `switch-client` only reaches a session on the SAME server the
      # caller is attached to, so `lain up --socket other` from inside a
      # different tmux server is unhandled.
      #
      # @param nested [Boolean] true when the calling shell is itself an
      #   attached tmux client
      # @return [Array<String>] argv for Kernel.exec
      def attach_command(nested:) = @tmux.argv(nested ? "switch-client" : "attach", "-t", @session)

      private

      # The one query that TOLERATES a nonzero exit: "no such session" is the
      # expected, non-error answer that drives #call into #create_session.
      def session_exists? = @tmux.run("has-session", "-t", @session).exitstatus.zero?

      # `@chat_args` is the exe's `-- ARGS` capture: chat's own flags to
      # validate, never Up's. The recipe only escapes each one for the shell
      # tmux hands the string to; Up never parses or knows the flag names.
      def default_chat_command = self.class.pane_command("chat", *@chat_args)

      # The ordering IS the fix, and each step is load-bearing.
      #
      # {ChatPreflight} FIRST, as the only step that can REFUSE: a refusal
      # raised after `new-session` would leave a session behind for the next
      # `lain up` to reattach to. Nothing tmux has been asked to do yet --
      # `has-session` creates no server.
      #
      # `cockpit_wanted?` next, because it spawns `nvim --version` and touches
      # no tmux, keeping its cost out of the window below.
      #
      # Then the window is opened EMPTY, carrying tmux's own default shell, so
      # {#keep_failed_pane} has somewhere to land BEFORE any pane runs a command
      # that can die -- see that method for the bug this closes.
      #
      # `-c` on the plain window too, not only the cockpit's two panes: a
      # `--no-nvim` session inheriting tmux's default-path would run its chat
      # wherever the tmux SERVER was started, a different project from the one
      # `lain up PATH` names and the one the HUD reads.
      #
      # `-x`/`-y` for {DETACHED_WIDTH}'s reason: every pane below opens while
      # the session is still detached, so the size stated here is what the split
      # and nvim's own layout are computed against.
      def create_session
        @warnings.concat(@chat_preflight.call(@chat_args))
        cockpit = cockpit_wanted?
        @tmux.act("new-session", "-d", "-s", @session, "-n", CHAT_WINDOW, "-c", @cwd,
                  "-x", DETACHED_WIDTH.to_s, "-y", DETACHED_HEIGHT.to_s)
        keep_failed_pane
        build_panes(cockpit)
      end

      # `lain up` builds a WORKING session or none at all. Splitting
      # `new-session` from the command it used to carry is what made that
      # something to keep on purpose: a failure in between strands a session
      # called `lain` whose chat window is a bare login shell, and since
      # #configure_session never ran, the retry finds it, reports "reattaching"
      # with NO warnings, and drops the operator at a shell prompt.
      #
      # Scoped to AFTER the window exists, deliberately: a `new-session` that
      # failed because another `lain up` just took the name must never be
      # answered by killing THEIR session.
      #
      # {PaneCorpse} starts its clock HERE for both shapes, because the grace it
      # measures is the PANE's life. Nothing builds one on the reattach path,
      # which is what makes `@corpse` nil there.
      def build_panes(cockpit)
        cockpit ? spawn_cockpit_panes : spawn_chat_pane
        @corpse = PaneCorpse.watching(tmux: @tmux, target: chat_target, session: @session)
      rescue StandardError
        @tmux.run("kill-session", "-t", @session)
        raise
      end

      def spawn_chat_pane = @tmux.act("respawn-pane", "-k", "-t", chat_target, "-c", @cwd, @chat_command)

      # Reattaching rebuilds nothing, so all it owes is the un-split warning and
      # a re-assert of {#keep_failed_pane}: a session `lain up` did not create,
      # or created before this option did, still earns its corpse.
      def reattach_session
        warn_unsplit_reattach
        keep_failed_pane
      end

      # The degrade contract, on the jq fallback's "degraded is never silent"
      # rule: no nvim binary means a single chat pane plus a named warning,
      # probed only on the create path.
      #
      # The message names no FLAG, because the cockpit is the default and the
      # operator need not have typed one -- "--nvim ignored" read as a reproach
      # for something they did not do.
      def cockpit_wanted?
        return false unless @cockpit.requested?
        return true if @binaries.present?("nvim")

        @warnings << "nvim not found on PATH -- opening the plain chat window instead of the cockpit " \
                     "(install neovim for the editor pane, or pass --no-nvim to stop asking)"
        false
      end

      # Reattaching with --nvim: #create_session never ran, so a chat window
      # still un-split means the request is being ignored, and degraded is never
      # silent. A window already carrying two panes IS the cockpit.
      def warn_unsplit_reattach
        return unless @cockpit.requested? && chat_window_unsplit?

        @warnings << "session '#{@session}' already exists without the nvim pane -- reattaching as-is " \
                     "(kill the session and re-run `lain up --nvim` for the cockpit, or attach plain)"
      end

      # list-panes answers one line per live pane; the cockpit means two.
      def chat_window_unsplit?
        @tmux.run("list-panes", "-t", chat_target).stdout.lines.size < 2
      end

      # Both panes pinned to ONE cwd with tmux's -c and handed ONE socket, so
      # the convention cannot silently diverge between the editor and the chat
      # that attaches to it.
      def spawn_cockpit_panes
        warn_missing_plugin
        @tmux.act("respawn-pane", "-k", "-t", chat_target, "-c", @cwd, @cockpit.nvim_pane_command)
        @tmux.act("split-window", "-h", "-t", chat_target, "-c", @cwd,
                  self.class.pane_command("chat", *@cockpit.chat_flags, *@chat_args))
      end

      # Probed only on the create path: a reattach never rebuilds the pane
      # commands, so it has nothing new to warn about even when the shipped
      # plugin cannot be located.
      def warn_missing_plugin
        return unless @cockpit.plugin_missing?

        @warnings << "lain's nvim plugin directory not found at #{@cockpit.nvim_plugin_root} -- cockpit opening " \
                     "with a plain nvim pane (reinstall the gem, or run :LainStart yourself once attached)"
      end

      def configure_session
        status_right, warning = @hud.status_right(jq_present: @binaries.present?("jq"))
        @warnings << warning if warning
        set_option("status-right", status_right)
        set_option("status-interval", @hud.interval.to_s)
        @tmux.act("set-window-option", "-t", chat_target, "monitor-bell", "on")
      end

      # A chat pane that dies takes its error message with it, and when it is
      # the session's only pane it takes the window, the session and the tmux
      # SERVER too -- so a perfectly clear refusal reaches the operator as a
      # terminal that blinks once and returns to the shell. That is how the
      # 2026-08-06 "starts and immediately crashes" report looked from outside,
      # with the cause legible only from a probe socket with remain-on-exit
      # forced on.
      #
      # WHEN this is written is the whole of it, because tmux reads the option
      # at pane-DEATH time. As the LAST thing #configure_session did, four tmux
      # invocations after the pane was already running chat, the fastest crashes
      # -- exactly the ones it was written for -- died into a window with no
      # option yet, and `up` then failed on its next tmux call with "no server
      # running" instead of leaving a corpse to read. Measured 9 losses in 20
      # forced repeats. tmux offers no creation-time flag for a window option
      # and, since 2.9, no scope between the window and the user's GLOBALS,
      # which `lain up` does not write -- so {#create_session} opens the window
      # bare and respawns the command into it.
      #
      # That replaces the party running the race rather than narrowing it: what
      # sits in the pane for the ~17-26ms in between is the user's LOGIN SHELL,
      # and a pathological `default-command` that exits there still takes pane
      # to window to session to server. Small, real, and not retired by the fix.
      #
      # `failed` and not `on`, so a clean exit still closes the pane and this
      # only holds the screen when there is something to read.
      #
      # #run, not #act -- best-effort ON PURPOSE, because `failed` needs tmux
      # >= 3.2 and failing `lain up` outright on an older tmux would trade a
      # working cockpit for a diagnostic nicety. The degrade is exact on
      # `2.6 <= v < 3.2`; below 2.6 it is not, since {#spawn_chat_pane}'s
      # `respawn-pane -c` did not exist yet and goes through #act. That is also
      # why this stays its OWN invocation rather than being chained onto
      # #create_session's with tmux's `;`, which would close the race just as
      # tightly: tmux aborts a command list at the first failure, so an older
      # tmux would be left with a half-created session AND a raise out of
      # #act.
      def keep_failed_pane = @tmux.run("set-window-option", "-t", chat_target, "remain-on-exit", "failed")

      def chat_target = "#{@session}:#{CHAT_WINDOW}"

      def set_option(name, value) = @tmux.act("set-option", "-t", @session, name, value)
    end
  end
end

# Both reopen the Up class body above, so they load after it.
require_relative "up/cockpit"
require_relative "up/hud"
require_relative "up/pane_command"
