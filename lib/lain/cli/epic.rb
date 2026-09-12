# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # `lain epic status [SLUG]`: where one epic stands. Returns a String and
    # prints nothing -- only the frontend touches a stream (output discipline).
    # Read-only and deterministic, so two runs over the same home and the same
    # session files are diffable.
    #
    # == The remaining-work rule
    #
    # **Not done is remaining**, where done is {Epic::DONE} and nothing else.
    # `abandoned` still blocks whatever it blocked ({Epic::Graph#ready} satisfies
    # a blocker only when it is done), so treating it as finished -- an earlier
    # draft did -- named an abandoned issue in a `blocked by` annotation while
    # showing it nowhere. The rule keeps every id named in an annotation present
    # in the listing above it.
    #
    # == Every constant from the epic tier is reached at CALL time
    #
    # This unit loads BEFORE `lain/epic` (lib/lain.rb: cli, then plan, then
    # epic), so a `Lain::Epic::...` reference evaluated while this file loads --
    # a constant assignment, a default argument -- raises NameError at boot.
    # Every such reference below therefore sits inside a method body.
    #
    # And it is spelled `Lain::Epic`, never `Epic`: the lexical scope here is
    # `Lain::CLI::Epic`, so a bare `Epic` resolves to THIS class and
    # `Epic::Home` would look for `Lain::CLI::Epic::Home`.
    class Epic
      # A slug was given and the home holds no such epic.
      class UnknownEpic < Error; end

      # No slug was given and the home holds more than one epic. Loud rather
      # than a guess: the alphabetically-first would report on work the caller
      # never asked about, in a command whose job is telling the truth about
      # which work is where.
      class Ambiguous < Error; end

      # How an ambiguity refusal spells the way out. The caller supplies the
      # MIDDLE, so every verb's advice is the invocation that just refused with
      # one slug added, and the trailing `SLUG` stays here rather than in four
      # strings that can drift apart.
      REMEDY = "name one: lain %<command>s SLUG"

      # The container exists but cannot be listed. Its own class for
      # {Epic::Home::UnreadableArtifact}'s reason: an unreadable directory is not
      # "no epics yet", and the empty-home message would report a permissions
      # fault as a fresh project.
      class UnreadableHome < Error
        def initialize(path, cause)
          super("cannot list the epics in #{path}: #{cause.message}")
        end
      end

      # A file the session glob matched cannot be read as a journal. The session
      # directory is one the user owns, so a stray `weird.ndjson/` subdirectory
      # (EISDIR) or a mode-000 file (EACCES) is reachable without anything being
      # wrong with this tier -- and a raw `Errno::EISDIR` escapes exe/lain's
      # `rescue Lain::Error` and prints a backtrace at a user who asked for a
      # status report.
      #
      # Named, not skipped: a journal that cannot be read may hold this epic's
      # transitions, and walking past it reports stale progress as current.
      # The refusal belongs to {SessionJournals}, which owns the read; kept as a
      # name here because this command's specs rescue it by this constant.
      UnreadableJournal = SessionJournals::Unreadable

      # Whether git ignores a path, answered by git itself.
      #
      # Repo mode exists so a team can review an epic in a pull request, and
      # this repository's own .gitignore holds `/.lain/`, which is where repo
      # mode resolves -- so a repo home can be invisible to the tool it was
      # chosen for. {Epic::Home} does not detect this: it is a pure path
      # calculator with no Sink and no subprocess, so the check belongs beside
      # the line that prints the resolved home.
      #
      # It asks and NEVER edits .gitignore -- what to ignore is the user's
      # policy. Unanswerable is "not ignored", not a failure: no git on PATH, or
      # a root that is no repository, must not fail a status report over a
      # warning about a setup that may not even be in use.
      class GitIgnores
        # What git says when it will not name the rule. `-v` always prints one,
        # so this is unreachable in practice; the alternative to a fallback is
        # an empty reason, which reads as "not ignored" and drops a true warning.
        UNNAMED = "an ignore rule this git would not name"

        # `Mixlib::ShellOut` rather than backticks or Open3: already this
        # project's subprocess runner ({Isolation::Worktree}), and it captures
        # both streams, so nothing git says interleaves into a Journal or a TTY.
        def initialize(root, shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @root = root
          @shell_out_factory = shell_out_factory
        end

        # The rule that ignores +path+, or "" when nothing does.
        #
        # A reason and not a predicate: "this is ignored" leaves the user to hunt
        # WHICH pattern did it, across a repo's .gitignore, .git/info/exclude and
        # the global core.excludesFile, and `-v` answers that for free.
        #
        # Exit 0 is ignored, 1 is not, 128 is could-not-answer (no repository
        # here) -- so only a literal 0 is a yes.
        def reason(path)
          shell = @shell_out_factory.call("git", "-C", @root, "check-ignore", "-v", "--", path)
          shell.run_command
          return "" unless shell.exitstatus.zero?

          rule(shell.stdout)
        rescue SystemCallError
          ""
        end

        private

        # `-v` prints `<source>:<line>:<pattern>\t<pathname>`. The source field
        # is handed on verbatim rather than parsed apart: a pattern may hold a
        # colon, and `.gitignore:5:/.lain/` is already exactly what the user
        # would grep for.
        def rule(stdout)
          field = stdout.to_s.lines.first.to_s.split("\t").first.to_s.strip
          field.empty? ? UNNAMED : field
        end
      end

      # `root:` defaults to the RESOLVED project's, not to `Dir.pwd`. A
      # `lain chat` mounts its epic under {Project::Resolver.default_project}'s
      # root, and this command must ask the same object or the two go blind to
      # each other's epics -- the resolver WALKS, so anything under a `.lain/`
      # already has root != cwd. They agreed before only because both read pwd.
      #
      # @param root [String] the project root; the config file and a repo-mode
      #   home both resolve under it
      # @param paths [Paths] injected, so a spec resolves against a throwaway
      #   XDG state home
      # @param config [Config] `.lain/config.toml`, already read
      # @param ignores [#reason] the git question, injected so no spec has to
      #   build a repository to exercise the warning
      def initialize(root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                     ignores: GitIgnores.new(root))
        @root = root
        @paths = paths
        @config = config
        @ignores = ignores
      end

      # @param slug [String, nil] the epic to report on; omitted resolves to the
      #   sole epic in the home
      # @param mermaid [Boolean] render {Epic::Mermaid} over the fold instead of
      #   the text projection -- the diagram is drawn from the same {#progress}
      #   this class exposes publicly, so a mermaid render and a text render
      #   can never disagree about which issue is ready
      # @return [String] the rendered projection, or the guidance an empty home
      #   deserves
      # @raise [Ambiguous, UnknownEpic, UnreadableHome] and any {Lain::Error}
      #   from the home, the document, or the fold -- exe/lain renders all of
      #   them as a message with no backtrace
      def status(slug = nil, mermaid: false)
        slugs = slugs_in(container)
        return unstarted(container) if slugs.empty?

        resolved = chosen(slug, slugs, container, command: "epic status")
        mermaid ? Lain::Epic::Mermaid.render(progress(resolved)) : report(resolved)
      end

      # WHICH epic a bare command means: the sole one in the home, or the named
      # one checked against it.
      #
      # Public because every epic verb has to answer it the SAME way -- a second
      # spelling of "the sole epic" would let two verbs report on different work,
      # silently, since neither would raise. `command` has no default for the
      # same reason: it would let the NEXT verb inherit advice for a command its
      # operator never ran. Spell it as argv does, minus the slug:
      # `"epic submit STAGE"`, `"chat --epic"`.
      #
      # @param slug [String, nil]
      # @param command [String] what the operator invoked, for {REMEDY}
      # @return [String] the resolved slug
      # @raise [Ambiguous, UnknownEpic, UnreadableHome]
      def resolve_slug(slug = nil, command:) = chosen(slug, slugs_in(container), container, command:)

      # The Journal's runtime truth folded over `epic.md`, for a slug already
      # resolved (through {#resolve_slug} or {#status}'s own `chosen`).
      #
      # Public so a second renderer over the same fold -- {Epic::Mermaid} here,
      # the `lain://status` buffer later -- asks this object rather than
      # re-walking {Home} and {Journals} itself, which is what keeps a text
      # report and a diagram of the SAME epic from ever disagreeing about which
      # issue is ready. `slug` is required and unchecked against the container
      # on purpose: every caller already resolved it, and re-validating here
      # would just be a second copy of {#resolve_slug}'s own rule.
      #
      # @param slug [String] a real epic slug, already resolved
      # @return [Epic::Progress]
      # @raise [Lain::Error] from the home or the fold
      def progress(slug)
        Lain::Epic::Progress.fold(journals_for(slug).to_a, graph: home_for(slug).read_epic, epic_slug: slug)
      end

      private

      # Memoized: three of the four callers above ask for it in one invocation,
      # and it is pure path arithmetic over values this object already holds.
      def container = @container ||= Lain::Epic::Home.container(config: @config, paths: @paths, root: @root)

      def home_for(slug) = Lain::Epic::Home.resolve(config: @config, paths: @paths, slug:, root: @root)

      # ONE {Journals}, so the records folded and the directory reported are the
      # same walk rather than two that could disagree.
      def report(slug)
        home = home_for(slug)
        walked = journals_for(slug)
        progress = Lain::Epic::Progress.fold(walked.to_a, graph: home.read_epic, epic_slug: slug)
        Report.new(slug:, path: home.path, sessions: walked.dir, progress:,
                   note: untracked_note(home.path)).to_s
      end

      def journals_for(slug) = Journals.new(paths: @paths, root: @root, epic_slug: slug)

      def records_for(slug) = journals_for(slug).to_a

      # A directory whose name is a legal slug. Anything else is skipped rather
      # than refused: no epic can be spelled that way, so a stray `.DS_Store`
      # must not stop a real epic being reported.
      def slugs_in(container)
        return [] unless File.directory?(container)

        Dir.children(container).select { |entry| epic_dir?(container, entry) }.sort
      rescue SystemCallError => e
        raise UnreadableHome.new(container, e)
      end

      def epic_dir?(container, entry)
        Lain::Epic::Home::NAME.match?(entry) && File.directory?(File.join(container, entry))
      end

      def chosen(slug, slugs, container, command:)
        return sole(slugs, container, command:) if slug.nil?
        return slug if slugs.include?(slug)

        raise UnknownEpic, "no epic #{slug.inspect} in #{container} -- it holds #{listed(slugs)}"
      end

      # An empty home is reachable only through {#resolve_slug}: {#status}
      # answers {#unstarted} before it ever chooses. "holds 0 epics ()" would be
      # a sentence about nothing, so the emptiness is said outright.
      def sole(slugs, container, command:)
        raise UnknownEpic, "no epics yet in #{container} -- there is nothing to name" if slugs.empty?
        return slugs.first if slugs.one?

        raise Ambiguous, "#{container} holds #{slugs.size} epics (#{listed(slugs)}) -- " +
                         format(REMEDY, command:)
      end

      def listed(slugs) = slugs.map { |slug| "`#{slug}`" }.join(", ")

      # An empty home is a fresh project, not a failure: guidance and exit 0,
      # where a raise would exit nonzero over a state every epic passes through.
      def unstarted(container)
        ["no epics yet in #{container}", untracked_note(container),
         "start one with the research-epic skill -- it interviews you, writes research.md, " \
         "and lands epic.md in a new <slug>/ directory here"].reject(&:empty?).join("\n")
      end

      # Said in the output rather than raised: the status an ignored repo home
      # hides is exactly what the caller asked for. Only repo mode can have it,
      # so git is not even asked otherwise. The rule is named in the message
      # because the actionable half is WHICH pattern to drop, not that one
      # exists.
      def untracked_note(path)
        return "" unless @config.epics_home == :repo

        rule = @ignores.reason(path)
        return "" if rule.empty?

        "warning: #{rule} makes git ignore this home, so these epics are invisible to review -- " \
          "repo mode exists to put them in a pull request. Drop that pattern " \
          "(this command never edits .gitignore)."
      end

      # Every session journal this project has written, narrowed to one epic and
      # ordered by the timestamp each record carries.
      #
      # Plural on purpose: an epic spans days and sessions, so the newest-session
      # resolution every other report command uses would silently drop last
      # week's transitions.
      class Journals
        include Enumerable

        def initialize(paths:, root:, epic_slug:)
          @paths = paths
          @root = root
          @epic_slug = epic_slug
        end

        def each(&block)
          return to_enum(:each) unless block

          ordered.each(&block)
          self
        end

        # Which files, in what order, is {SessionJournals}' contract; what stays
        # here is WHICH RECORDS ARE THIS EPIC'S. The extraction also fixed a real
        # defect: `Dir.glob` treats the DIRECTORY name as a pattern, so a
        # `$XDG_STATE_HOME` containing `[` matched nothing -- silently.
        # {SessionJournals} uses `Dir.children` and pins the case.
        def files = walk.files

        # WHICH directory this walk folded, forwarded so {Report} can print it.
        # Journals are keyed on the working directory while the container is
        # keyed on the resolved root, so a report naming only the home would
        # leave two runs with different progress for one epic indistinguishable.
        def dir = walk.dir

        private

        # `sessions_dir`'s OWN default -- the working directory -- and not
        # `project_hash(@root)`, which this line said until the project resolver
        # landed. The two were one string while `@root` WAS `Dir.pwd`; once
        # `@root` became the resolved root this quietly stopped folding the
        # directory `lain epic submit` writes into, and a verdict submitted from
        # a subdirectory became invisible to `status`. The alternative, moving
        # `sessions_dir`, relocates every resumable session on the machine.
        # Pinned by spec/lain/seams/epic_project_keying_seam_spec.rb.
        def walk = @walk ||= SessionJournals.new(dir: @paths.sessions_dir, types: epic_types)

        # A method rather than a constant: a constant's value is evaluated when
        # this file LOADS, and the epic unit loads after the CLI unit.
        #
        # The list bounds WHAT GETS MATERIALIZED, not what gets believed.
        # Ordering has to sort, so without this filter every record of every
        # session this project ever ran lands in one Array for the sake of a
        # handful of epic records. It is not a correctness guard, and a probe
        # proved it: opening it to everything changes no output, because the fold
        # dispatches by type itself and ignores what it does not recognize.
        def epic_types
          [Lain::Epic::IssueTransition::JOURNAL_TYPE,
           Lain::Epic::StageTransition::JOURNAL_TYPE,
           Approval::SignoffQueue::JOURNAL_TYPE]
        end

        # {SessionJournals} has already put every epic record in `ts` order; the
        # only narrowing left is to this epic.
        def ordered = walk.select { |record| attributable?(record) }

        # Ours, or unattributable.
        #
        # A record naming ANOTHER epic is dropped here rather than handed to the
        # fold: this walk spans every session the project ever ran, so
        # {Epic::ForeignJournal} would fire on the normal case and is
        # deliberately unreachable from here.
        #
        # A record with a BLANK slug is kept, so the fold's own guard refuses it.
        # Dropping it would report "nothing happened" for a record that says
        # something did.
        def attributable?(record)
          slug = record["epic_slug"].to_s
          slug.strip.empty? || slug == @epic_slug
        end
      end
      private_constant :Journals

      # The text projection of one {Epic::Progress}: summary, the ready set, the
      # remaining issues by wave. Its own object because rendering is not
      # resolving -- it knows nothing about config, homes, or journals.
      #
      # The boundary is the Progress rather than the prose: the empty-home
      # guidance and the tracking warning are produced BEFORE any epic has been
      # chosen, so moving them here would mean constructing a Report with nothing
      # to report on. They arrive as the `note` this object simply prints.
      class Report
        # `sessions:` is printed rather than merely held: one epic at one home
        # folds different records from different working directories and reports
        # different progress, with nothing else in the output to say why.
        def initialize(slug:, path:, sessions:, progress:, note:)
          @slug = slug
          @path = path
          @sessions = sessions
          @progress = progress
          @note = note
        end

        def to_s = [preamble, ready, remaining].join("\n\n")

        private

        def preamble
          ["epic `#{@slug}` — #{@progress.summary}", "home: #{@path}", "sessions: #{@sessions}", @note]
            .reject(&:empty?).join("\n")
        end

        # First, because it answers "what do I do now". Ready issues appear
        # again below in their wave -- the wave listing is everything that
        # remains, and hiding them would make the dependency picture wrong.
        def ready
          issues = @progress.ready
          return "ready: nothing#{because}" if issues.empty?

          ["ready:", *issues.map { |issue| "  #{glyph(issue)}" }].join("\n")
        end

        # Why nothing is ready, COUNTED rather than asserted. The first draft
        # said "every remaining issue is blocked or already moving", false in
        # five shapes -- an abandoned issue is neither, and on a finished epic it
        # claimed a reason for issues that do not exist, one line above
        # "remaining: nothing". It now tallies the residual set or says nothing.
        def because
          tallies = residual_tally
          tallies.empty? ? "" : " (#{tallies.join(", ")})"
        end

        # `pending` is reported as BLOCKED by derivation: ready is
        # pending-with-every-blocker-done, so while the ready set is empty every
        # pending issue necessarily has an unfinished blocker. Ordered by the
        # pipeline, not by count, so two runs of one epic read the same way.
        def residual_tally
          open = @progress.graph.reject { |issue| issue.status == Lain::Epic::DONE }
          { "blocked" => "pending", "in flight" => "in_flight", "abandoned" => "abandoned" }
            .map { |label, status| [label, open.count { |issue| issue.status == status }] }
            .reject { |_label, count| count.zero? }
            .map { |label, count| "#{count} #{label}" }
        end

        def remaining
          waves = residual_waves
          return "remaining: nothing -- every issue is done" if waves.empty?

          ["remaining, by wave:", *waves.flat_map { |number, issues| wave(number, issues) }].join("\n")
        end

        # {Epic::Graph#waves} is status-blind by design, which is correct as a
        # DAG layering and wrong as a to-do list. Done issues are dropped and an
        # emptied wave disappears, but the survivors KEEP their numbers: a wave
        # names a layer of the graph, which does not move when work lands, and
        # renumbering would make "wave 3" mean something different every morning.
        def residual_waves
          @progress.graph.waves.each_with_index.filter_map do |issues, index|
            open = issues.reject { |issue| issue.status == Lain::Epic::DONE }
            [index + 1, open] unless open.empty?
          end
        end

        def wave(number, issues)
          ["  wave #{number}", *issues.map { |issue| "    #{glyph(issue)}#{blockers(issue)}" }]
        end

        # The blockers still HOLDING this issue -- the same test
        # {Epic::Graph#ready} applies, so the two cannot disagree about stuck.
        def blockers(issue)
          holding = blockage.holding(issue.id)
          return "" if holding.empty?

          " (blocked by #{holding.map { |id| "`#{id}`" }.join(", ")})"
        end

        # Memoized because this report reads one fixed fold: the relation was
        # rebuilt per issue otherwise -- see {Epic::Blockage}.
        def blockage = @blockage ||= Lain::Epic::Blockage.of(@progress.graph)

        # The document's own marks, so a status reads here the way the markdown
        # spells it.
        def glyph(issue)
          "[#{Lain::Epic::Document::STATUS_MARKS.fetch(issue.status)}] `#{issue.id}` #{issue.title}"
        end
      end
      private_constant :Report
    end
  end
end
