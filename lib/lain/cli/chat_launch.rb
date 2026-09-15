# frozen_string_literal: true

module Lain
  module CLI
    # The chat lifecycle bracket: resolve --resume, open the journal, run the
    # conversation, always close. The exe keeps the flag declarations and the
    # Lain::Error -> Thor::Error mapping; this object owns the ORDER the
    # bracket guarantees, so those invariants carry specs instead of hiding
    # behind Thor private helpers.
    #
    # Collaborator factories are injected and default to the real things, so
    # specs drive the bracket -- refusal ordering, ensure-close,
    # conductor-vs-chronicle routing -- without a TTY, a network edge, or
    # global ENV mutation. Notices flow through {#call}'s block (the exe's
    # `say`); nothing here touches $stdout.
    class ChatLaunch
      # A MODE rather than a flag, and forced: `lain up` forwards the operator's
      # `-- ARGS` verbatim and may not add a word to that vector
      # ({Up#default_chat_command}), so an environment variable is the one
      # channel that reaches the child without touching the argv they typed.
      PREFLIGHT_ENV = "LAIN_PREFLIGHT"

      # Exactly `1`, never "any non-empty value": `LAIN_PREFLIGHT=0` reads as
      # off to anyone who types it, and a chat that silently declined to
      # converse would look like a hang rather than like a mode.
      #
      # @param env [#[]] the environment; injected so a spec states its own
      # @return [Boolean]
      def self.preflight?(env = ENV) = env[PREFLIGHT_ENV].to_s.strip == "1"

      # @param options [Hash] the exe's parsed chat flags. Most pass through
      #   whole to {Backend}, {LiveViews} and {Wiring} rather than being read
      #   here: this object owns the bracket's ORDER, not the meaning of any
      #   one flag.
      # @param profile [RunProfile] the backend the command line and the
      #   environment resolved, carrying which fields were typed; the exe
      #   builds it, and a chat forked or resumed lays it over the recording
      # @param resume_factory [#call] builds the --resume resolver
      # @param chronicle_factory [#call] opens the run's chronicle
      # @param live_views_factory [#call] builds the editor views
      # @param wiring_factory [#call] assembles the chat
      # @param run_clock_factory [#call] the run's clock
      # @param project_factory [#call] resolves the run's {Project}; called
      #   ONCE, before the chronicle opens, so nothing downstream reads a cwd
      #   the project has not already settled
      # @param status_feed_factory [#call] the HUD's feed. Takes a
      #   `context_window:` so published occupancy divides by the window the
      #   provider says it is serving rather than by {ContextWindow}'s
      #   conservative fallback -- see {Backend#context_window}.
      # @param gc_schedule_factory [#call] builds the daily reap's {GcSchedule}
      #   for the project's root; the real one spawns with the real process
      #   spawner
      # @param env [#[]] the environment, read for $TMUX by
      #   {#refuse_windows_outside_tmux!}
      # @option options [Boolean] :journal whether the run records one
      # @option options [Boolean] :btw whether asides join the record
      # @option options [Boolean] :nvim whether the editor views open
      # @option options [Boolean] :windows whether the HUD panes open
      # @option options [String] :fork a session to fork from
      # @option options [String] :resume a session to resume
      # @return [ChatLaunch]
      def initialize(options,
                     profile: RunProfile.from_options(options),
                     resume_factory: -> { Resume.new },
                     chronicle_factory: Chronicle.public_method(:for),
                     live_views_factory: LiveViews.public_method(:new),
                     wiring_factory: Wiring.public_method(:new),
                     run_clock_factory: -> { Lain::RunClock.new },
                     project_factory: Lain::Project::Resolver.public_method(:default_project),
                     gc_schedule_factory: GcSchedule.public_method(:new),
                     status_feed_factory: lambda { |run_clock:, context_window:|
                       Lain::StatusFeed.new(run_clock:, context_window:)
                     },
                     env: ENV)
        @options = options
        @typed_profile = profile
        @resume_factory = resume_factory
        @chronicle_factory = chronicle_factory
        @live_views_factory = live_views_factory
        @wiring_factory = wiring_factory
        @run_clock_factory = run_clock_factory
        @project_factory = project_factory
        @status_feed_factory = status_feed_factory
        @gc_schedule_factory = gc_schedule_factory
        @env = env
      end

      attr_reader :wiring, :live_views

      # The lifecycle bracket. Resume is resolved BEFORE open_chronicle so a
      # refusal (nothing to resume, an ambiguous selector, a mid-tool head)
      # raises before any journal file is opened -- a refusal never orphans a
      # fresh journal. A bare --resume arrives as "" (newest); absent as nil.
      #
      # {PREFLIGHT_ENV} short-circuits the whole bracket to {#preflight}. The
      # branch is HERE, at the one place a chat becomes a conversation, so no
      # caller can reach the second half without it -- and the ensure still
      # runs, closing the Null chronicle a pre-flight leaves.
      def call(&notice)
        return preflight(&notice) if self.class.preflight?

        refuse_contradictory_flags!
        refuse_windows_outside_tmux!
        # Ahead of everything that writes or spawns -- a salvaged resume, the
        # reap, the record -- so a refused run leaves none of them behind. Not
        # at construction: the probe behind it would make #preflight ask a
        # server, which is the one thing that method promises it never does.
        backend.num_ctx
        resumed = resumed_run(backend)
        resolve_project!
        schedule_gc
        open_chronicle
        converse(backend:, resumed:, &notice)
      ensure
        # Graceful close anchors the head; a hard kill skips this. Routed
        # through the conductor because its close is guarded: a signal that
        # already closed the session (:interrupted / :grace_expired) makes this
        # a no-op. Falls back to the chronicle if the run raised before wiring
        # existed.
        (@wiring&.conductor || chronicle).close(reason: :exit)
        # Last-resort release of a held capped-overflow notice: the closers
        # land in the RAW journal, not the tee, so a failure path may never
        # cross the fleet sink's boundary recognition.
        @live_views&.fleet&.drain_pending
      end

      # Every refusal `lain chat` raises before it reads a byte of the
      # terminal. `lain up` runs this in a child process ({Up::ChatPreflight})
      # so a construction refusal lands on the operator's own terminal rather
      # than in a tmux pane whose dead-pane banner eats the cause.
      #
      # ENUMERATED, and that is its maintenance cost: a refusal added elsewhere
      # on the launch path has to be added here too. Two rules keep the list
      # honest. **It opens no record**, because a file opened in this SECOND
      # process is one nothing else closes. **It asks no server anything**,
      # because an unreachable `--api-base` fails at TURN level and refusing it
      # here would stop the cockpit opening for a model server that is merely
      # down -- which is why the span policy resolves through
      # {Backend::SpanSummarizer.resolve} and not {Backend#pipeline_source} and
      # its live round trip.
      #
      # That rule costs this list one refusal: a `--num-ctx` above the trained
      # maximum can only be caught by asking, so {#call} refuses it and `lain
      # up` learns of it from the pane rather than from here.
      # `--resume`/`--fork` are absent for a third reason:
      # resolving one reads the record and may repair it, and two processes
      # would put that repair in the history twice. The profile their header
      # recorded is still read, since that writes nothing, and a selector that
      # refuses reads as no recorded profile: that refusal stays the pane's.
      #
      # @return [nil]
      # @raise [Lain::Error] whatever the flags refuse, in the flag's own name
      def preflight(&notice)
        refuse_contradictory_flags!
        resolve_project!
        @profile = preflight_profile
        constructed
        # A mode that says nothing looks exactly like a hang, and this one is
        # reachable by accident: LAIN_PREFLIGHT is inherited like any other
        # variable, so a stray one turns a typed `lain chat` into a process
        # that exits 0 having done nothing.
        #
        # The `&.` is not defensive padding: **a caller that omits the block
        # re-opens exactly that silent 0-byte exit.** It stays because this
        # method is a CHECK first -- its product is the raise, and examples
        # call it directly to ask "are these flags constructible?". Requiring a
        # block would make flag validation depend on having somewhere to write;
        # raising for a missing one would trade a latent silence for a latent
        # FALSE REFUSAL that `lain up` would relay as chat's own words.
        notice&.call("pre-flight only (#{PREFLIGHT_ENV} is set): these arguments construct, " \
                     "and no conversation was started")
        nil
      end

      # The session record opens FIRST (per --journal), then --nvim views tee
      # onto IT -- inverted from the old "nvim first" order, which let two
      # independent Journal.open calls straddle a second tick and split
      # telemetry from the session file it belonged in.
      def open_chronicle
        @chronicle = @chronicle_factory.call(enabled: @options[:journal], btw: @options[:btw] || false)
        # A tee is built for --nvim (its Channel) OR --journal (the state feed
        # publishes for the tmux HUD), so a pure --no-journal --no-nvim run
        # opens neither and stays byte-identical.
        return unless @options[:nvim] || @options[:journal]

        @live_views = @live_views_factory.call(options: @options, chronicle:, status_feed:)
      end

      # The ONE StatusFeed for the run, built here so it can sit in the tee's
      # sink list and threaded unchanged into Wiring's Command::Env -- so
      # /status reads the same live instance the tee feeds. Exists even for a
      # headless run, so /status still answers its honest zeros.
      #
      # Built here and BOUND LATER: `inbox_count` needs the session's
      # {Lain::Store} to resolve a committed head's causal chain, and that store
      # does not exist until `Wiring#run` has built the Agent -- a layer below
      # this line. So Wiring hands it over ({Lain::StatusFeed#bind_store});
      # until then an empty Store resolves nothing and the count only climbs.
      def status_feed = @status_feed ||= @status_feed_factory.call(run_clock:, context_window: backend.context_window)

      # The ONE {Backend} for the run, shared exactly as {#run_clock} and
      # {#project} are. Two halves of the launch need it -- the feed divides
      # occupancy by {Backend#context_window}, the wiring hangs the Agent and
      # the compaction source off it -- and the window book is memoized per
      # Backend, so two Backends would be two probes and possibly two answers
      # across an ollama runner reload.
      def backend = @backend ||= Backend.new(@options, profile)

      # The ONE {RunProfile} the run's backend is built from: what was typed,
      # over the profile a `--resume`d or `--fork`ed header recorded. Resolved
      # before the backend, and so before every refusal the backend raises,
      # because each is judged against the fields this resolves.
      def profile = @profile ||= @typed_profile.over(recorded_profile)

      # The ONE RunClock for the run. Written by the Conductor and by the tee's
      # Telemetry::Compaction, read by the StatusFeed; two instances would
      # publish an `idle` that never resets, so it is built at the one point
      # above all three and threaded down.
      def run_clock = @run_clock ||= @run_clock_factory.call

      # The ONE {Lain::Project} for the run. Five collaborators down there take
      # a root off it and the Session takes its cwd; two resolutions could hand
      # them two different projects, which is the failure a `Dir.pwd` apiece
      # already was.
      def project = @project ||= @project_factory.call

      # A COMMAND, named as one, because a bare `project` in #call reads as dead
      # code and `Lint/Void` does not fire on a method call. It forces the
      # resolution HERE: an unresolvable cwd or an unusable `$HOME` must refuse
      # BEFORE any journal file is opened, and #converse's lazy read lands after.
      def resolve_project! = project

      # Defaults to the Null duck so a directly-constructed instance records
      # nothing and checks nothing for nil; #call replaces it per the --journal
      # flag before any wiring runs.
      def chronicle = @chronicle ||= Chronicle::Null.new

      # What the process should exit with, for the one caller entitled to ask:
      # `lain chat --non-interactive`. Every other chat exits 0 whatever
      # happened, because a human watched the refusal go past on their own
      # screen. Zero when no conversation was wired at all: those paths report
      # through a raise or a notice, and a status invented here would be a
      # second, quieter answer.
      #
      # @return [Integer]
      def exit_status = @wiring ? @wiring.exit_status : Repl::Outcome::COMPLETED

      private

      # The collaborators the flags decide, built and thrown away. Split out so
      # the one refusal whose answer depends on WHERE the check ran has
      # somewhere honest to be re-stated.
      #
      # That refusal is the missing key, the only environment-derived one. A
      # tmux server started from a shell that HAS a key hands it to every pane
      # it later spawns, so "ANTHROPIC_API_KEY is not set" can be false of the
      # place it matters while being true of the place this check can see. The
      # message therefore says where it looked and what to do rather than
      # asserting a global fact it is not in a position to know.
      #
      # TWO classes are caught, and they are SIBLINGS -- neither is an ancestor
      # of the other, so naming one catches nothing of the other. Backend's is
      # the anthropic arm's; {Provider::Ollama::Deployment::MissingAPIKey} is
      # the cloud arm's, and `--provider ollama-cloud` under `lain up` is the
      # modal case for the hint. Re-raised as `e.class` so the arm's own error
      # survives the annotation.
      def constructed
        backend.provider
        backend.context
        # Gated, because a pre-flight must refuse a SUBSET of what chat refuses
        # and never a superset: under --no-compact chat resolves no strategy,
        # so a refusal here would reject a chat that would have run.
        Backend::SpanSummarizer.resolve(backend:, options: @options) if backend.compaction?
        # Gated for the same reason: the summarizer tier is a SECOND provider
        # with a second key. `--summarizer-provider` naming an arm whose
        # credential is missing used to pre-flight clean and then die at the
        # first compaction, in a pane whose banner eats the cause.
        backend.summarizer_provider if backend.compaction?
      rescue Backend::MissingAPIKey, Provider::Ollama::Deployment::MissingAPIKey => e
        raise e.class, "#{e.message} -- looked for in the environment this pre-flight " \
                       "ran in, which is not the one a tmux server started elsewhere " \
                       "hands its panes; export it here, or start that server from a " \
                       "shell that has it"
      end

      # The flag combinations that can never run, refused alike by a launch and
      # by a pre-flight, before either reads the terminal or opens a record.
      def refuse_contradictory_flags!
        refuse_windows_without_journal!
        refuse_headless_without_prompt!
      end

      # --windows observes the live-view tee, which --no-journal never builds;
      # refuse loudly up front rather than opening a chat whose flag is silently
      # dead.
      def refuse_windows_without_journal!
        return unless @options[:windows] && !@options[:journal]

        raise Lain::Error, "--windows needs the session journal: the fleet sink observes " \
                           "the live-view tee, which --no-journal disables"
      end

      # Checked only here, never from {#preflight}: `lain up` pre-flights
      # `--windows` from the operator's OWN shell, which is never the tmux
      # session the pane it is about to create belongs to, so this refusal
      # would be false of the very process that is allowed to ask it.
      # {FleetWindows.for} already degrades to its Null duck outside $TMUX --
      # this refusal is what keeps that degrade from reading as a `--windows`
      # that silently did nothing.
      def refuse_windows_outside_tmux!
        return unless @options[:windows] && @env["TMUX"].to_s.empty?

        raise Lain::Error, "--windows opens panes in the tmux session this process is already inside, " \
                           "and $TMUX is not set -- start tmux first, or drop --windows"
      end

      # A headless chat reads no line, so a run with nothing seeded has nothing
      # to do and no way to find out -- it would sit on the terminal read the
      # flag exists to remove, looking exactly like a hang. Refused ahead of
      # the chronicle: a refusal must never orphan a fresh journal.
      def refuse_headless_without_prompt!
        return unless @options[:non_interactive] && Blankness.blank?(@options[:prompt])

        raise Lain::Error, "--non-interactive needs --prompt: it reads no line from the terminal, " \
                           "so a run with no question seeded has nothing to ask"
      end

      # Resolved BEFORE open_chronicle (see #call) so a resume/fork refusal
      # raises before any journal file is opened. --fork opens the parent
      # read-only (never salvages it) and wins over --resume when both are
      # given.
      def resumed_run(backend)
        return resume.fork_at(fork_point, profile:, model: backend.context.model) if @options[:fork]

        @options[:resume] && resume.resume_at(resumed_path, profile:, model: backend.context.model)
      end

      # Only the header, so a pre-flight may read it too: a recorded profile
      # decides which arm's refusals the flags must pass.
      def recorded_profile
        return resume.recorded_profile(fork_point.path) if @options[:fork]
        return resume.recorded_profile(resumed_path) if @options[:resume]

        RunProfile::UNRECORDED
      end

      # A pre-flight leaves a selector's refusal -- nothing to resume, an
      # ambiguous or unmatched name -- to the pane that reports it, as it always
      # has, and reads the selection as having recorded nothing.
      def preflight_profile
        @typed_profile.over(recorded_profile)
      rescue Resume::Refusal
        @typed_profile
      end

      # Each door selects its session ONCE, and the header read and the open
      # both use that selection. See {Resume#locate} for the race two looks run.
      def resumed_path = @resumed_path ||= resume.locate(@options[:resume])

      def fork_point = @fork_point ||= resume.fork_point(@options[:fork])

      # One resolver for both reads of the record, the header and the door.
      def resume = @resume ||= @resume_factory.call

      def nvim_views = @live_views&.views

      # Keyed on the project's root, so it waits for the resolution. A
      # pre-flight never reaches it: that process only checks the flags.
      def schedule_gc = @gc_schedule_factory.call(root: project.root).call

      # Instance state, because the ensure in #call closes the wiring's
      # conductor.
      def converse(backend:, resumed:, &notice)
        @wiring = @wiring_factory.call(options: @options, chronicle:, status_feed:, run_clock:, project:)
        @wiring.run(backend:, resumed:, nvim: nvim_views, &notice)
      end
    end
  end
end
