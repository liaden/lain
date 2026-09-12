# frozen_string_literal: true

require "fileutils"
require "time"

module Lain
  module CLI
    # `lain worktrees gc`: runs {Isolation::Gc} over the current repository,
    # journals every decision under {Paths#state_home}, and answers what it
    # reaped and kept. Returns a String; only the exe says it, and for the
    # daily detached run that lands in the log {GcSchedule} opened.
    #
    # The repository and its worktree root come from {IsolationBackend}'s own
    # public search and formula, so the reaper sweeps the directory workers
    # are actually leased under. A seam spec holds the two to that answer.
    #
    # ONE RUN PER REPOSITORY AT A TIME, under an `flock`. Two runs would race
    # each other's claims and report each other's removals as git refusals.
    # A second run has nothing to add, so it stops at once and says so rather
    # than waiting: the daily run is detached and nobody is there to wait.
    class Worktrees
      # Refused by name, since outside a repository there is nothing to reap.
      class NotARepository < Error; end

      # @param root [String] the project's root, as chat resolves it: where the
      #   repository search starts and `.lain/config.toml` is read
      # @param paths [Paths] supplies the worktree root, the journal's home and
      #   the XDG bases the repository search stops at
      # @param home [String, nil] the user's home directory, where the
      #   repository search stops. NOT `Dir.home`, which raises a bare
      #   ArgumentError with HOME unset, where nil is refused here by name.
      # @param gc_factory [#call] builds the reaper
      # @param config [#call] loads the project's `.lain/config.toml`
      # @param clock [#call] answers now, for the run's header
      def initialize(root:, paths: Paths.new,
                     home: ENV.fetch("HOME", nil), # rubocop:disable Style/EnvHome -- see the `home:` tag
                     gc_factory: Isolation::Gc.public_method(:new), config: Config.public_method(:load),
                     clock: -> { Time.now })
        @root = Project::Resolver.resolved(File.expand_path(root), File)
        @paths = paths
        @home = home
        @gc_factory = gc_factory
        @config = config
        @clock = clock
      end

      # @return [String] a header, each reap and keep with its reason, then a count
      # @raise [NotARepository] outside a git repository
      def gc
        repo = repo_root
        exclusively(repo) { run(repo) }
      end

      private

      def run(repo)
        records = journaled(repo) { |journal| reaper(repo, journal).call }
        report = Report.new(records:, header: "lain worktrees gc at #{@clock.call.utc.iso8601} in #{repo}",
                            reported: reported(repo))
        File.write(state("anchors", repo), report.anchors.map { |name| "#{name}\n" }.join)
        report.to_s
      end

      def exclusively(repo)
        FileUtils.mkdir_p(File.dirname(state("lock", repo)))
        File.open(state("lock", repo), File::RDWR | File::CREAT) do |lock|
          return "another lain worktrees gc is running for #{repo}; this run did nothing" unless
            lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      def reaper(repo, journal)
        @gc_factory.call(repo_root: repo, root: IsolationBackend.worktree_root(repo, paths: @paths),
                         retain_days: @config.call(root: @root).isolation.retain_days, journal:)
      end

      def journaled(repo)
        journal = Journal.open(state("ndjson", repo))
        yield journal
      ensure
        journal&.close
      end

      # The anchors the last run already reported, so this one names only the
      # ones that are new.
      def reported(repo)
        File.exist?(state("anchors", repo)) ? File.readlines(state("anchors", repo), chomp: true) : []
      end

      def state(kind, repo) = File.join(@paths.state_home, "gc", "worktrees-#{@paths.project_hash(repo)}.#{kind}")

      def repo_root
        nearest = Project::Repository.nearest(@root, paths: @paths, home: @home)
        return nearest.path if nearest.found?

        raise NotARepository, "lain worktrees gc needs a git repository, and #{nearest.searched(@root)}"
      rescue Project::Resolver::UnusableHome => e
        raise NotARepository, "lain worktrees gc stops its repository search at $HOME, and #{e.message}"
      end

      # What one run says. Kept anchors are kept indefinitely, so a daily log
      # that re-listed each one would bury the day's news under the same lines
      # every morning: they are a count, plus the ones not reported before.
      class Report
        # @param records [Array<Telemetry::WorktreeReap>]
        # @param header [String] the run's first line
        # @param reported [Array<String>] anchors an earlier run already named
        def initialize(records:, header:, reported:)
          @records = records
          @header = header
          @reported = reported
        end

        # @return [Array<String>] every anchor this run kept
        def anchors = kept_anchors.map(&:name)

        def to_s
          return "#{@header}\nnothing to reap or keep" if @records.empty?

          [@header, *decisions, *summary, total].join("\n")
        end

        private

        def kept_anchors = @records.select { |record| record.subject == :anchor && !record.reaped? }

        def decisions
          (@records - kept_anchors).map do |record|
            "#{record.action} #{record.subject} #{record.name}: #{record.reason}"
          end
        end

        def summary
          return [] if anchors.empty?

          fresh = anchors - @reported
          noun = anchors.size == 1 ? "anchor" : "anchors"
          news = fresh.empty? ? "none new since the last run" : "#{fresh.size} new since the last run:"
          ["kept #{anchors.size} #{noun} no branch reaches, #{news}", *fresh.map { |name| "  #{name}" }]
        end

        def total
          reaped = @records.count(&:reaped?)
          "#{reaped} reaped, #{@records.size - reaped} kept"
        end
      end
    end
  end
end
