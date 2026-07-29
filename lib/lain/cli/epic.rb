# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # `lain epic status [SLUG]`: where one epic stands, as text. Returns a
    # String and prints nothing -- only the frontend touches a stream (output
    # discipline; {CLI::Friction}'s precedent, and the shape `render` in
    # exe/lain expects).
    #
    # The projection is the document an author wrote with the Journal's runtime
    # truth folded over it: summary, the ready set, then the remaining issues
    # by wave. Read-only and deterministic -- the same home and the same session
    # files render the same bytes, so two runs are diffable.
    #
    # == The remaining-work rule
    #
    # **Not done is remaining**, where done is {Epic::DONE} and nothing else.
    # `abandoned` is deliberately not finished: it is work somebody stopped, it
    # still blocks whatever it blocked ({Epic::Graph#ready} satisfies a blocker
    # only when it is done), and the only way past it is an edge edit somebody
    # has to make. An earlier draft treated it as finished; the result named an
    # abandoned issue in a `blocked by` annotation while showing it nowhere, so
    # the report explained a blockage with an id the reader could not find. The
    # one rule keeps every id named in an annotation present in the listing
    # above it, and a spec pins exactly that.
    #
    # == Every constant from the epic tier is reached at CALL time
    #
    # This unit loads BEFORE `lain/epic` (lib/lain.rb: cli, then plan, then
    # epic), so a `Lain::Epic::...` reference evaluated while this file loads --
    # a constant assignment, a default argument evaluated at definition -- would
    # raise NameError at boot. Every such reference below therefore sits inside
    # a method body.
    #
    # And it is spelled `Lain::Epic`, never `Epic`: the lexical scope here is
    # `Lain::CLI::Epic`, so a bare `Epic` resolves to THIS class (it is a
    # constant of `Lain::CLI`) and `Epic::Home` would look for
    # `Lain::CLI::Epic::Home`. The full path is not decoration.
    class Epic
      # A slug was given and the home holds no such epic.
      class UnknownEpic < Error; end

      # No slug was given and the home holds more than one epic. Loud rather
      # than a guess: picking the alphabetically-first would report on work the
      # caller never asked about, in a command whose entire job is telling the
      # truth about which work is where.
      class Ambiguous < Error; end

      # The container exists but cannot be listed. Its own class, next to the
      # owner that raises it, for {Epic::Home::UnreadableArtifact}'s reason: an
      # unreadable directory is not "no epics yet", and answering the empty-home
      # message here would report a permissions fault as a fresh project.
      class UnreadableHome < Error
        def initialize(path, cause)
          super("cannot list the epics in #{path}: #{cause.message}")
        end
      end

      # A file the session glob matched cannot be read as a journal. The session
      # directory is a directory the user owns, so a stray `weird.ndjson/`
      # subdirectory (EISDIR) or a mode-000 file (EACCES) is reachable without
      # anything being wrong with this tier -- and a raw
      # `Errno::EISDIR: Is a directory @ io_fillbuf` escapes exe/lain's
      # `rescue Lain::Error` and prints a backtrace at a user who asked for a
      # status report.
      #
      # Named, not skipped: a journal that cannot be read may hold this epic's
      # transitions, and quietly walking past it reports stale progress as
      # current. That is the fold's own never-skip rule, applied one layer out
      # at the file rather than at the record. {Epic::Home::UnreadableArtifact}
      # is the same idea on the artifact side; this walk was the last read path
      # without it.
      # The refusal now belongs to {SessionJournals}, which owns the read. Kept
      # as a name here because it is this command's documented failure and its
      # specs rescue it by this constant -- one name, one class, no second
      # definition to drift.
      UnreadableJournal = SessionJournals::Unreadable

      # Whether git ignores a path, answered by git itself.
      #
      # Repo mode exists for exactly one reason -- so a team can review an epic
      # in a pull request -- and this repository's own .gitignore holds
      # `/.lain/`, which is where repo mode resolves. A repo home can therefore
      # be invisible to the tool it was chosen for. {Epic::Home} deliberately
      # does not detect this: it is a pure path calculator with no Sink and no
      # subprocess, and a warning there would turn a resolver into an I/O
      # object. This command already prints the resolved home, so the check
      # belongs beside that line.
      #
      # Read-only in both directions. It asks a question and NEVER edits
      # .gitignore -- what to ignore is the user's policy, not a status
      # report's.
      #
      # Unanswerable is "not ignored", not a failure: no git on PATH, or a root
      # that is no repository, must not be able to fail a status report over a
      # warning about a setup that may not even be in use.
      class GitIgnores
        # What git says when it will not name the rule. `-v` always prints one,
        # so this is unreachable in practice -- it exists because the alternative
        # to a fallback is an empty reason, and an empty reason reads as "not
        # ignored", which would silently drop a warning that is true.
        UNNAMED = "an ignore rule this git would not name"

        # `Mixlib::ShellOut` rather than backticks or Open3: it is already this
        # project's subprocess runner ({Isolation::Worktree}), and it captures
        # both streams internally, so nothing git says can interleave into a
        # Journal or a TTY.
        def initialize(root, shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @root = root
          @shell_out_factory = shell_out_factory
        end

        # The rule that ignores +path+, or "" when nothing does.
        #
        # A reason and not a predicate, because a warning that says only "this is
        # ignored" leaves the user to go hunt WHICH pattern did it, across a
        # repo's .gitignore, .git/info/exclude, and the global core.excludesFile.
        # `-v` is git answering that for free.
        #
        # Exit 0 is ignored, 1 is not, 128 is could-not-answer (no repository
        # here) -- so only a literal 0 is a yes, and the other two are the same
        # "" as far as a status report is concerned.
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
        # colon, so splitting it into prose risks mangling the one string the
        # user needs to grep for, and `.gitignore:5:/.lain/` is already exactly
        # what they would search.
        def rule(stdout)
          field = stdout.to_s.lines.first.to_s.split("\t").first.to_s.strip
          field.empty? ? UNNAMED : field
        end
      end

      # @param root [String] the project root; the config file and a repo-mode
      #   home both resolve under it
      # @param paths [Paths] injected, so a spec resolves against a throwaway
      #   XDG state home instead of the real one
      # @param config [Config] `.lain/config.toml`, already read
      # @param ignores [#reason] the git question, injected so no spec has to
      #   build a repository to exercise the warning
      def initialize(root: Dir.pwd, paths: Paths.new, config: Config.load(root:), ignores: GitIgnores.new(root))
        @root = root
        @paths = paths
        @config = config
        @ignores = ignores
      end

      # @param slug [String, nil] the epic to report on; omitted resolves to the
      #   sole epic in the home
      # @return [String] the rendered projection, or the guidance an empty home
      #   deserves
      # @raise [Ambiguous, UnknownEpic, UnreadableHome] and any {Lain::Error}
      #   from the home, the document, or the fold -- exe/lain renders all of
      #   them as a message with no backtrace
      def status(slug = nil)
        container = Lain::Epic::Home.container(config: @config, paths: @paths, root: @root)
        slugs = slugs_in(container)
        return unstarted(container) if slugs.empty?

        report(chosen(slug, slugs, container))
      end

      private

      def report(slug)
        home = Lain::Epic::Home.resolve(config: @config, paths: @paths, slug:, root: @root)
        graph = home.read_epic
        progress = Lain::Epic::Progress.fold(records_for(slug), graph:, epic_slug: slug)
        Report.new(slug:, path: home.path, progress:, note: untracked_note(home.path)).to_s
      end

      def records_for(slug) = Journals.new(paths: @paths, root: @root, epic_slug: slug).to_a

      # A directory whose name is a legal slug. Anything else -- a stray file, an
      # editor's backup, a name the filesystem grammar refuses -- is skipped
      # rather than refused: no epic can be spelled that way, so there is nothing
      # here to be loud about, and refusing to report on a real epic because
      # somebody dropped a `.DS_Store` beside it would be absurd.
      def slugs_in(container)
        return [] unless File.directory?(container)

        Dir.children(container).select { |entry| epic_dir?(container, entry) }.sort
      rescue SystemCallError => e
        raise UnreadableHome.new(container, e)
      end

      def epic_dir?(container, entry)
        Lain::Epic::Home::NAME.match?(entry) && File.directory?(File.join(container, entry))
      end

      def chosen(slug, slugs, container)
        return sole(slugs, container) if slug.nil?
        return slug if slugs.include?(slug)

        raise UnknownEpic, "no epic #{slug.inspect} in #{container} -- it holds #{listed(slugs)}"
      end

      def sole(slugs, container)
        return slugs.first if slugs.one?

        raise Ambiguous, "#{container} holds #{slugs.size} epics (#{listed(slugs)}) -- " \
                         "name one: lain epic status SLUG"
      end

      def listed(slugs) = slugs.map { |slug| "`#{slug}`" }.join(", ")

      # An empty home is a fresh project, not a failure: it returns the guidance
      # a caller can act on and exits 0, where a raise would print to stderr and
      # exit nonzero over a state every epic passes through.
      def unstarted(container)
        ["no epics yet in #{container}", untracked_note(container),
         "start one with the research-epic skill -- it interviews you, writes research.md, " \
         "and lands epic.md in a new <slug>/ directory here"].reject(&:empty?).join("\n")
      end

      # Said in the output rather than raised: an ignored repo home is a
      # misconfiguration, and the status it hides is exactly what the caller
      # asked for. Only repo mode can have it -- an xdg home is outside the
      # repository by design, and calling that "untracked" would be noise about
      # the arrangement working correctly, so git is not even asked.
      #
      # The rule is named in the message because the actionable half of this
      # warning is WHICH pattern to drop, not that one exists.
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
      # Plural on purpose. An epic spans days and sessions, so the
      # newest-session resolution every other report command uses ({CLI::Friction},
      # `--resume`) would silently drop last week's transitions -- and a status
      # report that quietly under-reports progress is worse than one that
      # refuses.
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

        # Which files, in what order, is {SessionJournals}' contract and no
        # longer restated here -- `lain epic queue` folds the same directory for
        # the same reason, and two statements of one rule is how this chunk
        # already produced a silent bug. What stays here is the part that is
        # genuinely this command's: WHICH RECORDS ARE THIS EPIC'S.
        #
        # The extraction also fixed a real defect this method had: `Dir.glob`
        # treats the DIRECTORY name as a pattern, so a `$XDG_STATE_HOME`
        # containing `[` matched nothing -- silently. {SessionJournals} uses
        # `Dir.children`, the house idiom, and pins the case.
        def files = walk.files

        private

        def walk
          @walk ||= SessionJournals.new(dir: @paths.sessions_dir(project: @paths.project_hash(@root)),
                                        types: epic_types)
        end

        # A method rather than a constant: a constant's value is evaluated when
        # this file LOADS, and the epic unit loads after the CLI unit (see the
        # class comment above).
        #
        # What this list is for, stated accurately because it is easy to
        # overclaim: it bounds WHAT GETS MATERIALIZED, not what gets believed.
        # Ordering has to sort, so the kept records become an Array; without this
        # filter every record of every session this project ever ran -- months of
        # turns and messages -- lands in one Array to be sorted, for the sake of
        # a handful of epic records. It is not a correctness guard, and a probe
        # proved it: opening this filter to everything changes no output, because
        # the fold dispatches by type itself (`Journal.records(records, type:)`)
        # and ignores whatever it does not recognize.
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
        # fold. This walk spans every session the project ever ran, so most epic
        # records in it belong to other epics -- {Epic::ForeignJournal}, which
        # protects a caller handing one journal for one epic, would fire on the
        # normal case and is deliberately unreachable from here.
        #
        # A record with a BLANK slug is kept, so the fold's own guard refuses it.
        # It cannot be attributed away, and dropping it would report "nothing
        # happened" for a record that says something did -- the one answer the
        # Journal exists to prevent.
        def attributable?(record)
          slug = record["epic_slug"].to_s
          slug.strip.empty? || slug == @epic_slug
        end
      end
      private_constant :Journals

      # The text projection of one {Epic::Progress}: summary, the ready set, the
      # remaining issues by wave. Its own object because rendering is not
      # resolving -- this one knows nothing about config, homes, or journals, and
      # is handed the settled value.
      #
      # It is NOT all the text this command emits, and the boundary is the
      # Progress rather than the prose: the empty-home guidance and the tracking
      # warning are both produced BEFORE any epic has been chosen, when there is
      # no Progress to project and possibly no epic at all. Moving them here
      # would mean constructing a Report with nothing to report on, so they stay
      # on the command and arrive as the `note` this object simply prints.
      class Report
        def initialize(slug:, path:, progress:, note:)
          @slug = slug
          @path = path
          @progress = progress
          @note = note
        end

        def to_s = [preamble, ready, remaining].join("\n\n")

        private

        def preamble
          ["epic `#{@slug}` — #{@progress.summary}", "home: #{@path}", @note].reject(&:empty?).join("\n")
        end

        # First, because it is the one section that answers "what do I do now".
        # Ready issues appear again below in their wave -- the wave listing is
        # everything that remains, and hiding the ready ones from it would make
        # the dependency picture wrong to save two lines.
        def ready
          issues = @progress.ready
          return "ready: nothing#{because}" if issues.empty?

          ["ready:", *issues.map { |issue| "  #{glyph(issue)}" }].join("\n")
        end

        # Why nothing is ready, COUNTED rather than asserted. The first draft
        # said "every remaining issue is blocked or already moving", which was
        # false in five shapes -- an abandoned issue is neither, and on a
        # finished or empty epic it claimed a reason for issues that do not
        # exist, one line above "remaining: nothing". A summary line that states
        # a cause it never computed is the first thing a reader hits, so it now
        # tallies the residual set or says nothing at all.
        def because
          tallies = residual_tally
          tallies.empty? ? "" : " (#{tallies.join(", ")})"
        end

        # `pending` is reported as BLOCKED, and that is a derivation rather than
        # a guess: ready is pending-with-every-blocker-done, so while the ready
        # set is empty every pending issue necessarily has an unfinished blocker.
        # Ordered by the pipeline's own reading, not by count, so two runs of the
        # same epic read the same way.
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

        # {Epic::Graph#waves} is status-blind by design -- a finished first wave
        # still reports as wave 1, which is correct as a DAG layering and wrong
        # as a to-do list. So the done issues are dropped here and an emptied
        # wave disappears, while the surviving waves KEEP their original
        # numbers: a wave number names a layer of the graph, which does not move
        # when work lands, and renumbering would make "wave 3" mean something
        # different every morning.
        def residual_waves
          @progress.graph.waves.each_with_index.filter_map do |issues, index|
            open = issues.reject { |issue| issue.status == Lain::Epic::DONE }
            [index + 1, open] unless open.empty?
          end
        end

        def wave(number, issues)
          ["  wave #{number}", *issues.map { |issue| "    #{glyph(issue)}#{blockers(issue)}" }]
        end

        # The blockers still HOLDING this issue, which is why it is not in the
        # ready set -- the same test {Epic::Graph#ready} applies, so the two
        # cannot disagree about whether an issue is stuck.
        def blockers(issue)
          holding = @progress.graph.blocked_by(issue.id).reject { |id| @progress.status(id) == Lain::Epic::DONE }
          return "" if holding.empty?

          " (blocked by #{holding.map { |id| "`#{id}`" }.join(", ")})"
        end

        # The document's own marks, so the status a reader sees here is spelled
        # the way the markdown spells it.
        def glyph(issue)
          "[#{Lain::Epic::Document::STATUS_MARKS.fetch(issue.status)}] `#{issue.id}` #{issue.title}"
        end
      end
      private_constant :Report
    end
  end
end
