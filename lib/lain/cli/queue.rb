# frozen_string_literal: true

require "json"
require "thor"

module Lain
  module CLI
    # `lain queue here|local|prs|show`: what a reviewer should look at next, one
    # line per row. Rows carry text from outside (a plan's title, a pull
    # request's title, a branch name), so {Entry} is the one place a row becomes
    # a line and it takes that text apart first.
    class Queue < ::Thor
      include Exe::Boundary

      namespace "queue"

      # A row as text: every field safe to print, whichever source wrote it.
      class Entry
        ESCAPES = %r{\e\[[0-?]*[ -/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)?|\e.}m
        UNPRINTABLE = /[[:cntrl:]\p{Cf}\p{Zl}\p{Zp}\s]+/

        # @param text [Object] any text, including an escape sequence or a newline
        # @return [String] one line with no control character in it
        def self.plain(text) = text.to_s.scrub.gsub(ESCAPES, "").gsub(UNPRINTABLE, " ").strip

        # @param row [::Lain::Review::Queue::Row]
        # @param pull [Forge::Gh::ReviewRequest, nil] what GitHub said of a pull request row
        def initialize(row, pull)
          @row = row
          @pull = pull
        end

        # @return [String] `<id>\t<reason>\t<summary>`
        def line = [id, reason, summary].join("\t")

        # @return [Hash] the row as 1 JSON object's members
        def to_h
          { id:, rank: @row.rank.to_s, reason:, summary:, head_sha: @row.head_sha, request: @row.request.to_h }
        end

        # @return [Array<String>] the lines `show` prints
        def detail
          ["id: #{id}", "reason: #{reason}", "range: #{range}", *pull_detail]
        end

        private

        def id = self.class.plain(@row.id)

        def reason = self.class.plain(@row.reason)

        def summary
          fields = @row.request.to_h
          self.class.plain(fields["kind"] == "pr" ? @pull&.title || fields["url"] : span)
        end

        def span
          fields = @row.request.to_h
          case fields["kind"]
          when "range" then "#{fields["base"][0, 8]}..#{fields["head"][0, 8]}"
          when "branch" then [fields["branch"], fields["base"]].compact.join(" against ")
          else fields["repo_root"]
          end
        end

        def range
          fields = @row.request.to_h
          case fields["kind"]
          when "range" then "#{fields["base"]}..#{fields["head"]}"
          when "pr" then self.class.plain([fields["url"], *("since #{fields["since"]}" if fields["since"])].join(" "))
          else span
          end
        end

        def pull_detail
          return [] unless @pull

          ["title: #{self.class.plain(@pull.title)}", "author: #{self.class.plain(@pull.author)}",
           "requested: #{@pull.requested_at&.utc&.iso8601 || "unknown"}"]
        end
      end
      private_constant :Entry

      # Keeps each pull request the reads returned, so a row's title, author and
      # request time are known without a second GraphQL call.
      class Pulls
        # @param reads [Forge::Gh::Reads]
        def initialize(reads)
          @reads = reads
          @seen = {}
        end

        # @param query [String]
        # @return [Array<Forge::Gh::ReviewRequest>]
        def review_requests(query:) = remember(@reads.review_requests(query:))

        # @param query [String]
        # @param notes [#puts]
        # @return [Array<Forge::Gh::ReviewRequest>]
        def matches(query:, notes: Sink::Null.new) = remember(@reads.matches(query:, notes:))

        # @param row_id [String]
        # @return [Forge::Gh::ReviewRequest, nil]
        def for(row_id) = @seen[row_id]

        private

        def remember(pulls)
          pulls.each { |pull| @seen[::Lain::Review::Queue::PullRequests.id_for(pull)] = pull }
        end
      end
      private_constant :Pulls

      # Where a source's note goes: stderr, so a row stream stays rows.
      Notes = Struct.new(:cli) do
        def puts(text) = cli.say_error(Entry.plain(text))
      end
      private_constant :Notes

      def self.exit_on_failure? = true

      class_option :json, type: :boolean, default: false, desc: "One JSON object per row"

      desc "here", "Plan runs, then the local changes of this checkout"
      def here = list { [plan_runs, local_changes] }

      desc "local", "Unmerged branches, a dirty tree and recent commits of this checkout"
      def local = list { [local_changes] }

      desc "prs", "Pull requests that want my review"
      def prs = list { [pull_requests] }

      desc "show ID", "Why a row is queued, its range, and for a pull request who asked and when"
      def show(id)
        render(newline: false) do
          sources = id.start_with?("pr:") ? [pull_requests] : [plan_runs, local_changes]
          row = sources.flat_map(&:call).find { |candidate| Entry.plain(candidate.id) == Entry.plain(id) }
          raise ::Thor::Error, "no queue row #{Entry.plain(id)}" unless row

          lines(entry(row).detail)
        end
      end

      no_commands do
        def list
          render(newline: false) do
            sources = yield
            queue = ::Lain::Review::Queue.new(sources:, log: ::Lain::Review::Queue::Log.new(paths: Paths.new))
            lines(queue.map { |row| options[:json] ? JSON.generate(entry(row).to_h) : entry(row).line })
          end
        end
      end

      private

      def lines(texts) = texts.map { |text| "#{text}\n" }.join

      def entry(row) = Entry.new(row, row.request.to_h["kind"] == "pr" ? pulls.for(row.id) : nil)

      def notes = @notes ||= Notes.new(self)

      def checkout = Isolation::Checkout.of(Dir.pwd)

      def plan_runs = ::Lain::Review::Queue::PlanRuns.new(checkout:, notes:)

      def local_changes = ::Lain::Review::Queue::LocalChanges.new(repo_root: Dir.pwd, notes:)

      def pull_requests = pull_source.last

      def pulls = pull_source.first

      def pull_source
        @pull_source ||= begin
          config = Config.github(root: Project::Resolver.default_project.root)
          account = Forge::Gh::Account.for(config, shell_out_factory: Shell::Out.public_method(:new), notes:)
          pulls = Pulls.new(Forge::Gh::Reads.new(cwd: Dir.pwd, account:))
          checkouts = ::Lain::Review::Queue::Checkouts.new(roots: config.roots, notes:)
          [pulls, ::Lain::Review::Queue::PullRequests.new(reads: pulls, config:, checkouts:, notes:)]
        end
      end
    end
  end
end
