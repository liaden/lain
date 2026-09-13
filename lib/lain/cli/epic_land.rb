# frozen_string_literal: true

module Lain
  module CLI
    # `lain epic land ISSUE_ID [SLUG]`: land one approved issue's commit onto
    # the epic's working branch in this checkout, and move the issue to done.
    # `--resume` finishes a landing that merged and then stopped. Nothing is
    # pushed; `lain epic finish` takes the epic to the remote, once. Returns
    # Strings and prints nothing.
    #
    # THE COMMIT IS FOUND, NOT NAMED. A handback anchors a worker's commits
    # under `refs/lain/worker/`, and the implementation gate approved one of
    # them by its address, so the commit that lands is the anchored one whose
    # address the gate holds. Nothing re-hashes a working tree, and a commit
    # nobody approved has no address the registry has seen.
    #
    # Every constant from the epic, forge and isolation tiers is reached at
    # call time and spelled in full: this unit loads before them, and a bare
    # `Epic` resolves to the sibling {CLI::Epic}.
    class EpicLand
      USAGE = "lain epic land ISSUE_ID [SLUG]"

      # `root:` defaults to the RESOLVED project's, for {CLI::Epic#initialize}'s
      # reason: this command asks that object which epic a bare invocation means.
      #
      # @param root [String] the project root, which is also the parent checkout
      # @param paths [Paths] injected, so a spec resolves a throwaway state home
      # @param config [Config] `.lain/config.toml`, already read
      # @param epics [CLI::Epic] answers WHICH epic a bare invocation means
      # @param shell_out_factory [#call] every git subprocess the landing runs
      # @param notice [#call] told who holds the parent checkout when a landing
      #   waits on it for long
      def initialize(root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                     epics: Epic.new(root:, paths:, config:), shell_out_factory: Shell::Out.public_method(:new),
                     notice: Lain::Isolation::ParentLock::Silent)
        @root = root
        @paths = paths
        @config = config
        @epics = epics
        @shell_out_factory = shell_out_factory
        @notice = notice
      end

      # @return [String]
      # @raise [Lain::Error] every refusal, each before anything merges
      def land(issue_id, slug = nil)
        epic_slug = @epics.resolve_slug(slug, command: "epic land ISSUE_ID")
        issue = named!(issue_id)
        wired(epic_slug) { |landing| Told.new(epic_slug).landed(landing.land(landing.anchored(issue))) }
      end

      # @return [String]
      # @raise [Error] when nothing merged
      def resume(issue_id, slug = nil)
        epic_slug = @epics.resolve_slug(slug, command: "epic land --resume ISSUE_ID")
        issue = named!(issue_id)
        wired(epic_slug) { |landing| Told.new(epic_slug).resumed(landing.resume(issue)) }
      end

      # What a landing came to, as the text a human acts on.
      class Told
        def initialize(epic_slug)
          @epic_slug = epic_slug
          @branch = "epic/#{epic_slug}"
        end

        def landed(result) = result.landed.map { |entry| entry.done ? done(entry) : stopped(entry) }.join("\n")

        def resumed(result)
          result.landed.map do |entry|
            ["resumed #{entry.issue_id} at #{entry.sha}: #{@branch} already holds it, so nothing was merged",
             moved(entry)].join("\n")
          end.join("\n")
        end

        private

        def done(entry)
          ["landed #{entry.issue_id} at #{entry.sha} onto #{@branch} -- #{how(entry.report)}", moved(entry),
           "  nothing was pushed; `lain epic finish #{@epic_slug}` takes the epic to the remote once every " \
           "issue is done"].join("\n")
        end

        def how(report)
          case report.kind
          when :nothing_to_do then "it was already there"
          when :resolved then "resolved in #{report.paths.join(", ")}, merged as #{report.sha}"
          else report.fast_forward ? "a fast-forward" : "merged as #{report.sha}"
          end
        end

        def moved(entry) = "  #{entry.issue_id} moved in_flight -> done"

        def stopped(entry)
          ["stopped #{entry.issue_id} at #{entry.sha} -- nothing landed on #{@branch}",
           "  #{entry.report.summary.empty? ? entry.report.kind : entry.report.summary}"].join("\n")
        end
      end

      private

      # {CLI::EpicSubmit}'s bracket: a Journal that created its file and wrote
      # no record removes it on close, so a refusal leaves no trace on disk.
      def wired(epic_slug)
        journal = Journal.open(paths: @paths)
        begin
          yield landing(epic_slug, journal)
        ensure
          journal.close
        end
      end

      def landing(epic_slug, journal)
        base = Lain::Isolation::WorkingBranch.new("epic/#{epic_slug}", repo_root: @root, git: checkout)
        Lain::Forge::LocalLanding.new(
          epic_slug:, repo_root: @root, base:, approvals:,
          plan: ->(issue) { submit.ensure_plan_approved!(issue, epic_slug) },
          progress: -> { @epics.progress(epic_slug) }, scribe: Lain::Epic::Scribe.new(epic_slug:, journal:),
          queue: queue(base, journal), layout: Config.test_layout(root: @root), landings: -> { landings.to_a },
          shell_out_factory: @shell_out_factory
        )
      end

      def queue(base, journal)
        Lain::Isolation::LandingQueue.new(repo_root: @root, base:, journal:, retries: @config.isolation.rebase_retries,
                                          strategy: Lain::Isolation::MergeStrategy.from(@config.isolation),
                                          notice: @notice, shell_out_factory: @shell_out_factory)
      end

      def checkout = Lain::Isolation::Checkout.new(@root, shell_out_factory: @shell_out_factory)

      def approvals = Lain::Forge::LocalLanding::Approvals.from(journals.to_a)

      def submit = EpicSubmit.new(root: @root, paths: @paths, config: @config, epics: @epics)

      # FRESH per invocation, never memoized, for {CLI::EpicSubmit#journals}'
      # reason: {SessionJournals} caches its own walk.
      def journals = SessionJournals.new(dir: @paths.sessions_dir, types: [Approval::SignoffQueue::JOURNAL_TYPE])

      def landings = SessionJournals.new(dir: @paths.sessions_dir, types: [Lain::Forge::LocalLanding::LANDED])

      def named!(value)
        named = value.to_s.strip
        # Said in its own words so "you did not say which" reads apart from a
        # refusal of an issue that exists.
        raise Error, "lain epic land names one issue -- #{USAGE}" if named.empty?

        named
      end
    end
  end
end
