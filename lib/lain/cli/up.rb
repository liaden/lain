# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "shellwords"

module Lain
  module CLI
    # `lain up`: create (idempotently) or attach to the "lain" tmux session and
    # give it the session-scoped HUD -- status-right/status-interval printing
    # the line {Lain::StatusFeed} published, `monitor-bell` on the chat window.
    #
    # The window it builds is nvim on the left and, on the right, the chat's
    # transcript over the pane the human types into -- a transcript scrolls,
    # so the prompt cannot live in it and stay put. The two are joined by one
    # input socket, named from the project and the session before either
    # process exists, so neither pane waits on the other to start.
    #
    # Session-scoped, never global: tmux's session-beats-global inheritance is
    # what keeps the theme plugin's globals untouched, so this needs zero
    # tmux.conf changes. Idempotent because #call probes `has-session` first, so
    # a second `lain up` re-applies the same harmless option writes rather than
    # spawning a duplicate.
    #
    # Every tmux invocation goes through Mixlib::ShellOut with an ARGV array,
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

      # tmux's OWN format syntax, single-quoted so it reaches tmux byte for
      # byte. Every pane is asked for its id as it is made, because the window
      # holds more than one now and "the chat pane" can no longer be spelled
      # as the window: tmux resolves a window target to its ACTIVE pane, and
      # the active one is the pane the human types in, by design.
      # rubocop:disable Lint/InterpolationCheck
      PANE_ID = '#{pane_id}'
      # rubocop:enable Lint/InterpolationCheck

      # Rows for the input pane. It is the human's whole surface -- the chat's
      # HUD line, the prompt under it, and room for a countdown rail or a
      # completion menu without either scrolling the header away -- and every
      # row it takes comes off the transcript above it rather than off the
      # editor beside it.
      INPUT_PANE_HEIGHT = 6

      # The shortest window that can seat both panes: the input pane's rows,
      # as many again for the transcript, and the divider between them.
      #
      # THE DEGRADE IS THIS THRESHOLD, stated rather than left to tmux: below
      # it the rows are not there to take, so lain stops asking for them and
      # a one-row prompt, which still types, sits under a transcript that
      # keeps the rest.
      #
      # What a terminal shorter than that actually gets is tmux's arithmetic
      # and not lain's, with one measured caveat: at a 10-row client tmux
      # accepts and ignores EVERY layout change -- `resize-pane` in either
      # direction, `select-layout even-vertical` -- and merely evaluating the
      # guard inside the layout hook makes it re-apply the layout's own cell
      # sizes, so the input pane keeps its six and the transcript is left
      # two. Neither split is a cockpit at that size, and the rows come back
      # correctly the moment the terminal can seat them (measured: back to 24
      # rows restores 16 over 6).
      SEATED_WINDOW_HEIGHT = (INPUT_PANE_HEIGHT * 2) + 1

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
      # than "duplicating"; `warnings` carries the notices the exe says before
      # attaching -- a missing nvim, an unlocatable plugin -- so a degraded
      # cockpit is never a silent one.
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

      # Which panes `lain up` built, recorded on the tmux session itself, and
      # the two things the session then keeps true about them.
      #
      # A user option rather than a file, because it lives exactly as long as
      # the session does: a killed server leaves nothing behind to mislead the
      # next launch, and there is no pid anywhere to go stale.
      #
      # Every pane is named, the editor included and the ABSENT editor too --
      # so "is there an editor in this window?" is a question about a pane lain
      # made, not about how many panes happen to be there. The count answers
      # nothing: a chat over its input pane is two panes, and so is a cockpit
      # whose human split a shell into it.
      class Panes
        CHAT = "@lain_chat_pane"
        INPUT = "@lain_input_pane"
        EDITOR = "@lain_editor_pane"

        # `--no-nvim`, or a cockpit that degraded for want of the binary.
        # Recorded rather than left unset, so a window lain built says "no
        # editor" and only a window lain did not build says nothing at all.
        NO_EDITOR = ""

        # What the session does whenever its layout settles. tmux hands a
        # window's rows out afresh on every attach and resize and takes them
        # off the BOTTOM pane first, so the rows `split-window -l` asked for
        # last exactly until somebody looks at the cockpit: measured on 3.7b,
        # a 24-row terminal left the input pane at ONE row with the HUD gone.
        #
        # `window-layout-changed`, NOT `client-resized`: measured on the same
        # tmux, a client resize fires `client-resized` BEFORE the window has
        # been resized, so a hook there reads the old geometry and whatever it
        # resizes is undone by the redistribution that follows (6 rows became
        # 11 on a grow and 1 on a shrink). The layout hook fires after.
        #
        # A FLOOR, NOT A FIXED HEIGHT, which is the pane-height half of the
        # condition and a trade worth stating in both directions. The hook
        # fires on a deliberate `resize-pane` too, so seating unconditionally
        # made `prefix + arrow` on this pane inert -- fifteen rows asked for,
        # six given back. Firing only from BELOW leaves that human alone; what
        # it costs is that a growing window keeps tmux's own larger share
        # instead of snapping back to six, and that a human who shrinks the
        # pane UNDER the floor will see it restored at the next layout change.
        #
        # The window half is {Up::SEATED_WINDOW_HEIGHT}'s degrade, with no
        # else branch on purpose: measured, every size a hook could ask for
        # below the threshold is either what tmux already did or a request
        # tmux refuses. Both are evaluated `-t` the input pane, so a fork
        # window's geometry cannot answer for the chat window's.
        #
        # ARITHMETIC, not tmux's comparison operators: measured, `#{<:}` and
        # its kin compare STRINGS -- `#{<:15,6}` is 1 -- so a pane at fifteen
        # rows read as "below six" and the guard would have been decoration.
        # `#{e|-:}` is real arithmetic, so the SIGN of the difference is the
        # answer and `#{m:-*,...}` reads it; both halves are spelled as a
        # strict "is negative" so neither needs a negation or a ternary.
        SEAT_INPUT = "if -F -t %<input>s " \
                     '"#{&&:#{m:-*,#{e|-:%<too_short>d,#{window_height}}},' \
                     '#{m:-*,#{e|-:#{pane_height},%<rows>d}}}" ' \
                     '"resize-pane -t %<input>s -y %<rows>d"'

        # And what it does once a human is looking. {Up#run_chat} makes the
        # chat pane hold its screen on ANY exit, which is what lets a chat that
        # exited 0 be quoted rather than found missing; from the attach on, the
        # window's own `failed` governs it again, so an ordinary `/exit` still
        # closes the cockpit rather than leaving a corpse in it.
        RELEASE_CHAT = "set-option -p -t %<chat>s remain-on-exit failed"

        # @param tmux [Tmux] the server the session lives on
        # @param session [String] the session the options are written to
        # @param window [String] the chat window, whose panes are counted
        def initialize(tmux:, session:, window:)
          @tmux = tmux
          @session = session
          @window = window
        end

        # @param chat [String] the chat pane's id
        # @param input [String] the input pane's id
        # @param editor [String] the editor pane's id, or {NO_EDITOR}
        def record(chat:, input:, editor:)
          { CHAT => chat, INPUT => input, EDITOR => editor }
            .each { |name, id| @tmux.act("set-option", "-t", @session, name, id) }
          enforce(chat:, input:)
        end

        # The same two rules, re-asserted from what the session already
        # records -- {Up#keep_failed_pane}'s reason, and its argument
        # verbatim: a session `lain up` did not build this time, or built
        # before these hooks existed, still earns them. Without it anyone who
        # upgrades with a cockpit open keeps a one-row input pane until they
        # kill the session, and `lain up` is the command they would reach for.
        def rearm = enforce(chat: option(CHAT), input: option(INPUT))

        # {NO_EDITOR} and an unset option are both the empty string, which
        # `list-panes` can never answer with -- so a window with no editor
        # recorded, and a window lain never built, both fall out as false
        # without a guard.
        #
        # @return [Boolean] whether the editor pane this window was built with is still in it
        def editor? = live.include?(option(EDITOR))

        private

        # A pane lain cannot name is a hook it must not write: an empty target
        # would arm `resize-pane -t  -y 6`, which is a tmux error on every
        # layout change rather than a missing nicety.
        def enforce(chat:, input:)
          unless input.empty?
            # `too_short` is the tallest window that CANNOT seat both, so the
            # hook's own test is the strict one arithmetic makes cheapest.
            arm(SEAT_INPUT, "window-layout-changed", input:, too_short: SEATED_WINDOW_HEIGHT - 1,
                                                     rows: INPUT_PANE_HEIGHT)
          end
          arm(RELEASE_CHAT, "client-attached", chat:) unless chat.empty?
          self
        end

        # Best-effort, {Up#keep_failed_pane}'s rule: a tmux too old for a hook,
        # a format comparison or a pane-scoped option must lose the nicety
        # rather than the cockpit.
        def arm(recipe, event, **fields)
          @tmux.run("set-hook", "-t", @session, event, format(recipe, **fields))
        end

        # tmux exits nonzero on a user option nobody ever set, which is the
        # ordinary answer here rather than a failure -- hence {Tmux#run}.
        def option(name)
          answer = @tmux.run("show-options", "-v", "-t", @session, name)
          answer.exitstatus&.zero? ? answer.stdout.strip : ""
        end

        def live = @tmux.run("list-panes", "-t", @window, "-F", PANE_ID).stdout.split
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
        # byte.
        # rubocop:disable Lint/InterpolationCheck
        FORMAT = '#{pane_dead} #{pane_dead_status}'
        # rubocop:enable Lint/InterpolationCheck

        # Built where the pane is handed its command, because the grace it
        # measures is the PANE's life: there is no constructing one early and
        # arming it later, and no corpse for a pane that was never spawned.
        #
        # @param tmux [Tmux] the same server {Up} built the session on
        # @param target [String] the CHAT PANE's id, never the window: a
        #   window target resolves to whichever pane is active, and the active
        #   one is the input pane the human was left in, so a window here
        #   reports the input pane's health and captures its screen
        # @param session [String] the session that will survive the pane, named
        #   separately because the advice is spelled in tmux's own words and
        #   `kill-session` takes a session rather than a window
        # @param noun [String] what to call this pane in the sentence
        # @param consequence [String] what its death costs this launch, which
        #   is the one thing a corpse cannot know: the same death refuses the
        #   attach for the chat pane and merely warns for the input pane
        # @param clock [#call] the monotonic source the grace is measured
        #   against, defaulted from {RunClock::MONOTONIC} because that constant
        #   is spec'd to have exactly one site -- and because it lets a spec pin
        #   the poll in probe counts rather than in wall time
        def self.watching(tmux:, target:, session:, noun:, consequence:, clock: RunClock::MONOTONIC)
          new(tmux:, target:, session:, noun:, consequence:, clock:)
        end

        def initialize(tmux:, target:, session:, noun:, consequence:, clock: RunClock::MONOTONIC)
          @tmux = tmux
          @target = target
          @session = session
          @noun = noun
          @consequence = consequence
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
          return vanished unless answer.exitstatus&.zero?

          dead, status = answer.stdout.strip.split(" ", 2)
          dead == "1" ? status.to_s : :alive
        rescue StandardError
          :unanswerable
        end

        # A pane the SERVER does not list is a pane that exited and was not
        # held -- a death with no status left to report, and the one shape
        # that used to reach the operator as a cockpit with no chat in it and
        # nothing said anywhere.
        #
        # Asked of the server's whole pane list rather than of `has-session`,
        # so the two failures stay apart: a probe that merely could not run
        # leaves the pane listed and reads, correctly, as "tmux would not
        # say". A diagnostic that cannot tell must never close a cockpit that
        # would otherwise open.
        #
        # @return [String, :unanswerable]
        def vanished
          listed = @tmux.run("list-panes", "-a", "-F", PANE_ID)
          return :unanswerable unless listed.exitstatus&.zero?

          listed.stdout.split.include?(@target) ? :unanswerable : ""
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
          "the #{@noun} pane #{died} moments after `lain up` started it, #{@consequence}. " \
            "Session '#{@session}' survives with the dead pane in it: another `lain up` attaches to " \
            "it as it stands, `tmux kill-session -t #{@session}` clears it for a fresh start. " \
            "What the #{@noun} pane held:\n\n#{held}"
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

      # "Is this one installed, and does it answer?" -- asked of `nvim` for the
      # cockpit. `--version` is the probe because it is the one flag such a
      # binary has and does no work for, and ENOENT is the answer that matters:
      # an absent binary is a DEGRADE here, never an error, so the rescue is the
      # point of the object rather than a guard on it.
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

      # The planning half of `lain up --nvim`: the shared socket and the nvim
      # pane's command. The socket is computed ONCE here and handed to both
      # panes explicitly, so agreement is by construction rather than two sides
      # re-deriving the convention. `option` is the resolved answer to two
      # flags, not the spelling of either: nil is `--no-nvim`, "" derives the
      # plugin's deterministic socket, a non-empty String is used verbatim.
      class Cockpit
        # A relative socket resolves against each pane's own directory, so
        # requiring an absolute path is the rule rather than a formatting
        # preference -- the socket is the ONE name the editor and the chat must
        # agree on.
        #
        # It also refuses a Thor quirk exactly, without knowing about Thor: a
        # BARE `--nvim-socket` makes Thor supply the flag's own name, so the
        # cockpit would listen on a relative file called `nvim_socket`.
        # Comparing against the flag's name would be a heuristic; "not an
        # absolute path" is the rule the socket needs anyway.
        class UnusableSocket < Error
          def initialize(option)
            super("--nvim-socket #{option.inspect} is not an absolute path -- the nvim socket is the one " \
                  "name the editor pane and the chat pane must agree on, and a relative one resolves " \
                  "against whichever pane reads it. Write `--nvim-socket=/path/to.sock`, or leave the " \
                  "flag off to use the per-project socket lain derives.")
          end
        end

        def initialize(option:, cwd:, paths:)
          @option = option
          @cwd = cwd
          @paths = paths
        end

        def requested? = !@option.nil?

        # The whole of the layout wiring: `:LainStart` lays out now if lain has
        # attached, else arms a one-shot so the views open when the sibling
        # pane's `chat --nvim` lands. The rtp injection through `--cmd` is
        # evaluated before nvim sources rtp `plugin/` files, which is what makes
        # `:LainStart` exist with zero user config.
        #
        # THE SHAPE IS FORCED twice over, both halves measured on 2026-08-05
        # against nvim 0.12.4:
        #
        # 1. NOT `if exists(':LainStart') | LainStart | endif`, the idiom this
        #    wants: `-c` takes ONE Ex command, so every bar-chained form dies on
        #    `E488: Trailing characters` at the first bar -- `if|endif`,
        #    `try|endtry`, even `execute`. The cost was total: nvim came up on
        #    the "Press ENTER" prompt, never served its socket, and
        #    `chat --nvim` waited in ep_poll forever.
        # 2. NOT `silent! LainStart`, which fixes that and hides the next fault:
        #    it swallows any error `:LainStart` ITSELF raises, and shipped just
        #    long enough to find a layout that never opened, in silence. The
        #    ternary guards existence instead, so a bare `nvim --listen` is
        #    unharmed and a real failure reaches the screen.
        LAIN_START = "execute exists(':LainStart') ? 'LainStart' : ''"

        # Suppresses the user's start screen, which would otherwise cover the
        # cockpit until the first view arrives: a dashboard plugin draws over
        # exactly the empty unnamed buffer nvim boots into, and the cockpit's
        # nvim boots into nothing by design.
        #
        # NAMING the buffer is what trips snacks' own guard, measured against
        # nvim 0.12.4: it bails with reason "buffer has a name". The
        # neighbouring `argc(-1) > 0` guard looks more portable and is wrong
        # here -- the only argument worth passing is the project directory, and
        # snacks RE-enables the dashboard for a lone directory argument when its
        # explorer is on.
        #
        # Scheme-shaped so `:file` leaves it alone: a bare word is taken as a
        # relative filename and expanded against the cwd, which showed up as a
        # buffer named for a path in the project that nobody could open.
        #
        # `lain-cockpit://`, NOT `lain://`: init.lua's fallback scan treats
        # every `lain://` buffer as layout-eligible, and this is a placeholder
        # the runtime never created.
        SCRATCH_BUFFER = "file lain-cockpit://start"

        # Scoped to the ONE buffer this pane just named, not the whole nvim
        # process: `:h 'swapfile'` is local to buffer, so a bare `set
        # noswapfile` (`--cmd`/`-c` alike) or the `-n` startup flag -- which
        # resets the GLOBAL default rather than scoping anything -- would
        # silently disable swap recovery for every file a human later opens
        # in the review tab.
        #
        # BEFORE `SCRATCH_BUFFER`, not after: measured directly against nvim
        # 0.12.4, `:file` renames the buffer in place without touching its
        # buffer-local options, so a `setlocal` issued first survives the
        # rename. Issued after is too late regardless -- `:file` is what
        # CREATES the buffer's swapfile, so by the time a trailing `setlocal
        # noswapfile` would run, a second cockpit's `-c SCRATCH_BUFFER` has
        # already collided with a dirty peer's and nvim is blocked on "Press
        # ENTER", never reaching this `-c` at all.
        #
        # Two cockpits on two different projects otherwise collide on this
        # one swap path -- `SCRATCH_BUFFER` is a constant, not derived from
        # cwd -- and the cockpit's scratch buffer is DIRTY as soon as a view
        # lands, which is its steady state and exactly what trips `E325`
        # (dirty, not "busy": an unmodified peer's swapfile collides onto
        # `.swo` in silence instead). nvim's own recovery prompt for that
        # blocks the pane before it serves RPC, so `lain://approval`/
        # `:LainApprove` are unreachable while the chat pane looks healthy
        # from outside.
        NO_SWAPFILE = "setlocal noswapfile"

        def nvim_pane_command
          Shellwords.join(["nvim", *rtp_flag, "--listen", socket,
                           "-c", NO_SWAPFILE, "-c", SCRATCH_BUFFER, "-c", LAIN_START])
        end

        def chat_flags = ["--nvim", socket]

        # EMPTY IS THE DERIVE SENTINEL, deliberately: `--nvim-socket ""` is an
        # empty shell variable, and "an empty flag means no flag" is the reading
        # `--root` already takes. Anything else must be ABSOLUTE -- see
        # {UnusableSocket}.
        def socket
          @socket ||= begin
            raise UnusableSocket, @option unless @option.empty? || @option.start_with?(File::SEPARATOR)

            @option.empty? ? derived_socket : @option
          end
        end

        # The degrade case: the shipped plugin cannot be located. The cockpit
        # still opens either way -- see {#rtp_flag}.
        def plugin_missing? = !Dir.exist?(@paths.nvim_plugin_root)

        def nvim_plugin_root = @paths.nvim_plugin_root

        private

        def rtp_flag
          return [] if plugin_missing?

          ["--cmd", "set rtp+=#{nvim_plugin_root}"]
        end

        # The plugin's own convention byte-for-byte, with `Paths#project_hash`
        # as the Ruby twin of its sha256(getcwd). The 0700 directory is ensured
        # only on THIS derived path: runtime_dir is ours to create, where an
        # explicit --nvim-socket's parent is the caller's.
        def derived_socket
          File.join(@paths.runtime_dir, "nvim-#{@paths.project_hash(@cwd)}.sock").tap do |sock|
            FileUtils.mkdir_p(File.dirname(sock), mode: 0o700)
          end
        end
      end

      # The status-right HUD's string composition. Everything here is a STRING
      # for tmux's own `$SHELL -c` at the `#(...)` job boundary {Up}'s class
      # comment explains, so state_path is escaped for THAT shell, not ours.
      class Hud
        # The HUD arrives ALREADY RENDERED, in {Lain::StatusFeed}'s `hud` field
        # -- glyph, counts, the clamped context percentage, the run's token
        # spend and the composed mode lighter, all of it composed once by
        # {Lain::StatusFeed::Reading}. So this job's whole work is picking one
        # field out of one line, and the seven-line jq program it replaces (plus
        # its byte-for-byte twin in `plugin/tmux/scripts/lain-status`, plus a
        # named warning for a missing `jq`) is gone with it.
        #
        # NO `$` ANYWHERE, and that is the one rule shaping this. tmux 3.4
        # escapes a `$` in an option value to a backslash-dollar and stores it
        # escaped (3.8 does not), so the job tmux later hands the shell is a
        # syntax error -- swallowed by the `2>/dev/null` below, leaving a
        # permanent "lain: no state yet" on every tmux 3.4, which is Ubuntu
        # 24.04's and every GitHub runner's. That is why this reads the field
        # with `sed` rather than with the parameter expansion the shipped script
        # uses: a script FILE has no such rule and can be free of PATH entirely,
        # while an option value may not name a shell variable at all.
        #
        # Ending the field at the first `"` is sound rather than lucky:
        # {Lain::StatusFeed::Reading} strips `"`, `\` and `#` out of the one
        # segment that is free-form, and every other segment is a count or a
        # clamped percentage.
        EXTRACT = %q{sed -n 's/.*"hud":"\([^"]*\)".*/\1/p'}

        # How often tmux re-runs the `#(...)` job. A fact about this renderer --
        # what a redraw costs, how stale its numbers may get -- not about
        # sessions, windows or attaching, so it does not live on {Up}.
        DEFAULT_INTERVAL = 5

        # @param state_path [String] the state file the job reads, resolved by
        #   {Lain::ProjectDir#state_path} -- which today lives under
        #   `$XDG_STATE_HOME/lain`, not in the project
        # @param interval [Integer] seconds between re-renders; tmux's
        #   `status-interval`, which {Up} writes as a session option
        def initialize(state_path:, interval: DEFAULT_INTERVAL)
          @state_path = state_path
          @interval = interval
        end

        # `state_path` is public because the file sits in a directory named by
        # twelve hex characters of a hash, so {Up::Report#hud_line} has to tell
        # the operator where it is. Reading it hands out a name, not authority.
        attr_reader :interval, :state_path

        # `grep .` is the never-blank guard, and it is not decoration: an
        # ordinary fresh `up` window, before StatusFeed's first publish writes
        # `state.json`, leaves the extractor with nothing to print and rendered a
        # LITERALLY BLANK status-right (reproduced through an attached PTY
        # capture). Empty stdout fails `grep`, and `|| echo` then says so in
        # words -- which a state file from a lain too old to publish the field
        # reaches by the same route.
        #
        # @return [String] the status-right value
        def status_right
          "#(#{EXTRACT} #{Shellwords.escape(state_path)} 2>/dev/null | grep . || echo 'lain: no state yet')"
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
                     chat_command: nil, input_command: nil, chat_args: [],
                     status_interval: Hud::DEFAULT_INTERVAL,
                     nvim: nil, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new),
                     chat_preflight: ChatPreflight.new(shell_out_factory:, cwd:),
                     gc_schedule: GcSchedule.for(cwd:, paths:))
        @session = session
        @tmux = Tmux.new(socket:, shell_out_factory:)
        @cwd = cwd
        @paths = paths
        @panes = Panes.new(tmux: @tmux, session: @session, window: chat_target)
        @hud = Hud.new(state_path:, interval: status_interval)
        @chat_args = chat_args
        @chat_command = chat_command
        @input_command = input_command
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
      # The chat is probed BEFORE the input pane, always, whether or not the
      # chat turns out to be dead: raising the moment the chat's death was
      # known used to skip the input pane entirely, so an operator who lost
      # both panes at once was refused in the chat's words alone and sent
      # straight back into a session the refusal never mentioned had no
      # keyboard either. {PaneCorpse#call} is idempotent and bounded by its
      # own grace, so asking it here costs the failing path nothing new.
      #
      # @param nested [Boolean] forwarded to {#attach_command} unchanged
      # @return [LaunchPlan]
      # @raise [ChatDied] the chat pane died before anyone could attach to it
      def launch_plan(nested:)
        report = call
        died = @corpse&.call
        input_died = @input_corpse&.call
        raise ChatDied, [died, input_died].compact.join("\n\n") if died

        # A dead INPUT pane is not a reason to withhold the transcript, so it
        # is said rather than raised -- first, on {Report}'s warnings-first
        # rule.
        LaunchPlan.new(messages: [*input_died, *report.messages], argv: attach_command(nested:))
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
      #
      # ONE command for both shapes -- the cockpit's chat differs only by the
      # editor socket in front of the same flags -- so an injected
      # `chat_command:` overrides either.
      def chat_pane_command(editor_flags)
        @chat_command || PaneCommand.call("chat", *editor_flags, *input_flags, *@chat_args)
      end

      # The chat's end of the input rail, written before either process
      # exists: the socket carries no pid, so both panes can name it from the
      # project and the tmux SESSION alone -- the session, so two cockpits on
      # one project do not share one human.
      #
      # AHEAD of `@chat_args`, so an operator who typed their own `--input`
      # past the `--` still wins: Thor takes the last spelling of a flag.
      def input_flags = ["--input", "#{InputSocket::PREFIX}#{@session}"]

      # The pane's end of the same rail, by PATH rather than by name. Derived
      # once here and handed over, so the two ends cannot disagree about the
      # convention -- {Cockpit}'s rule for the editor socket, for the same
      # reason.
      def input_pane_command
        @input_command ||
          PaneCommand.call("input", "--socket", InputSocket.path(cwd: @cwd, name: @session, paths: @paths))
      end

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
      #
      # The window's own pane is asked for its id as it is opened, because
      # that is the only moment it is unambiguously THE pane: everything below
      # targets an id rather than the window, which tmux would resolve to
      # whichever pane is active by then.
      def create_session
        @warnings.concat(@chat_preflight.call(@chat_args))
        cockpit = cockpit_wanted?
        first = @tmux.act("new-session", "-d", "-s", @session, "-n", CHAT_WINDOW, "-c", @cwd,
                          "-x", DETACHED_WIDTH.to_s, "-y", DETACHED_HEIGHT.to_s,
                          "-P", "-F", PANE_ID).stdout.strip
        keep_failed_pane
        build_panes(cockpit, first)
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
      # EVERY PANE IS SPLIT BEFORE ANY PANE IS GIVEN A COMMAND, and the chat's
      # is given last. `remain-on-exit failed` REMOVES a pane that exits 0, so
      # while the chat ran before the split that hangs off it, a chat that
      # exited cleanly during start-up (`lain up -- --help`) took the pane the
      # input pane was about to split from: measured five times, four raised a
      # raw `can't find pane` out of tmux past {ChatDied}'s written sentence,
      # and the fifth won the race and attached the operator to a lone input
      # pane waiting forever for a chat that had gone. A login shell cannot
      # vanish in between.
      #
      # {PaneCorpse} starts its clock HERE for both panes. For the chat that
      # is its spawn, exactly; the input pane was spawned earlier, so its
      # grace is already partly spent and it only ever waits less.
      def build_panes(cockpit, first)
        editor = cockpit ? first : Panes::NO_EDITOR
        chat = cockpit ? split_chat_pane(first) : first
        input = spawn_input_pane(chat)
        @panes.record(chat:, input:, editor:)
        run_editor(first) if cockpit
        run_chat(chat, cockpit)
        # Where the human types is where the cursor belongs, stated rather than
        # left to the order the panes happened to be made in.
        @tmux.act("select-pane", "-t", input)
        watch_panes(chat:, input:)
      rescue StandardError
        @tmux.run("kill-session", "-t", @session)
        raise
      end

      # The chat pane holds its screen on ANY exit, not just a failing one:
      # that is what lets a chat which exited 0 be QUOTED rather than found
      # missing, and {Panes::RELEASE_CHAT} hands it back to the window's own
      # `failed` the moment a human attaches. Best-effort, {#keep_failed_pane}'s
      # rule -- a tmux without pane-scoped options must lose the diagnostic
      # rather than the cockpit.
      def run_chat(chat, cockpit)
        @tmux.run("set-option", "-p", "-t", chat, "remain-on-exit", "on")
        @tmux.act("respawn-pane", "-k", "-t", chat, "-c", @cwd,
                  chat_pane_command(cockpit ? @cockpit.chat_flags : []))
      end

      # Two corpses, and only one of them refuses. Nothing to attach TO is a
      # refusal; a cockpit with no keyboard is a sentence, because the
      # transcript is still worth reading and the human can still kill the
      # session from outside.
      def watch_panes(chat:, input:)
        @corpse = PaneCorpse.watching(tmux: @tmux, target: chat, session: @session,
                                      noun: "chat", consequence: "so this did not attach")
        @input_corpse = PaneCorpse.watching(tmux: @tmux, target: input, session: @session, noun: "input",
                                            consequence: "so this cockpit has no keyboard -- a chat reading " \
                                                         "its human from a pane reads no stdin of its own")
      end

      # Split off the CHAT pane rather than the window, which is what puts it
      # under the transcript instead of under the whole cockpit: a window
      # split would run the full width and take its rows from the editor too.
      #
      # @return [String] the input pane's id
      def spawn_input_pane(chat)
        @tmux.act("split-window", "-v", "-l", INPUT_PANE_HEIGHT.to_s, "-t", chat, "-c", @cwd,
                  "-P", "-F", PANE_ID, input_pane_command).stdout.strip
      end

      # Reattaching rebuilds nothing, so all it owes is the missing-editor
      # warning and a re-assert of the two things a session carries rather
      # than a pane: a session `lain up` did not create, or created before
      # either of them did, still earns its corpse and its seating.
      def reattach_session
        warn_editorless_reattach
        keep_failed_pane
        @panes.rearm
      end

      # The degrade contract, and its "degraded is never silent" rule: no nvim
      # binary means a single chat pane plus a named warning, probed only on the
      # create path.
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

      # Reattaching with --nvim: #create_session never ran, so a window with no
      # EDITOR pane means the request is being ignored, and degraded is never
      # silent. Asked of {Panes} rather than of the pane count, which answers
      # two for a plain chat over its input pane as readily as for half a
      # cockpit.
      def warn_editorless_reattach
        return unless @cockpit.requested? && !@panes.editor?

        @warnings << "session '#{@session}' already exists without the nvim pane -- reattaching as-is " \
                     "(kill the session and re-run `lain up --nvim` for the cockpit, or attach plain)"
      end

      # Opened EMPTY, carrying tmux's default shell, for {#build_panes}'s
      # reason: the pane the input pane splits from must be one that cannot
      # exit on its own. Its command arrives on {#run_chat}'s respawn.
      #
      # @return [String] the chat pane's id
      def split_chat_pane(first)
        @tmux.act("split-window", "-h", "-t", first, "-c", @cwd, "-P", "-F", PANE_ID).stdout.strip
      end

      # Every pane pinned to ONE cwd with tmux's -c and the editor handed ONE
      # socket, so the convention cannot silently diverge between the editor
      # and the chat that attaches to it.
      def run_editor(editor)
        warn_missing_plugin
        @tmux.act("respawn-pane", "-k", "-t", editor, "-c", @cwd, @cockpit.nvim_pane_command)
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
        set_option("status-right", @hud.status_right)
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
