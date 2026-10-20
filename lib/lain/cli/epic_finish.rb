# frozen_string_literal: true

module Lain
  module CLI
    # `lain epic finish [SLUG]`: take an epic whose every issue is done to main
    # as ONE pull request. {Forge::Landing} promotes `epic/<slug>`, opens the
    # pull request against main, merges it and deletes the remote branch. The
    # local branch stays: worktree gc reaps it once main holds it. Returns a
    # {Said} and prints nothing.
    #
    # `--local` is the same finish for a repository with no remote:
    # {Forge::LocalFinish} merges `epic/<slug>` into main in place, journaled
    # as a `local_merge` so the remote fold never reads it as its own merge.
    #
    # RE-RUNNABLE. Every run folds this epic's own forge records, so a run that
    # stopped continues from what the journal and the remote agree on, and a
    # finished one changes nothing.
    #
    # Every constant from the epic, forge and isolation tiers is spelled in
    # full: a bare `Epic` here resolves to the sibling {CLI::Epic}.
    class EpicFinish
      # An epic with an issue that has not landed. Refused before anything is
      # pushed or merged.
      class Unfinished < Error; end

      # An epic with no `epic/<slug>` branch to finish. Refused before anything
      # is pushed or merged.
      class NoBranch < Error; end

      # A remote finish in a repository with no remote. Refused before anything
      # is journaled, naming the finish that does apply.
      class NoRemote < Error; end

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
      # @param config [Config] `.lain/config.rb`, already read
      # @param epics [CLI::Epic] answers WHICH epic a bare invocation means
      # @param shell_out_factory [#call] every git subprocess
      # @param github [#pr_create, #pr_merge, #pr_view, #pr_list, #merge_state]
      # @param finisher [#call, #finished, #rerun, #untouched] {Remote}, or
      #   {Local} to merge into main here with no remote and no pull request
      def initialize(root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                     epics: Epic.new(root:, paths:, config:),
                     shell_out_factory: Shell::Out.public_method(:new), github: Lain::Forge::Gh.new(cwd: root),
                     finisher: Remote.new(root:, paths:, github:, shell_out_factory:))
        @root = root
        @paths = paths
        @epics = epics
        @shell_out_factory = shell_out_factory
        @github = github
        @finisher = finisher
      end

      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @return [Said] status 1 when the finish stopped, else 0
      # @raise [Unfinished] naming every issue that is not done
      def finish(slug = nil)
        epic_slug = @epics.resolve_slug(slug, remedy: Lain::Epic::Remedy.finish("SLUG"))
        finished!(epic_slug)
        sha = tip(epic_slug)
        told(epic_slug, sha, journaling { |journal| @finisher.call(epic_slug, sha, journaled(epic_slug, journal)) })
      end

      private

      def finished!(epic_slug)
        open = @epics.progress(epic_slug).graph.reject { |issue| issue.status == Lain::Epic::DONE }
        return if open.empty?

        raise Unfinished, "epic #{epic_slug} is not finished: " \
                          "#{open.map { |issue| "#{issue.id} is #{issue.status}" }.join(", ")} -- " \
                          "#{remedies(epic_slug, open).join(", and ")}, and #{@finisher.untouched}"
      end

      # An abandoned issue is work somebody dropped; landing it would ship that work.
      def remedies(epic_slug, open)
        abandoned, landable = open.partition { |issue| issue.status == "abandoned" }
        [(land_remedy(epic_slug) unless landable.empty?), (drop_remedy(abandoned) unless abandoned.empty?)].compact
      end

      def land_remedy(epic_slug)
        "every issue lands on epic/#{epic_slug} first (`#{Lain::Epic::Remedy.land("ISSUE_ID", epic_slug)}`)"
      end

      def drop_remedy(abandoned)
        "mark #{abandoned.size == 1 ? "it" : "each abandoned one"} done or remove it from epic.md, never land it"
      end

      def tip(epic_slug)
        branch = "epic/#{epic_slug}"
        checkout = Lain::Isolation::Checkout.new(@root, shell_out_factory: @shell_out_factory)
        if checkout.target("refs/heads/#{branch}").empty?
          raise NoBranch, "there is no #{branch} branch in #{@root} -- #{@finisher.untouched}"
        end

        Lain::Isolation::WorkingBranch.new(branch, repo_root: @root, git: checkout).tip
      end

      # {CLI::EpicSubmit}'s bracket: a Journal that created its file and wrote
      # no record removes it on close, so a run that changed nothing leaves no
      # trace on disk.
      def journaling
        journal = Journal.open(paths: @paths)
        begin
          yield journal
        ensure
          journal.close
        end
      end

      def journaled(epic_slug, journal)
        Lain::Forge::Journaled.new(@github, journal:, epic_slug:, issue_id: Lain::Forge::Landing::WHOLE_EPIC)
      end

      def told(epic_slug, sha, answer)
        head = ["#{answer.ok? ? "finished" : "stopped"} #{epic_slug} at #{sha}", "  branch epic/#{epic_slug}"]
        lines = head + (answer.ok? ? @finisher.finished(epic_slug, answer) : stopped(epic_slug, answer))
        Said.new(text: lines.join("\n"), status: answer.ok? ? 0 : 1)
      end

      # Read leniently because the producers differ: {Forge::Landing}'s
      # conflict carries a `state`, a {Forge::Gh} refusal a `message`, a
      # {Forge::Promotion} refusal both.
      def stopped(epic_slug, answer)
        said = %w[reason state message].map { |key| answer.detail[key].to_s }.reject(&:empty?)
        ["  #{said.empty? ? "refused, with no reason recorded" : said.join(" -- ")}",
         "  nothing else finishes this epic until that is settled; run `#{@finisher.rerun(epic_slug)}` again after"]
      end
    end

    class EpicFinish
      # The epic to main as one pull request through {Forge::Landing}. Every
      # run folds this epic's own forge records, so a run that stopped
      # continues from what the journal and the remote agree on.
      class Remote
        def initialize(root:, paths:, github:, shell_out_factory:)
          @root = root
          @paths = paths
          @github = github
          @shell_out_factory = shell_out_factory
        end

        # @return [Forge::Gh::Answer]
        def call(epic_slug, sha, journaled)
          raise NoRemote, no_remote(epic_slug) unless remote?

          entries = Scoped.new(records: journals.to_a, epic_slug:).to_a
          folded(entries, wiring(epic_slug, sha, journaled))
        end

        def finished(epic_slug, answer)
          ["  pull request ##{answer.value} -- merged",
           "  the remote branch is gone; the local epic/#{epic_slug} is left for `lain worktrees gc` once main " \
           "holds it"]
        end

        def rerun(epic_slug) = Lain::Epic::Remedy.finish(epic_slug)

        def untouched = "nothing reached the remote"

        private

        def remote?
          checkout = Lain::Isolation::Checkout.new(@root, shell_out_factory: @shell_out_factory)
          !checkout.run("remote").stdout.strip.empty?
        end

        def no_remote(epic_slug)
          "this repository has no remote; finish it with #{Lain::Epic::Remedy.finish(epic_slug, local: true)}"
        end

        # A first run knows nothing; any later one folds what earlier runs journaled.
        def folded(entries, wiring)
          return Lain::Forge::Landing.new(**wiring).call if entries.empty?

          Lain::Forge::Landing.resume(entries:, world:, **wiring)
        end

        def wiring(epic_slug, sha, journaled)
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
      end

      # The epic merged into main in this repository, with no remote. Nothing
      # is folded: git answers whether main already holds the tip.
      class Local
        BASE = Lain::Forge::Landing::BASE

        def initialize(root: Project::Resolver.default_project.root, shell_out_factory: Shell::Out.public_method(:new))
          @local_finish = Lain::Forge::LocalFinish.new(root:, shell_out_factory:)
        end

        # @return [Forge::Gh::Answer]
        def call(epic_slug, sha, journaled)
          params = { "head" => "epic/#{epic_slug}", "base" => BASE, "sha" => sha }
          journaled.attempt(action: Lain::Forge::LOCAL_MERGE, params:) do
            @local_finish.call(slug: epic_slug, base: BASE, sha:)
          end
        end

        def finished(_epic_slug, answer) = ["  merged into #{BASE} at #{answer.value}; nothing was pushed"]

        def rerun(epic_slug) = Lain::Epic::Remedy.finish(epic_slug, local: true)

        def untouched = "nothing merged into #{BASE}"
      end
    end
  end
end
