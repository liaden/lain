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
      def call(&notice)
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
