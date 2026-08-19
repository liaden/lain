# frozen_string_literal: true

module Lain
  module CLI
    # The chat lifecycle bracket, lifted out of the Thor executable the way
    # {Backend}, {Chronicle}, and {Wiring} were: resolve --resume, open the
    # journal, run the conversation, always close. The exe keeps the flag
    # declarations and the Lain::Error -> Thor::Error mapping; this object owns
    # the ORDER the bracket guarantees, so the invariants carry specs the way
    # lib/ does instead of hiding behind Thor private helpers.
    #
    # Collaborator factories are injected (the {Up} shell_out_factory model),
    # defaulting to the real things: specs drive the bracket -- refusal
    # ordering, ensure-close, conductor-vs-chronicle routing -- without a TTY,
    # a network edge, or global ENV mutation. Output discipline holds: notices
    # flow through {#call}'s block (the exe's `say`, the one output seam this
    # object is lent); nothing here touches $stdout.
    class ChatLaunch
      # Turns this launch into the construction-only check {#preflight}
      # describes, and nothing else -- read at the ONE place a chat becomes a
      # conversation, so a caller cannot get half of it.
      #
      # A MODE rather than a flag, and that is forced rather than chosen:
      # `lain up` is the only caller, it forwards the operator's `-- ARGS`
      # verbatim, and it is forbidden to add a word to that vector or even to
      # read one ({Up#default_chat_command}). An environment variable is the
      # one channel that reaches the child without touching the argv the
      # operator typed. `LAIN_DESKTOP` is the precedent for the spelling.
      PREFLIGHT_ENV = "LAIN_PREFLIGHT"

      # Exactly `1`, never "any non-empty value": `LAIN_PREFLIGHT=0` reads as
      # off to anyone who types it, and a chat that silently declined to
      # converse would look like a hang rather than like a mode.
      #
      # @param env [#[]] the environment; injected so a spec states its own
      # @return [Boolean]
      def self.preflight?(env = ENV) = env[PREFLIGHT_ENV].to_s.strip == "1"

      # @param options [Hash] the exe's parsed chat flags. Most are passed
      #   through whole to {Backend}, {LiveViews} and {Wiring} rather than read
      #   here — this object owns the bracket's ORDER, not the meaning of any
      #   one flag. The six it reads itself are the ones the ORDER depends on.
      # @param resume_factory [#call] builds the --resume resolver
      # @param chronicle_factory [#call] opens the run's chronicle
      # @param live_views_factory [#call] builds the editor views
      # @param wiring_factory [#call] assembles the chat
      # @param run_clock_factory [#call] the run's clock
      # @param project_factory [#call] resolves the run's {Project}; called
      #   ONCE, before the chronicle opens, so nothing downstream reads a cwd
      #   the project has not already settled
      # @param status_feed_factory [#call] the HUD's feed. Takes the run's
      #   `context_window:` as well as its `run_clock:`, so the occupancy
      #   published to `.lain/state.json` divides by the window the provider
      #   says it is serving rather than by {ContextWindow}'s conservative
      #   fallback -- see {Backend#context_window}.
      # @option options [Boolean] :journal whether the run records one
      # @option options [Boolean] :btw whether asides join the record
      # @option options [Boolean] :nvim whether the editor views open
      # @option options [Boolean] :windows whether the HUD panes open
      # @option options [String] :fork a session to fork from
      # @option options [String] :resume a session to resume
      # @return [ChatLaunch]
      def initialize(options,
                     resume_factory: -> { Resume.new },
                     chronicle_factory: Chronicle.public_method(:for),
                     live_views_factory: LiveViews.public_method(:new),
                     wiring_factory: Wiring.public_method(:new),
                     run_clock_factory: -> { Lain::RunClock.new },
                     project_factory: Lain::Project::Resolver.public_method(:default_project),
                     status_feed_factory: lambda { |run_clock:, context_window:|
                       Lain::StatusFeed.new(run_clock:, context_window:)
                     })
        @options = options
        @resume_factory = resume_factory
        @chronicle_factory = chronicle_factory
        @live_views_factory = live_views_factory
        @wiring_factory = wiring_factory
        @run_clock_factory = run_clock_factory
        @project_factory = project_factory
        @status_feed_factory = status_feed_factory
      end

      attr_reader :wiring, :live_views

      # The lifecycle bracket: resolve --resume, open the journal, run the
      # conversation, always close. Resume is resolved BEFORE open_chronicle so a
      # refusal (nothing to resume, an ambiguous selector, a mid-tool head) raises
      # before any journal file is opened -- a refusal never orphans a fresh
      # journal. A bare --resume arrives as "" (newest); absent as nil (a plain
      # new session).
      #
      # {PREFLIGHT_ENV} short-circuits the whole bracket to {#preflight}. The
      # branch is HERE, at the one place a chat becomes a conversation, so no
      # caller can reach the second half without it -- and the ensure below
      # still runs, closing the memoized Null chronicle a pre-flight leaves,
      # which is a no-op rather than a nil guard.
      def call(&notice)
        return preflight(&notice) if self.class.preflight?

        refuse_windows_without_journal!
        resumed = resumed_run(backend)
        resolve_project!
        open_chronicle
        converse(backend:, resumed:, &notice)
      ensure
        # Graceful close anchors the head; a hard kill skips this. Routed through
        # the conductor: its close is guarded, so a signal that already closed the
        # session (:interrupted / :grace_expired) makes this a no-op, and a plain
        # quit closes :exit. Falls back to the chronicle if the run raised before
        # wiring existed.
        (@wiring&.conductor || chronicle).close(reason: :exit)
        # Last-resort release of a held capped-overflow notice: the closers land
        # in the RAW journal, not the tee, so a failure path may never cross the
        # fleet sink's boundary recognition -- this teardown drain guarantees it.
        @live_views&.fleet&.drain_pending
      end

      # Every refusal `lain chat` raises before it reads a byte of the
      # terminal, with nothing opened and nothing asked of a server. `lain up`
      # runs this in a child process ({Up::ChatPreflight}) so a construction
      # refusal lands on the operator's own terminal rather than in a tmux pane
      # whose dead-pane banner eats the line naming the cause.
      #
      # ENUMERATED, and the enumeration is the maintenance cost: a refusal
      # added elsewhere on the launch path has to be added here too, or
      # `lain up` goes back to losing it. What keeps the list honest is the two
      # things it may not do.
      #
      # **It opens no record.** A refusal must never orphan a fresh journal --
      # #call's own ordering rule -- and this runs in a SECOND process, so a
      # file it opened would be one nothing else closes.
      #
      # **It asks no server anything.** An unreachable `--api-base` fails at
      # TURN level, not launch level, so refusing it here would stop the
      # cockpit opening for a model server that is merely down. That is why the
      # span policy resolves through {Backend::SpanSummarizer.resolve} and not
      # {Backend#pipeline_source}, which builds the window book off a live
      # round trip. Construction's one probe is `--num-ctx`'s own, bounded and
      # already degrading to "no ceiling knowable" when nothing answers.
      #
      # `--resume`/`--fork` are deliberately absent: resolving one reads the
      # record and may repair it, which is not construction, and doing it in
      # two processes would put that repair in the history twice. Their
      # refusals stay the pane's to report.
      #
      # @raise [Lain::Error] whatever the flags refuse, in the flag's own name
      # @return [nil]
      def preflight(&notice)
        refuse_windows_without_journal!
        resolve_project!
        constructed
        # A mode that says nothing looks exactly like a hang, and this one is
        # reachable by accident: LAIN_PREFLIGHT is inherited like any other
        # variable, so a stray one turns a `lain chat` somebody typed into a
        # process that exits 0 having done nothing. `lain up` reads the exit
        # status and ignores this line; a human reads the line.
        #
        # ⚠️ The `&.` is not defensive padding, and it is not free either:
        # **a caller that omits the block re-opens exactly that silent 0-byte
        # exit.** It stays because this method is a CHECK first and a mode
        # second -- its product is the raise, which needs nowhere to print, and
        # a dozen examples call it directly to ask "are these flags
        # constructible?". Requiring a block would make flag validation depend
        # on having somewhere to write, and raising for a missing one would
        # trade a latent silence for a latent FALSE REFUSAL, which `lain up`
        # would then relay to an operator as chat's own words.
        notice&.call("pre-flight only (#{PREFLIGHT_ENV} is set): these arguments construct, " \
                     "and no conversation was started")
        nil
      end

      # The session record opens FIRST (per --journal), then --nvim views tee
      # onto IT (LiveViews) -- inverted from the old "nvim first" order, which is
      # what let two independent Journal.open calls straddle a second tick and
      # split telemetry from the session file it belonged in.
      def open_chronicle
        @chronicle = @chronicle_factory.call(enabled: @options[:journal], btw: @options[:btw] || false)
        # A live-view tee is built for --nvim (its Channel) OR --journal (the state
        # feed publishes for the tmux HUD). Pure --no-journal --no-nvim opens none,
        # so a headless run stays byte-identical -- no tee, no state feed.
        return unless @options[:nvim] || @options[:journal]

        @live_views = @live_views_factory.call(options: @options, chronicle:, status_feed:)
      end

      # The ONE StatusFeed for the run, constructed on first read (here, in
      # open_chronicle, so it can sit in the tee's sink list) and threaded
      # unchanged into Wiring's Command::Env -- so /status reads the same live
      # instance the tee feeds. Exists even for a headless run (--no-journal
      # --no-nvim builds no tee), so /status still answers its honest zeros.
      def status_feed = @status_feed ||= @status_feed_factory.call(run_clock:, context_window: backend.context_window)

      # The ONE {Backend} for the run (T10), resolved on first read and shared
      # exactly as {#run_clock} and {#project} are. It was a local in {#call}
      # until the window book made it a THIRD thing two halves of the launch
      # need: the feed built in {#open_chronicle} divides occupancy by
      # {Backend#context_window}, and the wiring built in {#converse} hangs the
      # Agent and the compaction source off the same instance -- and that book
      # is memoized per Backend, so two Backends would be two probes and
      # possibly two answers across an ollama runner reload.
      def backend = @backend ||= Backend.new(@options)

      # The ONE RunClock for the run (T7). Its three measures are WRITTEN in
      # two places and READ in a third: the Conductor records a user prompt on
      # it, the tee's Telemetry::Compaction moves its compaction age, and the
      # StatusFeed publishes all three. Two instances would publish an `idle`
      # that never resets, so it is built here -- the one point above both --
      # and threaded down, exactly as the status feed is.
      def run_clock = @run_clock ||= @run_clock_factory.call

      # The ONE {Lain::Project} for the run (T5), resolved on first read and
      # threaded into the wiring exactly as {#run_clock} and {#status_feed} are.
      # Five collaborators down there take a root off it -- the isolation
      # backend, the command surface, the epic mount, the review seams -- and
      # the Session takes its cwd; two resolutions could hand them two different
      # projects, which is the failure a `Dir.pwd` apiece already was.
      def project = @project ||= @project_factory.call

      # A COMMAND, named as one, because a bare `project` in #call reads as dead
      # code and `Lint/Void` does not fire on a method call. What it does is
      # force the resolution to happen HERE, for #resumed_run's reason one line
      # above it: an unresolvable cwd or an unusable `$HOME` must refuse BEFORE
      # any journal file is opened, so a refusal never orphans a fresh journal.
      # Left to #converse's lazy read it would land after.
      def resolve_project! = project

      # The session record's lifecycle collaborator (journal, scribe, observer,
      # per-iteration durability -- see {Chronicle}). Defaults to the Null duck
      # so a directly-constructed instance records nothing and checks nothing
      # for nil; #call replaces it per the --journal flag before any wiring runs.
      def chronicle = @chronicle ||= Chronicle::Null.new

      private

      # The collaborators the flags decide, built and thrown away. Split out of
      # {#preflight} so that method reads as the three things it promises --
      # refuse, construct, say so -- and so the one refusal whose answer
      # depends on WHERE the check ran has somewhere honest to be re-stated.
      #
      # That refusal is the missing key, and it is the only environment-derived
      # one: every other flag arrives on the command line. A tmux server
      # started from a shell that HAS a key hands it to every pane it later
      # spawns, so "ANTHROPIC_API_KEY is not set" can be false of the place it
      # matters while being true of the place this check can see. The message
      # therefore says where it looked and what to do, rather than asserting a
      # global fact it is not in a position to know -- a refusal that states a
      # false cause is the thing this codebase's refusals exist to prevent.
      def constructed
        backend.provider
        backend.context
        # Gated, because a pre-flight must refuse a SUBSET of what chat
        # refuses and never a superset: under --no-compact chat resolves no
        # strategy, so a refusal here would reject a chat that would have run.
        Backend::SpanSummarizer.resolve(backend:, options: @options) if backend.compaction?
      rescue Backend::MissingAPIKey => e
        raise Backend::MissingAPIKey, "#{e.message} -- looked for in the environment this pre-flight " \
                                      "ran in, which is not the one a tmux server started elsewhere " \
                                      "hands its panes; export it here, or start that server from a " \
                                      "shell that has it"
      end

      # --windows observes the live-view tee, which --no-journal never builds;
      # refuse loudly up front rather than opening a chat whose flag is silently
      # dead (T20).
      def refuse_windows_without_journal!
        return unless @options[:windows] && !@options[:journal]

        raise Lain::Error, "--windows needs the session journal: the fleet sink observes " \
                           "the live-view tee, which --no-journal disables"
      end

      # Resolved BEFORE open_chronicle (see #call) so a resume/fork refusal
      # raises before any journal file is opened -- a refusal never orphans a
      # fresh journal. A bare --resume arrives as "" (newest); absent as nil.
      # --fork opens the parent read-only (never salvages it) and wins over
      # --resume when both are given.
      def resumed_run(backend)
        return @resume_factory.call.fork(selector: @options[:fork], model: backend.context.model) if @options[:fork]

        @options[:resume] && @resume_factory.call.call(selector: @options[:resume], model: backend.context.model)
      end

      # The --nvim wiring bits the Repl builds its Neovim frontend from, or nil.
      def nvim_views = @live_views&.views

      # The wiring half of #call, split out so call stays the resolve-and-close
      # bracket it reads as; @wiring is instance state because the ensure closes
      # its conductor.
      def converse(backend:, resumed:, &notice)
        @wiring = @wiring_factory.call(options: @options, chronicle:, status_feed:, run_clock:, project:)
        @wiring.run(backend:, resumed:, nvim: nvim_views, &notice)
      end
    end
  end
end
