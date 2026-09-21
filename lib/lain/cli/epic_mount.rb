# frozen_string_literal: true

module Lain
  module CLI
    # Which epic a chat is in, the ONE ownership baton over it, and the
    # {Lain::Tools::RequestReview} hung off that baton. {ToolsetBuild} is handed
    # this rather than working it out: `(home:, review:, notes:)` always travel
    # together AND carry an invariant between them.
    #
    # == The invariant, which is the whole reason this is an object
    #
    # ONE {Epic::Review} per slug, and the SAME instance is the journaled home's
    # `reviews:` and the tool's `review:`. Two Reviews sharing a journal both
    # hand out generation 1, and {Epic::Review::Replay#park} calls that a wiring
    # error and CARRIES the damage rather than refusing -- so a second Review
    # never announces itself, it just quietly stops guarding. Built once in
    # {#initialize} rather than memoized, so there is no second path to one.
    #
    # == A chat never fails to start over an epic
    #
    # Every refusal from the epic tier answers {NoEpic}, whose whole surface is
    # `tools == []` -- the one message {ToolsetBuild} sends. `home` and `review`
    # have no honest null (which epic this is cannot be defaulted), so answering
    # them would be a lie rather than a Null Object.
    #
    # == Two constants named Epic, and they are different classes
    #
    # The lexical scope here is `Lain::CLI`, so a bare `Epic` is {CLI::Epic} and
    # the artifact tier must be spelled `Lain::Epic::...` in full.
    class EpicMount
      # What a chat is told when the tool it might have had is not there. The
      # lost capability comes first: "there are 2 epics here" on its own reads as
      # a status line rather than as something that just cost a tool.
      UNWIRED = "request_review is not wired for this chat: %<reason>s"

      # No epic resolved, so no tool. `tools` is the entire duck {ToolsetBuild}
      # depends on; the class comment says why `home` and `review` are absent.
      module NoEpic
        def self.tools = []
      end

      # The slug resolves BEFORE the journal is opened or folded: the
      # overwhelmingly common chat is not in an epic at all, and it must pay one
      # directory listing to find that out rather than a fold of every session
      # this project has ever recorded.
      #
      # `SystemCallError` is rescued beside {Lain::Error} because the session
      # directory is created on demand ({Paths#sessions_dir}) and the epics
      # container is a path a user owns: a read-only state home must cost this
      # chat its review tool, never its startup.
      #
      # Under --no-journal the baton is not durable, and that is a comment rather
      # than a startup notice: it works in memory for the process's life, and
      # such a session writes no session file for --resume to resume anyway.
      #
      # == Every default lives on {.mount}, and that placement is the guard
      #
      # Ruby evaluates default arguments BEFORE the body's `rescue` is armed, so
      # a default that raises escapes the very clause written to catch it. This
      # method held `config: Config.load(root:)` and three config refusals went
      # straight out of it -- looking correct, because the rescue named exactly
      # the right class and simply never ran. Splitting the resolution onto
      # {.mount} puts every default inside the guarded region.
      #
      # @param chronicle [Epic::Chronicle] the epic's record, mounted read-write
      # @param options [Hash] the parsed CLI options; `:epic` names the slug
      # @param notice [#call, nil] told why a mount was abandoned; silent by default
      # @param injected [Hash] collaborators the caller substitutes, passed to {.mount}
      # @option injected [#call, nil] :bindings a thunk reading the live
      #   {HumanReplies}, which the tool reads at CALL time because it does not
      #   exist yet when the toolset is built
      # @return [EpicMount, NoEpic]
      def self.for(chronicle:, options:, notice: nil, **injected)
        mount(chronicle:, options:, **injected)
      rescue Lain::Error, SystemCallError => e
        (notice || SILENT).call(unwired(e)) if worth_saying?(options[:epic], e)
        NoEpic
      end

      # Resolution proper, with nothing rescued: this method exists so that the
      # defaults raise where {.for}'s answer can hear them.
      #
      # @param chronicle [Epic::Chronicle] the epic's record, mounted read-write
      # @param options [Hash] the parsed CLI options
      # @param root [String] the project directory every default resolves against
      # @param paths [Paths] where an epic's files live
      # @param config [Config] read here rather than at {.for}, so a typo in
      #   `[epics]` raises inside that method's rescue rather than past it
      # @param bindings [#call, nil] a thunk reading the live {HumanReplies}
      # @param told [#call] the run's one line to the human, forwarded to the tool
      # @param changesets [#source, nil] builds the review source
      # @param surface [#present, #call, nil] where a changeset is drawn, or a
      #   thunk reading one
      # @param view [#open, #marks, #call, nil] the rendering a review gesture's
      #   row number resolves through, or a thunk reading one
      # @param policy [Lain::Review::Verdict::Policy, nil] verdict admissibility
      # @option options [String] :epic the slug {Epic#resolve_slug} refuses by
      #   name when it is ambiguous or unknown
      # @return [EpicMount]
      def self.mount(chronicle:, options:, told:, root: Dir.pwd, paths: Paths.new, config: Config.load(root:),
                     bindings: nil, changesets: nil, surface: nil, view: nil, policy: nil)
        new(slug: Epic.new(root:, paths:, config:).resolve_slug(options[:epic], command: "chat --epic"),
            journal: chronicle.record_journal, root:, paths:, config:, bindings:, told:,
            changesets:, surface:, view:, policy:)
      end

      # Silent for the ordinary case, loud for every refusal a human could act
      # on.
      #
      # "Nobody named an epic and the home holds none" is exactly `slug.nil?`
      # plus {CLI::Epic::UnknownEpic}, and a startup line for it would fire in
      # every chat in every project that has never used the epic tier. Everything
      # else cost this session a tool it could have had, so it is said.
      def self.worth_saying?(slug, error) = !(slug.nil? && error.is_a?(Epic::UnknownEpic))

      # No sentence of its own bolted on: {CLI::Epic::Ambiguous} is asked on
      # behalf of `chat --epic`, so its remedy already names the flag a chat can
      # use. Adding one here is what made a notice name two commands.
      def self.unwired(error) = format(UNWIRED, reason: error.message)

      private_class_method :mount, :worth_saying?, :unwired

      attr_reader :slug, :review, :notes

      # The Review is built HERE and not behind a memo, so "one per slug" is
      # structural. It is also what puts the journal fold inside {.for}'s rescue:
      # a torn session file must cost the chat its review tool at startup, not
      # raise later out of the toolset build.
      #
      # @param slug [String] the epic this chat is mounted into, already resolved
      #   by {Epic#resolve_slug}
      # @param journal [#<<] where the epic records land -- the chat's own
      #   session journal, which is what {CLI::Epic::Journals} reads back
      # @param root [String] the project root the epic's home is resolved under
      # @param paths [Paths] the XDG/project path authority
      # @param config [Config] `.lain/config.toml`, loaded -- carries the
      #   `[epics]` table
      # @param bindings [#call, nil] a thunk reading the live {HumanReplies},
      #   which the tool reads at CALL time because it does not exist yet when
      #   the toolset is built
      # @param told [#call] the run's one line to the human. Required and not
      #   defaulted, all the way down: this mount deliberately passes no
      #   `editor:` (see {#request_review}), so it is the only thing that names
      #   a file to the human, and a mount that silently defaulted it would open
      #   reviews nobody could learn about.
      # @param changesets [#source, nil] builds the {Lain::Review::Source} an
      #   `implementation` review reads its diff from; nil leaves the tool's
      #   {Lain::Tools::RequestReview::NoChangesets}, which refuses the stage
      # @param surface [#present, #call, nil] where a changeset is drawn, or a
      #   thunk reading one; nil leaves {Lain::Review::Surface::Null}
      # @param view [#open, #marks, #call, nil] the rendering a review gesture's
      #   row number resolves through, or a thunk reading one
      # @param policy [Lain::Review::Verdict::Policy, nil] whether a verdict may
      #   stand; nil leaves {Lain::Review::Verdict::Policy.default}
      def initialize(slug:, journal:, root:, paths:, config:, told:, bindings: nil,
                     changesets: nil, surface: nil, view: nil, policy: nil)
        @slug = slug
        @journal = journal
        @root = root
        @paths = paths
        @config = config
        @bindings = bindings
        @told = told
        # One ivar because they are one decision: the seams the changeset half
        # of the tool takes, which arrive together and forward together.
        @review_seams = { changesets:, surface:, view:, policy: }.freeze
        @notes = Lain::Tools::RequestReview::Notes.new(journal:)
        @review = rebuilt_review
      end

      # A collection rather than a tool-or-nil: "a chat outside an epic has no
      # document to review" is honestly an EMPTY set, which is what keeps a nil
      # check out of {ToolsetBuild} -- {NoEpic} answers the same message.
      def tools = @tools ||= [request_review]

      # The journaled home, guarded by the SAME Review the tool holds. A second
      # construction anywhere would leave the regeneration guard guarding
      # nothing.
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
      # so no wiring can reach it. {Tools::RequestReview::NoEditor} is therefore
      # the honest collaborator -- `told:` names the path and the human opens it
      # themselves, while the editor's `done` gesture still settles the review
      # because that rail IS the bound command inbox.
      #
      # Which makes `told:` load-bearing HERE and nowhere more: it is not one of
      # several ways the human finds out, it is the only one this construction
      # leaves, and the call parks on an unbounded await behind it. That is why
      # it is required rather than defaulted at every hop down to the tool.
      #
      # The changeset seams are supplied by nobody here either, but by {Wiring}
      # rather than by default -- while nothing injected them, every
      # `implementation` call in every real process refused with
      # {Tools::RequestReview::Refusals::NO_CHANGESET} and no spec could see it,
      # because a spec passes its own. A caller that passes none still gets a
      # tool that refuses the stage in one sentence naming the wiring.
      def request_review
        Lain::Tools::RequestReview.new(home:, review:, notes:, bindings: @bindings, told: @told,
                                       **@review_seams)
      end

      # {Epic::Review.from_journal} and not {Review.new}, so a chat restarted
      # while a human still holds a file goes on refusing to overwrite it.
      #
      # It fails OPEN on its own records: {SessionJournals} counts and skips a
      # torn line of a type no sign-off rests on, so a `review_opened` torn by a
      # crash is simply gone, and `open?(path) == false` means only that no
      # readable claim says otherwise. A torn sign-off in the same directory
      # refuses the read, which {.for} turns into a chat with no review tool and
      # a notice naming the line.
      def rebuilt_review
        Lain::Epic::Review.from_journal(prior_claims, journal: notes, epic_slug: slug)
      end

      # Every session journal in this project, not merely this chat's: the claim
      # a restart has to rebuild was written by the session that died.
      # {CLI::Epic::Journals} is not reused because its type filter is the
      # progress tier's and would materialize none of these.
      #
      # == What it costs, measured rather than guessed
      #
      # Startup, in-epic: 35 ms over 50 files / 2.7 MB, 203 ms over 300 files /
      # 32 MB. Outside an epic: 0 ms, because {.for} resolves the slug first and
      # the common chat stops there. Nothing prunes the session directory, so an
      # epic-using project pays a linearly growing tax at every start -- bounding
      # it (an mtime window, or chaining back through the session header) is a
      # follow-up against this walk.
      #
      # == Why folding EVERY file is the safer half of a real hazard
      #
      # A generation is a per-Review counter from 1, so two dead sessions can
      # both have handed out 1 for this slug, and one's close then releases the
      # other's held claim. Folding everything MITIGATES that: {Review::Replay}
      # takes its high-water across every record it is given, so each session
      # starts above every claim it can see, where a narrower fold would put
      # every session back at 1. What is left is the genuinely concurrent case,
      # which a generation carrying a session id would close.
      #
      # `sessions_dir`'s OWN default, NOT `project_hash(@root)` -- see the note
      # on {CLI::Epic::Journals#walk}. The claims replayed here were written by a
      # chat whose journal lands in the cwd-keyed directory, so keying the read
      # on the resolved root looked somewhere nothing is ever written.
      def prior_claims
        SessionJournals.new(dir: @paths.sessions_dir,
                            types: [Lain::Epic::ReviewOpened::JOURNAL_TYPE,
                                    Lain::Epic::ReviewClosed::JOURNAL_TYPE]).to_a
      end
    end
  end
end
