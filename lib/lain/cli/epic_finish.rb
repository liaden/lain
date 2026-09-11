# frozen_string_literal: true

module Lain
  module CLI
    # `lain epic finish [SLUG]`: take an epic whose every issue is done to main
    # as ONE pull request. {Forge::Landing} promotes `epic/<slug>`, opens the
    # pull request against main, merges it and deletes the remote branch. The
    # local branch stays: worktree gc reaps it once main holds it. Returns
    # Strings and prints nothing.
    #
    # RE-RUNNABLE. Every run folds this epic's own forge records, so a run that
    # stopped continues from what the journal and the remote agree on, and a
    # finished one changes nothing.
    #
    # Every constant from the epic, forge and isolation tiers is reached at
    # call time and spelled in full: this unit loads before them.
    class EpicFinish
      # An epic with an issue that has not landed. Refused before anything
      # reaches the remote.
      class Unfinished < Error; end

      # This epic's forge records, and nobody else's. An {Intent} carries its
      # epic and issue as fields; an {Outcome} carries them in its `detail`,
      # stamped by {Forge::Journaled}, so each is read where it lives and a
      # settled pair cannot be split by the narrowing.
      class Scoped
        include Enumerable

        def initialize(records:, epic_slug:)
          @records = records
          @attribution = [epic_slug.to_s, Lain::Forge::Landing::WHOLE_EPIC].freeze
        end

        def each(&block)
          return to_enum(:each) unless block

          @records.select { |record| attribution(record) == @attribution }.each(&block)
          self
        end

        private

        def attribution(record)
          case record["type"].to_s
          when Lain::Forge::Intent::JOURNAL_TYPE then [record["epic_slug"].to_s, record["issue_id"].to_s]
          when Lain::Forge::Outcome::JOURNAL_TYPE then detailed(record["detail"].to_h)
          else []
          end
        end

        def detailed(detail) = [detail["epic_slug"].to_s, detail["issue_id"].to_s]
      end

      # @param root [String] the project root, which is also the checkout
      #   holding `epic/<slug>`
      # @param paths [Paths] injected, so a spec resolves a throwaway state home
      # @param config [Config] `.lain/config.toml`, already read
      # @param epics [CLI::Epic] answers WHICH epic a bare invocation means
      # @param shell_out_factory [#call] every git subprocess
      # @param github [#pr_create, #pr_merge, #pr_view, #pr_list, #merge_state]
      #   {Forge::Gh} keeps its own subprocess runner, since `gh` needs a cwd,
      #   a timeout and a stdin that {Shell::Out} does not take
      def initialize(root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                     epics: Epic.new(root:, paths:, config:),
                     shell_out_factory: Shell::Out.public_method(:new), github: Lain::Forge::Gh.new(cwd: root))
        @root = root
        @paths = paths
        @epics = epics
        @shell_out_factory = shell_out_factory
        @github = github
      end

      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @return [String]
      # @raise [Unfinished] naming every issue that is not done
      def finish(slug = nil)
        epic_slug = @epics.resolve_slug(slug, command: "epic finish")
        finished!(epic_slug)
        sha = tip(epic_slug)
        told(epic_slug, sha, landed(epic_slug, sha))
      end

      private

      def finished!(epic_slug)
        open = @epics.progress(epic_slug).graph.reject { |issue| issue.status == Lain::Epic::DONE }
        return if open.empty?

        raise Unfinished, "epic #{epic_slug} is not finished: " \
                          "#{open.map { |issue| "#{issue.id} is #{issue.status}" }.join(", ")} -- every issue " \
                          "lands on epic/#{epic_slug} first (`lain epic land ISSUE_ID #{epic_slug}`), and nothing " \
                          "reached the remote"
      end

      def tip(epic_slug)
        checkout = Lain::Isolation::Checkout.new(@root, shell_out_factory: @shell_out_factory)
        Lain::Isolation::WorkingBranch.new("epic/#{epic_slug}", repo_root: @root, git: checkout).tip
      end

      # {CLI::EpicSubmit}'s bracket: a Journal that created its file and wrote
      # no record removes it on close, so a run that changed nothing leaves no
      # trace on disk.
      def landed(epic_slug, sha)
        entries = Scoped.new(records: journals.to_a, epic_slug:).to_a
        journal = Journal.open(paths: @paths)
        begin
          folded(entries, wiring(epic_slug, sha, journal))
        ensure
          journal.close
        end
      end

      # A first run knows nothing; any later one folds what earlier runs journaled.
      def folded(entries, wiring)
        return Lain::Forge::Landing.new(**wiring).call if entries.empty?

        Lain::Forge::Landing.resume(entries:, world:, **wiring)
      end

      def wiring(epic_slug, sha, journal)
        journaled = Lain::Forge::Journaled.new(@github, journal:, epic_slug:, issue_id: Lain::Forge::Landing::WHOLE_EPIC)
        { epic_slug:, sha:, journaled:,
          promotion: Lain::Forge::Promotion.new(epic_slug:, journaled:, repo_root: @root,
                                                shell_out_factory: @shell_out_factory) }
      end

      def world
        Lain::Forge::Reconcile::World.live(repo_root: @root, github: @github,
                                           shell_out_factory: @shell_out_factory)
      end

      # FRESH per invocation, never memoized: {SessionJournals} caches its walk.
      def journals
        SessionJournals.new(dir: @paths.sessions_dir,
                            types: [Lain::Forge::Intent::JOURNAL_TYPE, Lain::Forge::Outcome::JOURNAL_TYPE])
      end

      def told(epic_slug, sha, answer)
        head = ["#{answer.ok? ? "finished" : "stopped"} #{epic_slug} at #{sha}", "  branch epic/#{epic_slug}"]
        (head + (answer.ok? ? finished(epic_slug, answer) : stopped(answer))).join("\n")
      end

      def finished(epic_slug, answer)
        ["  pull request ##{answer.value} -- merged",
         "  the remote branch is gone; the local epic/#{epic_slug} is left for `lain worktrees gc` once main holds it"]
      end

      # Read leniently because the producers differ: {Forge::Landing}'s
      # conflict carries a `state`, a {Forge::Gh} refusal a `message`, a
      # {Forge::Promotion} refusal both.
      def stopped(answer)
        said = %w[reason state message].filter_map { |key| answer.detail[key].to_s }.reject(&:empty?)
        ["  #{said.empty? ? "refused, with no reason recorded" : said.join(" -- ")}",
         "  nothing else finishes this epic until that is settled; run `lain epic finish` again after"]
      end
    end
  end
end
