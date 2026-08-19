# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # `lain up`: create (idempotently) or attach to the "lain" tmux session,
    # and give it the session-scoped HUD planning/interface-integration.md §
    # "One state feed, three renderers" designs -- status-right/status-interval
    # reading I1's `.lain/state.json` via jq, `monitor-bell` on the spawned
    # chat window. Session-scoped, never global (`set-option -t SESSION`,
    # never `-g`): tmux's own inheritance rule (session beats global) is what
    # keeps the theme plugin's globals untouched, so this needs zero
    # tmux.conf changes.
    #
    # Idempotent by construction: #call probes `has-session` first and only
    # creates when it is absent, so a second `lain up` re-applies the same
    # (harmless) option writes to the session that is already there instead
    # of spawning a duplicate -- the exe's job from there is just to attach.
    #
    # Every tmux/jq invocation goes through Mixlib::ShellOut with an ARGV
    # array, never a single command string -- no intermediate shell on OUR
    # side, so nothing here needs to worry about quoting `session`/
    # `state_path`/`chat_command` against a shell we control. The ONE place a
    # shell reappears is deliberate: the `#(...)` job tmux embeds in
    # `status-right` is interpreted by tmux's OWN `$SHELL -c` at render time,
    # so THAT string (composed by {Up::Hud}) is Shellwords-escaped for a POSIX
    # shell, not for ours.
    class Up
      # tmux missing outright, or any tmux invocation that fails for a reason
      # other than "no session yet" (has-session's own expected nonzero) --
      # surfaced by name so the exe's Lain::Error -> Thor::Error mapping shows
      # a clean message, never a raw Errno or Mixlib backtrace on a demo
      # machine.
      class TmuxUnavailable < Error; end

      # A chat `lain up` will not open a session for, refused in chat's own
      # words. The message is the child's stderr VERBATIM: the exe maps a
      # {Lain::Error} to a `Thor::Error`, which prints the message and nothing
      # else, so what the operator reads is exactly what the pane would have
      # shown them -- and, unlike the pane, with its first line intact.
      class ChatRefused < Error; end

      # A chat pane that died before `lain up` could attach to anything, told
      # in the pane's own words. The sibling of {ChatRefused}: that one is what
      # `chat` could be ASKED about beforehand, this one is what only running
      # it reveals -- an exec that failed, a pathological login shell, a crash
      # on the way up. {PaneCorpse} composes the message.
      class ChatDied < Error; end

      # The PATH argument: a directory a user typed, expanded against the
      # shell's own and checked ONCE. Everything below that names a directory
      # reads the result -- both panes' tmux `-c`, the nvim socket's hash, and
      # the HUD's `.lain/state.json` -- so a PATH honoured by only some of them
      # would leave a cockpit in the project the user asked for beside a status
      # bar reading the shell's, which looks like a stale HUD rather than the
      # wrong project.
      class Workdir
        # Refused BY NAME rather than left to tmux, whose answer to `-c <file>`
        # is a pane that dies before anything reaches the screen -- and rather
        # than falling back to the shell's directory, which would open a
        # session somewhere the user did not ask for and say nothing about it.
        class NotADirectory < Error
          def initialize(path)
            super("#{path} is not a directory -- `lain up [PATH]` opens the project directory you name")
          end
        end

        # nil is "wherever the shell is", which needs neither expansion nor a
        # check -- and yields NO keyword at all, so {Up#initialize}'s own
        # default stays the single place this class reads the working directory.
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

      # The size a session `lain up` CREATES is built at, stated because tmux
      # sizes a session with no client attached from `default-size` -- 80x24
      # out of the box. Everything `lain up` does happens before anyone
      # attaches: the window is opened, split, and nvim boots in the left pane
      # while the exe is still on its way to `attach`. At tmux's default that
      # made the cockpit two 40-column panes, which is not an editor anyone can
      # work in, and 40 columns is what nvim computes its own layout against.
      #
      # What this is NOT a fix for, stated because the first draft of this
      # comment claimed it: 40x24 was never shown to BREAK nvim. Review
      # reproduced neither half -- `nvim --clean --listen` in a real 40x24 tmux
      # pane serves RPC and answers `&columns` at once (0.12.4), and four
      # `botright vsplit`s (the plugin's own layout primitive) succeed at 40
      # columns with no E36. So the QA round 6 hang, where an nvim RPC never
      # answered, has NO established cause and is still open. This widens the
      # session because a 40-column editor pane is not a usable cockpit, which
      # stands on its own.
      #
      # 200x50 rather than a guess at the terminal: the operator's real client
      # resizes the whole window on attach (`window-size latest`, tmux's
      # default), so this number only has to be big enough for the layout that
      # boots BEFORE anyone is there -- and being generous costs a session
      # nobody is looking at nothing. The invariant is "true at CREATION", not
      # "true whenever detached": once an 80x24 client has attached, the window
      # is 80x24 and DETACHING does not restore this (measured -- `window-size
      # latest` keeps the last client's size). Harmless here, because
      # everything that reads the geometry has already run by then.
      #
      # Session-scoped like every other option here: `-x`/`-y` on `new-session`
      # is recorded as `default-size` ON THAT SESSION (measured: a sibling
      # session on the same server keeps its own, and the server's global stays
      # 80x24), so this needs no `-g` write and cannot reach the operator's own
      # sessions. That last part is ASSERTED, not just measured -- a global
      # write is the one outcome worse than the defect, and it is invisible to
      # every argv assertion. Nothing states geometry on the REATTACH path
      # either: a session lain did not create may have a human attached, and
      # resizing that would shrink their terminal to fix our layout.
      #
      # Sized for the cockpit but applied to every created session, `--no-nvim`
      # included -- one window in a 200x50 session is no worse off. There is a
      # case that a layout's dimensions belong to {Cockpit} rather than here;
      # left alone because what is written is an option on the SESSION, which
      # is this class's own object.
      DETACHED_WIDTH = 200
      DETACHED_HEIGHT = 50

      Report = Data.define(:session, :created, :warnings)

      # `created` tells the caller whether a fresh session was just built (so
      # it can say so before attaching) or one was already running (so a
      # second `lain up` reads as "reattaching", never "duplicating").
      # `warnings` carries the jq-missing notice, if any -- the exe `say`s it
      # before attaching so a degraded HUD is never a SILENT one.
      class Report
        # The created-vs-reattaching line is the Report's OWN knowledge (it
        # already carries exactly the two fields that decide it), not exe
        # glue -- the exe just `say`s whatever this returns, alongside
        # `warnings`, before it execs.
        def announcement
          created ? "created tmux session '#{session}'" : "reattaching to '#{session}'"
        end
      end

      # {#launch_plan}'s return shape: `messages` is everything the exe
      # `say`s, in print order (warnings before the final announcement, so a
      # degraded HUD is explained BEFORE "created"/"reattaching" scrolls
      # past); `argv` is exactly {#attach_command}'s `Kernel.exec` array.
      LaunchPlan = Data.define(:messages, :argv)

      # The pane-command recipe lives in {PaneCommand} -- what a spawned pane
      # is missing is a question about shells and environments, not about tmux.
      # Kept here as the public seam T16 F2 established, so /fork's window and
      # /btw's popup still share it under the name they already use.
      def self.pane_command(*argv) = PaneCommand.call(*argv)

      # The `up` flags, as this class's constructor keywords -- the same shape
      # {Consolidate.from_options} and {Improve.from_options} use, and it earns
      # its keep by keeping ONE translation in one place: two flags decide
      # `nvim:`, and the exe has no business knowing which combination makes
      # which value.
      class Flags
        # `--no-nvim` with `--nvim-socket`. Refused rather than resolved either
        # way: silently dropping the socket loses a request the user made, and
        # letting it turn the cockpit back on overrides the one they made more
        # explicitly. Two flags that cancel are a typo, and the only useful
        # answer is to say which two.
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

        # nil is off. "" is the cockpit with no explicit socket, which is
        # {Cockpit}'s own derive sentinel -- so an absent flag and an empty one
        # arrive as the same value, deliberately.
        def nvim
          socket = @options[:nvim_socket]
          raise SocketWithoutCockpit, socket if socket && !@options[:nvim]

          @options[:nvim] ? socket.to_s : nil
        end
      end

      # Every tmux invocation `lain up` makes, on the socket it was told to
      # use, turning a real tmux failure into a named Lain error. Its own
      # object because "speak to a tmux server" and "decide what the cockpit
      # should look like" are different jobs -- and this is the seam
      # `shell_out_factory` was always injected for.
      #
      # NOT the only such layer in the codebase: {TmuxSurface} carries a
      # private `act`/`run`/`socket_flag` trio that this one duplicates almost
      # exactly (`socket_flag` byte-for-byte), and already spells the
      # relationship out with `TmuxUnavailable = Up::TmuxUnavailable`. Sharing
      # the two is the real cleanup here; this extraction only bought {Up} the
      # ten lines the ClassLength cop wanted.
      class Tmux
        # @param socket [String, nil] tmux's `-L`; the default socket when nil
        # @param shell_out_factory [#call] `Mixlib::ShellOut.new`, or a double
        def initialize(socket:, shell_out_factory:)
          @socket = socket
          @shell_out_factory = shell_out_factory
        end

        # The argv for a tmux command on THIS socket, composed but not run --
        # what {Up#attach_command} hands to `Kernel.exec`, which has to
        # replace the process rather than spawn a child.
        def argv(*) = ["tmux", *socket_flag, *]

        # TOLERATES a nonzero exit, which two callers need: `has-session`'s
        # "no such session" is an expected answer rather than a failure, and
        # {Up#keep_failed_pane} is deliberately best-effort.
        def run(*)
          @shell_out_factory.call(*argv(*)).tap(&:run_command)
        rescue Errno::ENOENT
          raise TmuxUnavailable, "tmux not found on PATH -- install it (or fix PATH) before `lain up`"
        end

        # Every MUTATING call goes through here so a real failure -- a broken
        # or sandboxed tmux that cannot spawn a server at all, not just "no
        # session yet" -- fails loudly instead of leaving a half-configured
        # session with no error anywhere.
        def act(*args)
          shell_out = run(*args)
          return shell_out if shell_out.exitstatus.zero?

          raise TmuxUnavailable, "tmux #{args.first} failed: #{shell_out.stderr.strip}"
        end

        private

        # PRIVATE again since {#argv} exists: composing an argv on this socket
        # is now something this object does for its callers rather than a flag
        # it lends them to compose one themselves.
        def socket_flag = @socket ? ["-L", @socket] : []
      end

      # Asks `chat` whether it would refuse, before a session exists to hide
      # the answer in. A missing API key, a bad `--num-ctx`, an unknown
      # `--compact-strategy` -- each used to reach the operator only from
      # inside a dying pane, where tmux's dead-pane banner scrolls the content
      # up by exactly one line and the line it eats is the one naming the
      # cause (`planning/qa/scenarios/failure-injection.md` §11).
      #
      # It asks by RUNNING chat, in a child process, with the argument vector
      # {Up} already built and never read. That is the whole design: chat's
      # flags are declared in `exe/lain` and validated by chat, so the check
      # has to be chat's too -- {Up#default_chat_command} records why Up may
      # not learn them, and reproducing the refusals here would be a second
      # copy of a surface that already exists. What comes back is an exit
      # status and stderr, which is all {Up} needs to decide.
      #
      # {ChatLaunch::PREFLIGHT_ENV} is what makes that child a check rather
      # than a chat; see {ChatLaunch#preflight} for what it does and does not
      # do (no record opened, no server asked).
      #
      # Two things it will NOT do. It will not refuse when it could not RUN --
      # a check that cannot answer must not close the cockpit, so that
      # degrades to a warning, the rule {Up#cockpit_wanted?} and the jq
      # fallback already follow. And it runs only where a chat pane is about
      # to be spawned: reattaching respawns nothing, so there is no launch to
      # pre-empt and a refusal would only lock an operator out of a session
      # that is already running.
      #
      # KNOWN RESIDUAL: the child inherits `lain up`'s OWN environment, while
      # the pane inherits the tmux SERVER's (plus {PaneCommand}'s re-exports,
      # which deliberately exclude `ANTHROPIC_API_KEY` -- a pane command is
      # readable from the process table). So the one refusal whose answer can
      # differ between the two is the missing-key one, and it can differ in
      # both directions. It is the same environment {PaneCommand} already
      # treats as authoritative for every `LAIN_*` default.
      class ChatPreflight
        # Bounded because `lain up` must not hang on a check. Generous against
        # a cold bootsnap cache (~3.6s to load lain) plus `--num-ctx`'s own 2s
        # probe, so no honest pre-flight comes near it.
        #
        # It is not the whole wait, and the overshoot is ADDITIVE rather than
        # proportional: Mixlib escalates before it kills (TERM, wait, KILL),
        # which costs a flat ~3.1s. Measured against a TERM-ignoring child at
        # three settings -- 3s -> 6.1s, 8s -> 11.3s, 15s -> 18.2s. So the
        # worst case here is ~18s, and the earlier `TIMEOUT = 30` really would
        # have stalled a cockpit for ~33s. (A single reading at 3s reads as
        # "about double", which is the coincidence of 3 + 3; two more points
        # are what tell the two laws apart.)
        TIMEOUT = 15

        # What the child's stderr may spend on the operator's terminal. A
        # refusal is a line or two; anything approaching these bounds is not a
        # refusal, and this is the one message on the path that lain did not
        # write.
        MAX_LINES = 20
        MAX_BYTES = 4_000

        # A backtrace frame's PREFIX, in both of Ruby's spellings -- the
        # raising line, and its `from ...` continuations -- and matching a
        # bare `-e` or an eval'd name as readily as a `.rb` path.
        #
        # A prefix rather than a line, and that distinction is the whole of
        # {#deframed}: Ruby's FIRST backtrace line is
        # `path:n:in 'method': MESSAGE (Class)`, so the frame and the cause
        # share it. Dropping it whole satisfies "no frames" by taking the one
        # sentence this check exists to deliver with it -- the operator would
        # read `refused these arguments (exit 1)` about a chat that crashed
        # saying exactly why.
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
          # No status at all is a SIGNALLED child -- neither a refusal nor an
          # acceptance, so it degrades with the rest rather than guessing (and
          # rather than dying on `nil.zero?`, which is how it would read).
          return [unchecked("`lain chat` was killed before it could answer")] if answer.exitstatus.nil?

          raise ChatRefused, refusal(answer)
        rescue Errno::ENOENT, Mixlib::ShellOut::CommandTimeout => e
          [unchecked(e.message)]
        end

        private

        # stderr is where Thor prints a refusal and where every named
        # {Lain::Error} lands through it. stdout is the fallback rather than
        # the alternative, and the exit status is the last resort: a child that
        # refused without saying anything is still a refusal, and "exit 3" is
        # more use to the operator than an empty line.
        def refusal(answer)
          said = [answer.stderr, answer.stdout].map { |text| legible(text) }.find { |text| !text.empty? }
          said.to_s.empty? ? "`lain chat` refused these arguments (exit #{answer.exitstatus})" : said
        end

        # Scrubbed, de-framed and capped, in that order. The encoding pass is
        # first because everything after it is line and byte arithmetic on text
        # that arrived as bytes -- a child is free to emit invalid UTF-8, and a
        # String carrying it reaches a terminal through the exe's `say`.
        # `force_encoding` then `scrub`, NOT `encode`: a String already tagged
        # UTF-8 is its own target encoding, so `encode` returns it unchanged
        # and the invalid bytes sail through. Scrubbed again after the byte
        # cap, which can land mid-character.
        def legible(text)
          text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
              .each_line.lazy.filter_map { |line| deframed(line) }.first(MAX_LINES).join.strip
              .byteslice(0, MAX_BYTES).scrub("?")
        end

        # The frame off, the cause kept. A `from ...` continuation has nothing
        # after its prefix and so disappears; the raising line keeps its
        # message. A line that never looked like a frame is returned untouched
        # -- including a blank one, since spacing a child chose is not this
        # object's to edit.
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

      # Reads the chat pane back, shortly after it has been given its command,
      # and answers what it died of -- or nothing at all, which is the ordinary
      # case and the one this is tuned for.
      #
      # It exists because {ChatPreflight} can only cover what `chat` will
      # REFUSE. A pane that fails to exec, or whose login shell exits, or which
      # crashes on the way up, is discovered by running it -- and the operator
      # then gets attached to a corpse with no idea what they are looking at,
      # or (worse, on an older tmux) a terminal that blinks once and returns to
      # the shell.
      #
      # **The scrollback, not the visible region.** tmux draws its own
      # `Pane is dead (status N, ...)` banner INTO the pane, which scrolls the
      # content up by exactly one line -- and the first line is where a refusal
      # names its cause. Measured on tmux 3.7b: a plain `capture-pane -p` comes
      # back without it, `-S -` still has it. That displacement is the whole
      # reason this object reads history rather than screen.
      #
      # **What it costs the healthy path, and why it is not a fixed wait.** tmux
      # reaps an exited pane on its own event loop, so death is a fact that
      # arrives late -- measured 11-20ms after `respawn-pane` on this box, 15
      # reps, and that includes the polling client's own round trip. So the
      # grace is counted from the moment the pane was given its command rather
      # than from the moment the check starts: every tmux call {Up} makes in
      # between is time already spent, and a loaded box -- where a wait would
      # hurt most -- spends the grace on work instead of on sleeping. A pane
      # confirmed dead ends the wait immediately, so only a HEALTHY launch pays,
      # and only for the remainder.
      #
      # **Nothing is lost when the grace is too short.** A death slower than
      # {GRACE} is simply not converted into a message on the operator's own
      # terminal; `remain-on-exit failed` still holds the corpse on screen where
      # they can read it, exactly as before. That is what makes a small bound
      # the right trade rather than a compromise.
      #
      # Best-effort throughout, on {Up#keep_failed_pane}'s rule: a tmux that
      # will not answer (too old to have held the pane at all, or a server that
      # exited under us) means the check cannot tell, and a diagnostic that
      # cannot tell must never close a cockpit that would otherwise open.
      class PaneCorpse
        # Seconds from the pane's spawn. ~7x the 11-20ms reap latency measured
        # above, which is the only thing the wait is here to outlast.
        GRACE = 0.15

        # Fine enough that a confirmed death is reported promptly, coarse
        # enough that the poll costs a handful of tmux round trips rather than
        # a spin.
        CADENCE = 0.01

        # What a dead pane's screen may spend on the operator's terminal.
        # Larger than {ChatPreflight}'s caps because this is a SCREEN rather
        # than a refusal, and unlike the pre-flight's it keeps backtrace frames:
        # a refusal that needs a frame to explain itself is a bug, while an
        # unexpected crash IS the frames.
        MAX_LINES = 40
        MAX_BYTES = 4_000

        # tmux's OWN format syntax, not Ruby interpolation -- single-quoted so
        # it reaches tmux byte for byte. `display-message -p` resolves it
        # against the window's ACTIVE pane, which is the chat pane in both
        # shapes `lain up` builds: the sole pane of a plain window, and the
        # one `split-window` just made in the cockpit.
        # rubocop:disable Lint/InterpolationCheck
        FORMAT = '#{pane_dead} #{pane_dead_status}'
        # rubocop:enable Lint/InterpolationCheck

        # Built where the pane is handed its command, because the grace it
        # measures is the PANE's life and not this object's -- so there is no
        # constructing one early and arming it later, and no corpse to ask
        # about a pane that was never spawned.
        #
        # @param tmux [Tmux] the same server {Up} built the session on
        # @param target [String] the chat window, `session:chat`
        # @param session [String] the session that will survive the pane, named
        #   separately because the advice is spelled in tmux's own words and
        #   `kill-session` takes a session rather than a window
        # @param clock [#call] the monotonic source the grace is measured
        #   against, defaulted from {RunClock::MONOTONIC} as every `clock:` seam
        #   in the repo is -- naming the primitive here instead would be the
        #   second site of a constant that is spec'd to have exactly one. It is
        #   also what lets a spec pin the poll EXACTLY, in probe counts, rather
        #   than bounding it in wall time and hoping the box stays quiet.
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

        # `rescue StandardError`, and the breadth is the point rather than
        # laziness. {Tmux#run} names only `Errno::ENOENT`; every other way
        # asking can fail -- EACCES on the binary, EMFILE out of fork -- would
        # otherwise escape as something `exe/lain`'s `rescue Lain::Error` does
        # not catch, putting a backtrace on the operator's terminal AND killing
        # a launch that was working. So the rescue is on the BEHAVIOUR (this
        # could not ask) and not on a list of errnos, because the list is what
        # was wrong: a diagnostic never fails `lain up`, whatever went wrong
        # inside it.
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
        # `pane_dead_status` -- so the death is known and the number is not,
        # and the sentence has to survive saying so.
        #
        # It names the SESSION and what a re-run does with it because the
        # obvious shorter sentence -- "there is nothing to attach to" -- is true
        # for exactly one command. {Up#create_session} built a session and
        # {Up#keep_failed_pane} is holding the corpse inside it on purpose, so
        # the next `lain up` reattaches straight into that pane. An operator
        # told "nothing to attach to" and then dropped into it one command later
        # has been misled by us, not by tmux.
        def report(status)
          died = status.empty? ? "died" : "exited #{status}"
          "the chat pane #{died} moments after `lain up` started it, so this did not attach. " \
            "Session '#{@session}' survives with the dead pane in it: another `lain up` attaches to " \
            "it as it stands, `tmux kill-session -t #{@session}` clears it for a fresh start. " \
            "What #{@target} held:\n\n#{held}"
        end

        # Same breadth as {#probe}, failing the other way round: by here the
        # pane IS dead, so the refusal is already correct and only its evidence
        # can go missing. Losing the capture must not lose the refusal.
        def held
          text = legible(@tmux.run("capture-pane", "-p", "-S", "-", "-t", @target).stdout)
          text.empty? ? "(nothing -- it died without writing a line)" : text
        rescue StandardError
          "(nothing -- tmux would not hand back the pane's screen)"
        end

        # Scrubbed first, because everything after it is line and byte
        # arithmetic on text a terminal was free to fill with any bytes at all;
        # scrubbed again after the byte cap, which can land mid-character.
        #
        # The squeeze is where this parts company with {ChatPreflight#legible},
        # whose rule is that spacing a child chose is not its to edit. A PANE is
        # a fixed grid, so most of what comes back is tmux padding the rows it
        # was given -- measured end to end, twenty blank lines between the cause
        # and the dead-pane banner, which would also have been twenty of
        # {MAX_LINES}. Runs collapse to one, so a blank line the program itself
        # wrote between paragraphs still survives.
        #
        # Two bounds on that, neither of them free: a program's own DOUBLE blank
        # line is flattened to a single one, and a padded row -- blank but
        # carrying spaces -- is not squeezed at all. So this works because tmux
        # strips a row's trailing whitespace, not because the regexp guarantees
        # anything: measured on a real `-S -` capture, 36 truly-blank rows and
        # zero whitespace-only ones. A tmux that padded with spaces would leave
        # the screenful back, which is cosmetic rather than wrong.
        def legible(text)
          text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").strip.gsub(/\n{3,}/, "\n\n")
              .each_line.first(MAX_LINES).join.byteslice(0, MAX_BYTES).scrub("?")
        end
      end

      # "Is this one installed, and does it answer?" -- asked of `jq` for the
      # HUD and of `nvim` for the cockpit, and belonging to neither of them.
      # `--version` is the probe because it is the one flag both have and
      # neither does any work for, and ENOENT is the answer that matters: a
      # binary that is not there is a DEGRADE here, never an error, so the
      # rescue is the point of the object rather than a guard on it.
      #
      # Extracted so that {Up} RUNS nothing itself. Be precise about what that
      # buys, because the looser claim is false: {Up#initialize} still takes a
      # `shell_out_factory` and still hands it to three collaborators. What it
      # no longer has is one of its OWN -- no ivar, no call site -- so every
      # subprocess `lain up` causes goes through an object named for what it
      # runs ({Tmux}, {ChatPreflight}, {PaneCorpse}, this), which is also what
      # keeps the fake factory a spec injects readable where it lands.
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

      # `nvim:` is the T19 cockpit switch: nil is off (`--no-nvim`), "" is the
      # cockpit with no explicit `--nvim-socket` (derive the plugin's
      # deterministic one), a non-empty String is that socket path used
      # verbatim. `cwd:` and `paths:` feed {Cockpit}, which owns the
      # socket/pane planning.
      #
      # `cwd:` is declared BEFORE `state_path:` so the HUD's default can read
      # it. `.lain/` is a project artifact like `.git/`, not an XDG concern,
      # and the file is a fact about the directory the PANES sit in rather than
      # about the shell that typed `lain up PATH` -- the chat pane publishes it
      # from its own cwd ({StatusFeed}'s `default_path`), so a HUD defaulted
      # independently reads another project's file and merely looks stale.
      # {ProjectDir} is a THIRD object both this class and {StatusFeed} name,
      # never one reaching into the other's private path helper; threading a
      # root through it is what that separation was left room for.
      #
      # `chat_preflight:` is injected on the `shell_out_factory:` model, and
      # for a reason a spec cannot get around: the real one SPAWNS the
      # launching binary, which under rspec is rspec. A group driving real
      # tmux hands in a no-op so it keeps measuring tmux; the seam's own
      # examples drive the real object over a fake factory.
      def initialize(session: DEFAULT_SESSION, socket: nil, cwd: Dir.pwd,
                     state_path: ProjectDir.new(root: cwd).state_path,
                     chat_command: nil, chat_args: [], status_interval: Hud::DEFAULT_INTERVAL,
                     nvim: nil, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new),
                     chat_preflight: ChatPreflight.new(shell_out_factory:, cwd:))
        @session = session
        @tmux = Tmux.new(socket:, shell_out_factory:)
        @cwd = cwd
        @hud = Hud.new(state_path:, interval: status_interval)
        @chat_args = chat_args
        @chat_command = chat_command || default_chat_command
        @cockpit = Cockpit.new(option: nvim, cwd:, paths:)
        @binaries = Binaries.new(shell_out_factory:)
        @chat_preflight = chat_preflight
        @warnings = []
      end

      # @return [Report]
      # @raise [TmuxUnavailable] no tmux on PATH, or a real tmux failure --
      #   never a bare Errno/Mixlib exception past this boundary.
      def call
        created = !session_exists?
        created ? create_session : reattach_session
        configure_session
        Report.new(session: @session, created:, warnings: @warnings.dup)
      end

      # Everything the exe needs to finish `lain up`, in the order it needs
      # it: what to print, then what to exec. This is the orchestration the
      # exe used to own (build a Report, print its warnings then its
      # announcement, THEN compute the attach argv) -- that sequencing is
      # `Up`'s own domain knowledge, same as `#attach_command`'s verb
      # branching, so it lives here rather than being re-derived call site by
      # call site. `#call`/`#attach_command`/`Report#announcement` all stay
      # public in their own right (existing specs keep exercising each in
      # isolation); this just composes them.
      #
      # {PaneCorpse} hangs off HERE and not off `#call`, which is a decision
      # rather than convenience: `#call` was asked to build a session and it
      # built one -- with a corpse in it, which is exactly what
      # {#keep_failed_pane} is for. What a corpse changes is whether ATTACHING
      # is still the right next move, and "what the exe does once the session
      # exists" is this method's whole subject. It also keeps the refusal off
      # every other caller of `#call`, none of which is about to attach.
      #
      # `@corpse` is nil when nothing was SPAWNED, which is the reattach path,
      # and that silence is deliberate twice over: there is no launch to judge,
      # and a corpse the operator came back to is evidence they are entitled to
      # attach to and read rather than something to lock them out of.
      #
      # Nil by ABSENCE, and stated here because nothing in `#initialize` says
      # so: {#build_panes} is the only writer, so "no corpse" is a pane that was
      # never spawned rather than a default anyone has to remember to set. The
      # reattach examples pin the behaviour; this paragraph is what stops the
      # unset ivar reading as an oversight.
      #
      # @param nested [Boolean] forwarded to {#attach_command} unchanged
      # @return [LaunchPlan]
      # @raise [ChatDied] the chat pane died before anyone could attach to it
      def launch_plan(nested:)
        report = call
        died = @corpse&.call
        raise ChatDied, died if died

        LaunchPlan.new(messages: report.warnings + [report.announcement], argv: attach_command(nested:))
      end

      # The argv the exe hands to `Kernel.exec` to reattach: `switch-client`
      # when the CALLING shell is itself an attached tmux client (tmux
      # refuses a nested `attach` -- "sessions should be nested with care" --
      # and the refusal comes out raw past any rescue, because `Kernel.exec`
      # has already replaced the process by the time tmux objects; the
      # branch has to happen BEFORE exec, not be caught after), plain
      # `attach` otherwise. `nested:` is the caller's OWN answer (the exe
      # passes `ENV.key?("TMUX")`) rather than this class reading ENV
      # itself, so a spec exercises the exact same branch a real nested
      # shell would hit, with no environment coupling.
      #
      # Known gap, accepted for now: `switch-client` only reaches a session
      # on the SAME server the caller is already attached to. `lain up
      # --socket other` from inside a DIFFERENT tmux server is still
      # unhandled -- out of scope while `lain up` only ever spawns on one
      # (default) socket; multi-server topology is a later concern if it
      # ever arises.
      #
      # @param nested [Boolean] true when the calling shell is itself an
      #   attached tmux client
      # @return [Array<String>] argv for Kernel.exec
      def attach_command(nested:) = @tmux.argv(nested ? "switch-client" : "attach", "-t", @session)

      private

      # The one query that TOLERATES a nonzero exit: "no such session" is the
      # expected, non-error answer that drives #call into #create_session.
      def session_exists? = @tmux.run("has-session", "-t", @session).exitstatus.zero?

      # {.pane_command} over the `chat` subcommand. `@chat_args` is the exe's
      # `-- ARGS` trailing capture -- already `chat`'s own flags to validate,
      # never Up's, so the recipe only Shellwords-escapes each one before it
      # lands in a string tmux hands to ITS OWN `$SHELL -c` (the class
      # comment's shell-boundary note); Up never parses or knows the flag
      # names.
      def default_chat_command = self.class.pane_command("chat", *@chat_args)

      # The ordering here IS the fix, and each step is load-bearing.
      #
      # {ChatPreflight} FIRST, and it is the only step that can REFUSE: a chat
      # this session could not run is a session that should never have been
      # created, and a refusal raised after `new-session` would leave one
      # behind for the next `lain up` to reattach to. Nothing tmux has been
      # asked to do yet -- `has-session` above creates no server.
      #
      # `cockpit_wanted?` next, because it spawns `nvim --version` and touches
      # no tmux. Computing it before anything exists keeps the missing-nvim
      # warning where HEAD had it, and keeps its cost out of the window below.
      #
      # Then the window is opened EMPTY -- carrying tmux's own default shell,
      # which is not going anywhere -- so {#keep_failed_pane} has somewhere to
      # land BEFORE any pane runs a command that can die. Only then does the
      # real command arrive. {#keep_failed_pane} explains the bug that closes.
      #
      # `-c` on the plain window too, not only on the cockpit's two panes: a
      # `--no-nvim` session that inherited tmux's default-path would run its
      # chat wherever the tmux SERVER was started, which is a different project
      # from the one `lain up PATH` names and from the one the HUD reads.
      #
      # `-x`/`-y` for {DETACHED_WIDTH}'s reason: every pane below is opened
      # while the session is still detached, so the size stated HERE is the one
      # the split and nvim's own layout are computed against.
      def create_session
        @warnings.concat(@chat_preflight.call(@chat_args))
        cockpit = cockpit_wanted?
        @tmux.act("new-session", "-d", "-s", @session, "-n", CHAT_WINDOW, "-c", @cwd,
                  "-x", DETACHED_WIDTH.to_s, "-y", DETACHED_HEIGHT.to_s)
        keep_failed_pane
        build_panes(cockpit)
      end

      # `lain up` builds a WORKING session or none at all. HEAD had that for
      # free -- `new-session` carried the command, so it either produced a
      # session already running chat or produced nothing -- and splitting the
      # two is what makes it something to keep on purpose: a failure in
      # between would otherwise strand a session called `lain` whose `chat`
      # window is a bare login shell, and since #configure_session never ran,
      # the retry finds it, reports "reattaching to 'lain'" with NO warnings,
      # and drops the operator at a shell prompt.
      #
      # Scoped to AFTER the window exists, deliberately: a `new-session` that
      # failed because another `lain up` just took the name must never be
      # answered by killing THEIR session.
      #
      # {PaneCorpse} starts its clock HERE, once, for both shapes: the grace it
      # measures is the PANE's life, so it has to start where the pane is handed
      # its command and not where the question is later asked. Nothing builds
      # one on the reattach path, which is what makes `@corpse` nil there.
      def build_panes(cockpit)
        cockpit ? spawn_cockpit_panes : spawn_chat_pane
        @corpse = PaneCorpse.watching(tmux: @tmux, target: chat_target, session: @session)
      rescue StandardError
        @tmux.run("kill-session", "-t", @session)
        raise
      end

      def spawn_chat_pane = @tmux.act("respawn-pane", "-k", "-t", chat_target, "-c", @cwd, @chat_command)

      # Reattaching rebuilds nothing, so all it owes is the un-split warning
      # and a re-assert of {#keep_failed_pane}: a session `lain up` did not
      # create -- or created before this option did -- still earns its corpse.
      def reattach_session
        warn_unsplit_reattach
        keep_failed_pane
      end

      # T19's degrade AC: the cockpit without an nvim binary is TODAY's single
      # chat pane plus a named warning -- mirroring the jq fallback's "degraded
      # is never silent" rule, and probed only on the create path (a reattaching
      # `lain up` changes nothing, so it has nothing to warn about).
      #
      # The message does not name a FLAG, because the cockpit is the default and
      # the operator need not have typed one -- "--nvim ignored" read as a
      # reproach for something they did not do.
      def cockpit_wanted?
        return false unless @cockpit.requested?
        return true if @binaries.present?("nvim")

        @warnings << "nvim not found on PATH -- opening the plain chat window instead of the cockpit " \
                     "(install neovim for the editor pane, or pass --no-nvim to stop asking)"
        false
      end

      # Reattaching with --nvim: #create_session never ran, so the cockpit
      # could not have been built THIS run. A chat window that is still
      # un-split means the request is being ignored -- degraded is never
      # silent (the jq and missing-nvim fallbacks' rule), so the warning
      # names the ways out. A window already carrying two panes IS the
      # cockpit, reattaching to it is the ordinary case, nothing to say.
      def warn_unsplit_reattach
        return unless @cockpit.requested? && chat_window_unsplit?

        @warnings << "session '#{@session}' already exists without the nvim pane -- reattaching as-is " \
                     "(kill the session and re-run `lain up --nvim` for the cockpit, or attach plain)"
      end

      # list-panes answers one line per live pane; the cockpit means two.
      def chat_window_unsplit?
        @tmux.run("list-panes", "-t", chat_target).stdout.lines.size < 2
      end

      # The cockpit split, per {Cockpit}'s plan: both panes pinned to ONE cwd
      # (tmux -c) and handed ONE socket, so the convention cannot silently
      # diverge between the editor and the chat that attaches to it.
      def spawn_cockpit_panes
        warn_missing_plugin
        @tmux.act("respawn-pane", "-k", "-t", chat_target, "-c", @cwd, @cockpit.nvim_pane_command)
        @tmux.act("split-window", "-h", "-t", chat_target, "-c", @cwd,
                  self.class.pane_command("chat", *@cockpit.chat_flags, *@chat_args))
      end

      # T2 degrade AC: probed only on the create path (mirrors
      # {#warn_unsplit_reattach}'s own create-vs-reattach split) -- a
      # reattach never rebuilds the pane commands, so it has nothing new to
      # warn about even when the shipped plugin cannot be located.
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
      # the session's only pane it takes the window, the session and the whole
      # tmux SERVER too -- so a refusal that printed a perfectly clear line (a
      # missing API key, an unknown provider) reaches the operator as a
      # terminal that blinks once and returns to the shell. That is how the
      # 2026-08-06 report ("starts and immediately crashes") looked from the
      # outside, with the actual cause legible only from a probe socket with
      # remain-on-exit forced on.
      #
      # WHEN this is written is the whole of it, because tmux reads the option
      # at pane-DEATH time. It used to be the LAST thing #configure_session
      # did, four tmux invocations after the pane was already running chat --
      # so the fastest crashes, exactly the ones it was written for, died into
      # a window that had no option yet, and `up` then failed on its next tmux
      # call with "no server running" rather than leaving a corpse to read.
      # Measured 9 losses in 20 forced repeats. tmux offers no creation-time
      # flag for a window option and, since 2.9, no scope between the window
      # and the user's GLOBALS -- which `lain up` does not write -- so the
      # window is opened bare and the command respawned into it instead
      # ({#create_session}).
      #
      # That does not narrow the race so much as replace the party running it:
      # chat cannot start until after this option is written, so the crash
      # this exists for can no longer land early. What DOES sit in the pane
      # for the ~17-26ms in between is the user's LOGIN SHELL, and a
      # pathological `default-command` or `$SHELL` that exits there still
      # takes pane -> window -> session -> server, because the option has not
      # landed yet either. That exposure is unchanged by this reordering and
      # is measured 3-4x larger than an earlier note assumed -- small, real,
      # and not retired by the fix.
      #
      # `failed` and not `on`: a clean exit should still close the pane, so
      # this costs nothing in the ordinary case and only holds the screen when
      # there is something to read.
      #
      # #run, not #act -- best-effort ON PURPOSE. `failed` needs tmux >= 3.2,
      # and failing `lain up` outright on an older tmux would trade a working
      # cockpit for a diagnostic nicety. On `2.6 <= v < 3.2` that degrade is
      # exact: the option write is skipped and everything else still works.
      # Below 2.6 it is NOT -- {#spawn_chat_pane}'s `respawn-pane -c` did not
      # exist yet and goes through #act, so `lain up` raises rather than
      # degrading. Academic (2.6 is 2017, well under the 3.2 this targets),
      # but the honest bound. That is also why this stays its OWN invocation
      # instead of being chained onto #create_session's with tmux's `;`,
      # which would otherwise close the race just as tightly: tmux aborts a
      # command list at the first failure, so an older tmux would be left with
      # a half-created session AND a raise out of #act.
      def keep_failed_pane = @tmux.run("set-window-option", "-t", chat_target, "remain-on-exit", "failed")

      def chat_target = "#{@session}:#{CHAT_WINDOW}"

      def set_option(name, value) = @tmux.act("set-option", "-t", @session, name, value)
    end
  end
end

# Both reopen the Up class body above, so they load after it (the same
# load-order note effect/handler.rb's children carry).
require_relative "up/cockpit"
require_relative "up/hud"
require_relative "up/pane_command"
