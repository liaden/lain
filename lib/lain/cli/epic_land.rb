# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # `lain epic land ISSUE_ID SHA [SLUG]`: put one approved issue's commit on
    # the remote, open its pull request, merge it, and move the issue to done.
    # `--resume` continues one that crashed. Returns Strings and prints nothing
    # -- {CLI::Epic}'s precedent and `spec/output_discipline_spec.rb`'s rule.
    #
    # == The sha is an ARGUMENT, and that is the design
    #
    # No record binds an approved implementation to a commit.
    # {Approval::GateDecision} journals `artifact_digest`, the COMPOSED
    # `(stage, slug, content)` hash, and nothing journals the content -- so the
    # approved sha is genuinely unrecoverable from the journal.
    #
    # The binding is the HASH, not a record. {Epic::Submission.implementation}
    # takes its digest as given, and `lain epic submit implementation --digest`
    # got that string from the human. So this command rebuilds the same
    # Submission from the sha it was handed and lets {Approval::Gate#ensure_approved!}
    # answer: a sha nobody approved hashes to an address the registry has never
    # seen, and the run refuses before the first intent. Landing an unapproved
    # commit is unrepresentable here, not merely detected.
    #
    # Nothing re-hashes a working tree to discover the sha, and nothing journals
    # the content digest at submit time to make discovery possible -- that
    # reverses {Approval::Gate}'s deliberate ignorance of what it gates.
    # {Forge::Promotion::Remote#anchored!} separately refuses anything that is
    # not a full object name naming a commit, so `HEAD`, an abbreviation and a
    # branch name are all rejected downstream of the gate too.
    #
    # == `--resume` takes no sha
    #
    # It DERIVES one from the journaled `promote` intent, which by construction
    # carries the sha the gate already cleared. Accepting one would let a human
    # resume a landing onto a different commit than the one that was approved.
    #
    # == Every constant from the epic and forge tiers is reached at CALL time
    #
    # This unit loads BEFORE `lain/epic` and `lain/forge` (lib/lain.rb: cli,
    # then epic, then forge), so every `Lain::Epic::...` and `Lain::Forge::...`
    # reference below sits inside a method body -- and is spelled `Lain::Epic`,
    # never `Epic`, because a bare `Epic` resolves to the sibling {CLI::Epic}.
    class EpicLand
      # `--resume` was asked to continue a landing this issue's journal holds no
      # promote intent for. Its own class, because "nothing was ever started" and
      # "the run refused" have nothing alike as remedies.
      class NothingToResume < Error; end

      # The command was handed no issue, or no commit to land it at. Named for
      # {EpicSubmit::NeedsIssue}'s reason: "you did not say which" must be
      # distinguishable from a gate that refused.
      class NeedsArguments < Error; end

      # The two forge record types, narrowed to one issue of one epic.
      #
      # One epic holds several landing histories, so a resume folding all of
      # them would report another issue's outstanding intents as this one's --
      # and could read another issue's settled promote as this one's, which is
      # the double-land this filter exists to prevent.
      #
      # Attribution is read from two places because the two records are shaped
      # differently: an {Forge::Intent} carries `epic_slug`/`issue_id` as fields,
      # while an {Forge::Outcome} carries only a digest and gets the same pair
      # stamped into its `detail` by {Forge::Journaled} -- deliberately, so an
      # orphaned outcome can still be traced to somebody's problem. ONE writer
      # stamps both off one object's state, so reading each where it lives
      # cannot split a settled pair: an outcome is kept exactly when its own
      # intent is, and {Forge::Reconcile}'s positional pairing survives the
      # narrowing intact.
      class Scoped
        include Enumerable

        def initialize(records:, epic_slug:, issue_id:)
          @records = records
          @attribution = [epic_slug.to_s, issue_id.to_s].freeze
        end

        def each(&block)
          return to_enum(:each) unless block

          @records.select { |record| attribution(record) == @attribution }.each(&block)
          self
        end

        private

        # An empty attribution for anything else, so a record of some other tier
        # matches no epic and no issue rather than needing a type test at the
        # call site.
        def attribution(record)
          case record["type"].to_s
          when Lain::Forge::Intent::JOURNAL_TYPE then [record["epic_slug"].to_s, record["issue_id"].to_s]
          when Lain::Forge::Outcome::JOURNAL_TYPE then detailed(record["detail"].to_h)
          else []
          end
        end

        def detailed(detail) = [detail["epic_slug"].to_s, detail["issue_id"].to_s]
      end

      # What one landing answered, as the text a human acts on.
      #
      # The branch is named on EVERY outcome, success or not. A stop is only
      # actionable if the reader is told which ref to go look at, and the
      # conflicted answer {Forge::Landing} builds carries a merge state and no
      # address at all.
      class Report
        def initialize(issue_id:, branch:, sha:, answer:, skipped: [])
          @issue_id = issue_id
          @branch = branch
          @sha = sha
          @answer = answer
          @skipped = skipped
        end

        def to_s = [headline, "  branch #{@branch}", *@skipped, *outcome].join("\n")

        private

        def headline = "#{@answer.ok? ? "landed" : "stopped"} #{@issue_id} at #{@sha}"

        def outcome
          return ["  pull request #{numbered} -- merged"] if @answer.ok?

          ["  #{refusal}", "  act on #{@branch} -- nothing else will land this issue"]
        end

        def numbered = @answer.value.nil? ? "(number unrecorded)" : "##{@answer.value}"

        # The three fields are read leniently because they come from different
        # producers: {Forge::Landing}'s conflict carries a `state`, a {Forge::Gh}
        # refusal carries a `message`, a {Forge::Promotion} refusal carries both
        # a `reason` and a `message`, and none of them carries all three.
        def refusal
          said = %w[reason state message].filter_map { |key| @answer.detail[key].to_s }.reject(&:empty?)
          said.empty? ? "refused, with no reason recorded" : said.join(" -- ")
        end
      end

      # Everything one landing needs, wired for one issue against one open
      # journal.
      #
      # Its own object because assembling six collaborators is a different job
      # from choosing a verb and rendering what came back -- and because `land`
      # and `resume` need the SAME six. A second wiring site would be a second
      # chance for the promotion and the journal bracket to be built for
      # different issues, which {Forge::Promotion} documents as a disagreement
      # neither object can detect.
      class Crew
        def initialize(epic_slug:, issue_id:, sha:, journal:, records:, github:, repo_root:, shell_out_factory:)
          journaled = Lain::Forge::Journaled.new(github, journal:, epic_slug:, issue_id:)
          @wiring = { epic_slug:, issue_id:, sha:, journaled:,
                      artifact: Lain::Epic::Submission.implementation(slug: epic_slug, issue_id:, digest: sha),
                      gate: Approval::Gate.from_journal(records, journal:),
                      scribe: Lain::Epic::Scribe.new(epic_slug:, journal:),
                      promotion: Lain::Forge::Promotion.new(epic_slug:, issue_id:, journaled:, repo_root:,
                                                            shell_out_factory:) }.freeze
        end

        def land = Lain::Forge::Landing.new(**@wiring).call

        def resume(entries:, world:) = Lain::Forge::Landing.resume(entries:, world:, **@wiring)
      end

      # @param root [String] the project root: the config, a repo-mode epic
      #   home, and the checkout holding the anchored commit all resolve under it
      # @param paths [Paths] injected, so a spec resolves against a throwaway
      #   XDG state home instead of the real one
      # @param config [Config] `.lain/config.toml`, already read
      # @param epics [CLI::Epic] answers WHICH epic a bare invocation means.
      #   Asked rather than reimplemented, for {CLI::EpicSubmit}'s reason: two
      #   spellings of "the sole epic in the home" would disagree silently.
      # @param shell_out_factory [#call] every git subprocess this command's
      #   collaborators run -- {Forge::Promotion} and {Forge::Reconcile::World}
      #   -- injected the way {CLI::Epic::GitIgnores} injects one, so no spec
      #   needs a repository or a remote
      # @param github [#pr_create, #pr_merge, #pr_view, #pr_list, #merge_state]
      def initialize(root: Dir.pwd, paths: Paths.new, config: Config.load(root:),
                     epics: Epic.new(root:, paths:, config:),
                     shell_out_factory: Mixlib::ShellOut.public_method(:new),
                     github: Lain::Forge::Gh.new(cwd: root, shell_out_factory:))
        @root = root
        @paths = paths
        @epics = epics
        @shell_out_factory = shell_out_factory
        @github = github
      end

      # @param issue_id [String] the issue whose implementation is landing
      # @param sha [String] the FULL object name of the approved commit
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @return [String]
      # @raise [Approval::Gate::NotApproved] before any forge intent, when
      #   nothing approved this (slug, issue, sha)
      def land(issue_id, sha, slug = nil)
        epic_slug = @epics.resolve_slug(slug)
        issue = named!(issue_id, "lain epic land names one issue")
        anchor = named!(sha, "lain epic land takes the full object name of the approved commit")
        answer = crewed(epic_slug, issue, anchor, &:land)
        Report.new(issue_id: issue, branch: branch(epic_slug, issue), sha: anchor, answer:).to_s
      end

      # @param issue_id [String] the issue whose landing is being continued
      # @param slug [String, nil]
      # @return [String]
      # @raise [NothingToResume] when this issue's journal holds no promote
      #   intent, before anything is journaled
      def resume(issue_id, slug = nil)
        epic_slug = @epics.resolve_slug(slug)
        issue = named!(issue_id, "lain epic land --resume names one issue")
        records = journals.to_a
        resumed(epic_slug, issue, records, Scoped.new(records:, epic_slug:, issue_id: issue).to_a)
      end

      private

      # The world is asked ONCE per invocation and shared: {Forge::Reconcile}
      # folds these entries twice (here, to say what was skipped, and again
      # inside {Forge::Landing.resume}), and a second {World} would cost a second
      # `ls-remote` against a remote that can move between them.
      def resumed(epic_slug, issue, records, entries)
        anchor = resumable!(entries, issue)
        world = Lain::Forge::Reconcile::World.live(repo_root: @root, github: @github,
                                                   shell_out_factory: @shell_out_factory)
        report = Lain::Forge::Reconcile.new(entries:, world:).report
        return escalation(report, epic_slug, issue) unless report.orphans.empty? && report.unaddressable.empty?

        answer = crewed(epic_slug, issue, anchor, records) { |crew| crew.resume(entries:, world:) }
        Report.new(issue_id: issue, branch: branch(epic_slug, issue), sha: anchor, answer:,
                   skipped: skipped(report)).to_s
      end

      # The journal is opened around the WHOLE run and closed after --
      # {CLI::EpicSubmit}'s bracket, and for its reason: a Journal that CREATED
      # its file and wrote no record removes it on close, so a refusal leaves no
      # trace on disk.
      def crewed(epic_slug, issue_id, sha, records = journals.to_a)
        journal = Journal.open(paths: @paths)
        begin
          yield Crew.new(epic_slug:, issue_id:, sha:, journal:, records:, github: @github, repo_root: @root,
                         shell_out_factory: @shell_out_factory)
        rescue Approval::Gate::NotApproved => e
          raise Approval::Gate::NotApproved, unapproved(e, epic_slug, issue_id, sha)
        ensure
          journal.close
        end
      end

      # Re-raised rather than returned: `exe/lain` renders a {Lain::Error} as a
      # message with no backtrace and a NONZERO exit, while a String returned
      # here would exit 0 and read as a decision ({CLI::EpicSubmit}'s rule). The
      # message is widened because the gate names only the composed digest, and
      # what a human standing here needs is the command that would approve it.
      def unapproved(error, epic_slug, issue_id, sha)
        "#{error.message} -- nothing was promoted for #{issue_id}; approve it first with " \
          "`lain epic submit implementation #{epic_slug} --issue #{issue_id} --digest #{sha}`"
      end

      # The sha `--resume` continues from, read off the promote intent this
      # issue's own journal recorded -- by construction the one the gate already
      # cleared. The LAST one, because a re-land after a refused promotion
      # journals a second intent and the run being resumed is the latest.
      def resumable!(entries, issue_id)
        promoted = entries.select do |record|
          record["type"] == Lain::Forge::Intent::JOURNAL_TYPE && record["action"] == Lain::Forge::PROMOTE
        end
        sha = promoted.last.to_h.dig("params", "sha").to_s.strip
        raise NothingToResume, nothing_started(issue_id) if sha.empty?

        sha
      end

      def nothing_started(issue_id)
        "no promote intent for issue #{issue_id} -- nothing was ever started, so there is nothing to resume; " \
          "land it with `lain epic land #{issue_id} SHA`"
      end

      # Every session journal this project has written, FRESH per invocation and
      # never memoized. {CLI::EpicSubmit} states the reason in full:
      # {SessionJournals} caches its own walk, so one held here would make a
      # REUSED command fold the world as it was before its own first landing.
      def journals
        SessionJournals.new(dir: @paths.sessions_dir,
                            types: [Approval::SignoffQueue::JOURNAL_TYPE, Lain::Forge::Intent::JOURNAL_TYPE,
                                    Lain::Forge::Outcome::JOURNAL_TYPE])
      end

      def skipped(report)
        report.settled.map { |item| "  skipped #{item.intent.action} -- already settled" } +
          report.unsettled.select(&:completed_externally?)
                .map { |item| "  skipped #{item.intent.action} -- found already in place" }
      end

      # Corruption, reported rather than raised, for the forge tier's own reason:
      # every refusal there is a value the journal can carry, and this one is
      # {Forge::Landing.resume}'s own guard restated where a human can read it.
      def escalation(report, epic_slug, issue_id)
        ["cannot resume #{issue_id}", "  branch #{branch(epic_slug, issue_id)}",
         *report.orphans.map { |item| "  an outcome answers no intent this journal holds (#{item.intent_id})" },
         *report.unaddressable.map { |item| "  #{item.reason}" },
         "  escalate: this issue's journal is inconsistent, and no landing may continue from it"].join("\n")
      end

      # The pull request's head ref, spelled the way {Forge::Landing} spells it.
      # Restated here deliberately: the conflicted answer that class builds
      # carries a merge state and no address, and a stop is only actionable if
      # the reader is told which ref to go look at.
      def branch(epic_slug, issue_id) = "epic/#{epic_slug}/#{issue_id}"

      def named!(value, what)
        named = value.to_s.strip
        raise NeedsArguments, "#{what} -- lain epic land ISSUE_ID SHA [SLUG]" if named.empty?

        named
      end
    end
  end
end
