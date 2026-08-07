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
      DEFAULT_STATUS_INTERVAL = 5

      # `created` tells the caller whether a fresh session was just built (so
      # it can say so before attaching) or one was already running (so a
      # second `lain up` reads as "reattaching", never "duplicating").
      # `warnings` carries the jq-missing notice, if any -- the exe `say`s it
      # before attaching so a degraded HUD is never a SILENT one.
      Report = Data.define(:session, :created, :warnings) do
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
      def initialize(session: DEFAULT_SESSION, socket: nil, cwd: Dir.pwd,
                     state_path: ProjectDir.new(root: cwd).state_path,
                     chat_command: nil, chat_args: [], status_interval: DEFAULT_STATUS_INTERVAL,
                     nvim: nil, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @session = session
        @socket = socket
        @cwd = cwd
        @hud = Hud.new(state_path:)
        @chat_args = chat_args
        @chat_command = chat_command || default_chat_command
        @status_interval = status_interval
        @cockpit = Cockpit.new(option: nvim, cwd:, paths:)
        @shell_out_factory = shell_out_factory
        @warnings = []
      end

      # @return [Report]
      # @raise [TmuxUnavailable] no tmux on PATH, or a real tmux failure --
      #   never a bare Errno/Mixlib exception past this boundary.
      def call
        created = !session_exists?
        created ? create_session : warn_unsplit_reattach
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
      # @param nested [Boolean] forwarded to {#attach_command} unchanged
      # @return [LaunchPlan]
      def launch_plan(nested:)
        report = call
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
      def attach_command(nested:)
        verb = nested ? "switch-client" : "attach"
        ["tmux", *socket_flag, verb, "-t", @session]
      end

      private

      # The one query that TOLERATES a nonzero exit: "no such session" is the
      # expected, non-error answer that drives #call into #create_session.
      def session_exists? = run("has-session", "-t", @session).exitstatus.zero?

      # {.pane_command} over the `chat` subcommand. `@chat_args` is the exe's
      # `-- ARGS` trailing capture -- already `chat`'s own flags to validate,
      # never Up's, so the recipe only Shellwords-escapes each one before it
      # lands in a string tmux hands to ITS OWN `$SHELL -c` (the class
      # comment's shell-boundary note); Up never parses or knows the flag
      # names.
      def default_chat_command = self.class.pane_command("chat", *@chat_args)

      def create_session
        cockpit_wanted? ? create_cockpit_session : act(*new_session_args)
      end

      # `-c` on the plain window too, not only on the cockpit's two panes: a
      # `--no-nvim` session that inherited tmux's default-path would run its
      # chat wherever the tmux SERVER was started, which is a different project
      # from the one `lain up PATH` names and from the one the HUD reads.
      def new_session_args
        args = ["new-session", "-d", "-s", @session, "-n", CHAT_WINDOW, "-c", @cwd]
        @chat_command ? args + [@chat_command] : args
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
        return true if binary_present?("nvim")

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
        run("list-panes", "-t", "#{@session}:#{CHAT_WINDOW}").stdout.lines.size < 2
      end

      # The cockpit split, per {Cockpit}'s plan: both panes pinned to ONE cwd
      # (tmux -c) and handed ONE socket, so the convention cannot silently
      # diverge between the editor and the chat that attaches to it.
      def create_cockpit_session
        warn_missing_plugin
        act("new-session", "-d", "-s", @session, "-n", CHAT_WINDOW, "-c", @cwd, @cockpit.nvim_pane_command)
        act("split-window", "-h", "-t", "#{@session}:#{CHAT_WINDOW}", "-c", @cwd,
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
        status_right, warning = @hud.status_right(jq_present: binary_present?("jq"))
        @warnings << warning if warning
        set_option("status-right", status_right)
        set_option("status-interval", @status_interval.to_s)
        act("set-window-option", "-t", "#{@session}:#{CHAT_WINDOW}", "monitor-bell", "on")
        keep_failed_pane
      end

      # A chat pane that dies takes its error message with it, and when it is
      # the session's only pane it takes the whole tmux SERVER too -- so a
      # refusal that printed a perfectly clear line (a missing API key, an
      # unknown provider) reaches the operator as a terminal that blinks once
      # and returns to the shell. That is how the 2026-08-06 report ("starts
      # and immediately crashes") looked from the outside, with the actual
      # cause legible only from a probe socket with remain-on-exit forced on.
      #
      # `failed` and not `on`: a clean exit should still close the pane, so
      # this costs nothing in the ordinary case and only holds the screen when
      # there is something to read.
      #
      # #run, not #act -- best-effort ON PURPOSE. `failed` needs tmux >= 3.2,
      # and failing `lain up` outright on an older tmux would trade a working
      # cockpit for a diagnostic nicety. A tmux too old simply keeps today's
      # behaviour.
      def keep_failed_pane = run("set-window-option", "-t", "#{@session}:#{CHAT_WINDOW}", "remain-on-exit", "failed")

      def set_option(name, value) = act("set-option", "-t", @session, name, value)

      # Every MUTATING tmux call (as opposed to #session_exists?'s query)
      # goes through here so a real failure -- a broken or sandboxed tmux
      # that cannot spawn a server at all, not just "no session yet" -- fails
      # this method loudly instead of leaving a half-configured session with
      # no error anywhere.
      def act(*args)
        shell_out = run(*args)
        raise TmuxUnavailable, "tmux #{args.first} failed: #{shell_out.stderr.strip}" unless shell_out.exitstatus.zero?

        shell_out
      end

      def run(*)
        @shell_out_factory.call("tmux", *socket_flag, *).tap(&:run_command)
      rescue Errno::ENOENT
        raise TmuxUnavailable, "tmux not found on PATH -- install it (or fix PATH) before `lain up`"
      end

      def socket_flag = @socket ? ["-L", @socket] : []

      def binary_present?(binary)
        @shell_out_factory.call(binary, "--version").tap(&:run_command).exitstatus.zero?
      rescue Errno::ENOENT
        false
      end
    end
  end
end

# Both reopen the Up class body above, so they load after it (the same
# load-order note effect/handler.rb's children carry).
require_relative "up/cockpit"
require_relative "up/hud"
require_relative "up/pane_command"
