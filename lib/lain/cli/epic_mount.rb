# frozen_string_literal: true

module Lain
  module CLI
    # Which epic a chat is in, the ONE ownership baton over it, and the
    # {Lain::Tools::RequestReview} hung off that baton.
    #
    # {ToolsetBuild} is where a run's capabilities are assembled, and this is
    # what it is handed rather than what it works out: the tell is the same
    # `(home:, review:, notes:)` triple that named {ToolsetBuild} itself -- three
    # collaborators that always travel together AND carry an invariant between
    # them, which is state an object is missing rather than arguments a build
    # should thread.
    #
    # == The invariant, which is the whole reason this is an object
    #
    # ONE {Epic::Review} per slug, and the SAME instance is the journaled home's
    # `reviews:` and the tool's `review:`. Two Reviews sharing a journal both
    # hand out generation 1, and {Epic::Review::Replay#park} calls that a wiring
    # error and CARRIES the damage rather than refusing -- so a second Review
    # never announces itself, it just quietly stops guarding. Built once in
    # {#initialize} rather than memoized behind a reader, so there is no second
    # path to a second one.
    #
    # == A chat never fails to start over an epic
    #
    # A chat outside an epic has no document to review, and a tool that cannot
    # act should not be offered to the model -- so every refusal from the epic
    # tier answers {NoEpic}, whose whole surface is `tools == []`. The seam
    # {ToolsetBuild} sends is that one message, which is why {NoEpic} implements
    # only it: `home` and `review` have no honest null (which epic this is cannot
    # be defaulted), and answering them would be a lie rather than a Null Object.
    #
    # == Two constants named Epic, and they are different classes
    #
    # The lexical scope here is `Lain::CLI`, so a bare `Epic` is {CLI::Epic} --
    # the command that owns slug resolution -- and the artifact tier has to be
    # spelled `Lain::Epic::...` in full. Both are spelled explicitly below for
    # that reason. And every one of those references sits INSIDE a method body:
    # this unit loads before `lain/epic` and `lain/tools` (see lib/lain.rb), so a
    # constant evaluated at load time would raise NameError at boot.
    class EpicMount
      # What a chat is told when the tool it might have had is not there. It
      # names the lost capability first, because "there are 2 epics here" on its
      # own reads as a status line rather than as something that just cost the
      # session a tool.
      UNWIRED = "request_review is not wired for this chat: %<reason>s"

      # Only where naming one would actually help. {CLI::Epic::Ambiguous}'s own
      # message ends with the `lain epic status SLUG` remedy, which is the right
      # advice for a report and the wrong flag for a chat.
      NAME_ONE = " Start the chat with --epic SLUG to say which."

      # The startup-notice seam's null, matching {Frontend::PromptComposer::SILENT}.
      SILENT = ->(_message) {}

      # No epic resolved, so no tool. `tools` is the entire duck {ToolsetBuild}
      # depends on -- see the class comment for why this deliberately does not
      # answer `home` or `review`.
      module NoEpic
        def self.tools = []
      end

      # The wiring entry, on {Switchboard.for}'s shape: read the surface flag
      # off the options, resolve the journal the chronicle carries (the null
      # device under --no-journal), and build over both.
      #
      # The slug resolves BEFORE the journal is opened or folded, and that
      # ordering is deliberate: the overwhelmingly common chat is not in an epic
      # at all, and it must pay one directory listing to find that out rather
      # than a fold of every session this project has ever recorded.
      #
      # `SystemCallError` is rescued beside {Lain::Error} because the session
      # directory is created on demand ({Paths#sessions_dir}) and the epics
      # container is a path a user owns: a read-only state home or a file where
      # a directory belongs must cost this chat its review tool, never its
      # startup.
      #
      # == --no-journal, stated rather than warned about
      #
      # The journal is /dev/null then, so `review_opened` is not durable and a
      # restart would not rebuild the baton. That is a comment and not a startup
      # notice on purpose. Within one process the baton is in memory and works
      # exactly as it always does; only a RESTART loses it -- and a --no-journal
      # session writes no session file, so there is nothing for --resume to
      # resume and no restart-mid-review flow to reach. Warning here would
      # restate a flag the operator just set, on the one seam reserved for things
      # they can still act on.
      #
      # == Every default lives on {.mount}, and that placement is the guard
      #
      # Ruby evaluates default arguments BEFORE the body's `rescue` is armed, so
      # a default that raises escapes the very clause written to catch it. This
      # method held `config: Config.load(root:)` and three config refusals went
      # straight out of it -- silently correct-looking, because the rescue named
      # exactly the right class and simply never ran.
      #
      # It was a new hazard rather than an inherited one: NO chat path read
      # `.lain/config.toml` before this class existed, so the object built to
      # keep a chat starting was what made a typo in `[epics]` fatal to startup.
      # Splitting the resolution onto {.mount} puts every default inside the
      # guarded region, `Dir.pwd` and `Paths.new` included -- neither is known to
      # raise, but there is no reason for them to sit outside the net when
      # keeping them in it costs nothing.
      #
      # @param bindings [#call, nil] a thunk reading the live {HumanReplies} --
      #   it does not exist yet when the toolset is built, so the tool reads this
      #   at CALL time ({Tools::RequestReview#live})
      # @return [EpicMount, NoEpic]
      def self.for(chronicle:, options:, notice: nil, **injected)
        mount(chronicle:, options:, **injected)
      rescue Lain::Error, SystemCallError => e
        (notice || SILENT).call(unwired(e)) if worth_saying?(options[:epic], e)
        NoEpic
      end

      # Resolution proper, with nothing rescued: every refusal here is {.for}'s
      # to answer, and this method exists so that the defaults raise where that
      # answer can hear them.
      def self.mount(chronicle:, options:, root: Dir.pwd, paths: Paths.new, config: Config.load(root:),
                     bindings: nil, notify: nil)
        new(slug: Epic.new(root:, paths:, config:).resolve_slug(options[:epic]),
            journal: chronicle.record_journal, root:, paths:, config:, bindings:, notify:)
      end

      # Silent for the ordinary case, loud for every refusal a human could act
      # on.
      #
      # "Nobody named an epic and the home holds none" is the ordinary case, and
      # it is exactly `slug.nil?` plus {CLI::Epic::UnknownEpic}: that class comes
      # from the empty-home branch only when no slug was given, and from the
      # not-found branch only when one was. A startup line for it would fire in
      # every chat in every project that has never used the epic tier.
      #
      # Everything else cost this session a tool it could have had -- several
      # epics and no name, a name that is not here, a container that cannot be
      # listed -- so it is said.
      def self.worth_saying?(slug, error) = !(slug.nil? && error.is_a?(Epic::UnknownEpic))

      def self.unwired(error)
        "#{format(UNWIRED, reason: error.message)}#{NAME_ONE if error.is_a?(Epic::Ambiguous)}"
      end

      private_class_method :mount, :worth_saying?, :unwired

      attr_reader :slug, :review, :notes

      # The Review is built HERE and not behind a memo, so "one per slug" is
      # structural. It is also what puts the journal fold inside {.for}'s rescue:
      # a torn session file must cost the chat its review tool at startup, not
      # raise later out of the toolset build.
      #
      # @param journal [#<<] where the epic records land -- the chat's own
      #   session journal, which is what {CLI::Epic::Journals} reads back
      def initialize(slug:, journal:, root:, paths:, config:, bindings: nil, notify: nil)
        @slug = slug
        @journal = journal
        @root = root
        @paths = paths
        @config = config
        @bindings = bindings
        @notify = notify || Lain::Notify::Null.new
        @notes = Lain::Tools::RequestReview::Notes.new(journal:)
        @review = rebuilt_review
      end

      # What this epic lets a chat DO, as a collection rather than a
      # tool-or-nil: "a chat outside an epic has no document to review" is
      # honestly an EMPTY set, and saying it that way is what keeps a nil check
      # out of {ToolsetBuild} -- {NoEpic} answers the same message with `[]`.
      def tools = @tools ||= [request_review]

      # The journaled home, guarded by the SAME Review the tool holds. Both
      # sides read this one attribute; a second construction anywhere would
      # leave the regeneration guard guarding nothing.
      def home
        @home ||= Lain::Epic::Home::Journaled.new(
          Lain::Epic::Home.resolve(config: @config, paths: @paths, root: @root, slug:),
          journal: @journal, reviews: review
        )
      end

      private

      # `editor:` is deliberately not passed, and it is a finding rather than an
      # omission: the object answering `open_review` is {Frontend::Neovim}, which
      # {Repl#run} builds as a local and publishes only as its `command_inbox`,
      # so no wiring can reach it. The tool's own {Tools::RequestReview::NoEditor}
      # is therefore the honest collaborator -- a hand-over where the
      # notification names the path and the human opens it themselves. The
      # editor's `done` gesture still settles the review, because that rail IS
      # the command inbox and it IS bound ({Repl#run} -> {HumanReplies#bind_editor}).
      def request_review
        Lain::Tools::RequestReview.new(home:, review:, notes:, bindings: @bindings, notify: @notify)
      end

      # {Epic::Review.from_journal} and not {Review.new}, so a chat restarted
      # while a human still holds a file goes on refusing to overwrite it.
      #
      # It fails OPEN and this comment does not overclaim it: {Journal.records}
      # skips any line it cannot parse -- its fd is shared with Rust tracing
      # spans, so that is its contract -- and a `review_opened` torn by a crash
      # is therefore simply gone. `open?(path) == false` means no readable claim
      # says otherwise, which is weaker than "nobody holds this file".
      def rebuilt_review
        Lain::Epic::Review.from_journal(prior_claims, journal: notes, epic_slug: slug)
      end

      # Every session journal in this project, not merely this chat's: the claim
      # a restart has to rebuild was written by the session that died, which is a
      # DIFFERENT file. {CLI::Epic::Journals} folds the same directory for the
      # same reason, and is not reused here only because its type filter is the
      # progress tier's and would materialize none of these records.
      #
      # == What it costs, measured rather than guessed
      #
      # Startup, in-epic: 35 ms over 50 files / 2.7 MB, 203 ms over 300 files /
      # 32 MB. Outside an epic: 0 ms, because {.for} resolves the slug before it
      # ever gets here and the common chat stops there. Nothing prunes the
      # session directory, so an epic-using project pays a linearly growing tax
      # at every start -- tolerable now, unbounded in shape. Bounding it (an
      # mtime window, or chaining back through the session header the way
      # --resume already does) is a follow-up against this walk, not something
      # this object can decide alone.
      #
      # == Why folding EVERY file is the safer half of a real hazard
      #
      # A generation is a per-Review counter from 1, so two dead sessions can
      # both have handed out 1 for this slug, and one's close then releases the
      # other's held claim. Folding everything is what MITIGATES that rather
      # than causing it: {Review::Replay} takes its high-water across every
      # record it is given, so each session starts above every claim it can see.
      # A narrower fold would put every session back at 1 and collide far more
      # often. What is left is the genuinely concurrent case -- two chats opened
      # in one project before either journaled -- which `lain up`'s fleet makes
      # reachable. A generation carrying a session id would close it; that is
      # the epic tier's to answer, not this caller's.
      def prior_claims
        SessionJournals.new(dir: @paths.sessions_dir(project: @paths.project_hash(@root)),
                            types: [Lain::Epic::ReviewOpened::JOURNAL_TYPE,
                                    Lain::Epic::ReviewClosed::JOURNAL_TYPE]).to_a
      end
    end
  end
end
