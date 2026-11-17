# frozen_string_literal: true

module Lain
  module Review
    class Queue
      # Pull requests worth a look: the ones that ask for my review, and, when
      # matches are on, the ones a configured keyword or path picks out of the
      # configured organizations.
      class PullRequests
        REQUESTS = "is:open is:pr review-requested:@me archived:false"
        MATCHES = "is:open is:pr archived:false -author:@me"
        SCOPES = { mine: %i[direct], all: %i[direct team code_owner] }.freeze
        private_constant :MATCHES, :SCOPES

        # @param pull [Forge::Gh::ReviewRequest]
        # @param orgs [Array<String>] the organizations to keep; empty keeps every one
        def self.in_orgs?(pull, orgs) = orgs.empty? || orgs.include?(pull.repo.split("/").first)

        # @param pull [Forge::Gh::ReviewRequest]
        # @return [String] the id of the row that stands for the pull request
        def self.id_for(pull) = "pr:#{pull.repo}##{pull.number}"

        # @param reads [Forge::Gh::Reads]
        # @param config [Config::Github] orgs narrow requests and scope matches; the rest drive matches
        # @param checkouts [Checkouts] finds each pull request's local clone
        # @param scope [Symbol] `:mine` lists direct requests only, `:all` adds team and code-owner ones
        # @param matches [Boolean] whether keyword and path searches run
        # @param notes [#puts] where a refused row is named
        # @param shell_out_factory [#call] builds the subprocess runner
        # @param clock [#call] the time the since_days window counts back from
        def initialize(reads:, config:, checkouts:, scope: :mine, matches: false, notes: Sink::Null.new,
                       shell_out_factory: Shell::Out.public_method(:new), clock: -> { Time.now })
          @reads = reads
          @config = config
          @checkouts = checkouts
          @scope = SCOPES.fetch(scope)
          @matches = matches
          @notes = notes
          @shell_out_factory = shell_out_factory
          @clock = clock
        end

        # @return [Array<Row>] requests first, then matches
        # @raise [Forge::Gh::Reads::Refused, Forge::Gh::Account::Refused]
        def call
          requested = @reads.review_requests(query: REQUESTS)
          shown = requested.select { |pull| in_orgs?(pull) && @scope.include?(pull.via) }
          rows = shown.filter_map { |pull| request_row(pull) }.each_with_index
                      .sort_by { |row, at| [Queue::RANKS.index(row.rank), at] }.map(&:first)
          rows + (@matches ? match_rows(requested) : [])
        end

        private

        def in_orgs?(pull) = self.class.in_orgs?(pull, @config.orgs)

        def request_row(pull)
          since, count = rereview(pull)
          if since
            return row(pull, :re_review, "direct, re-review: #{count} #{count == 1 ? "commit" : "commits"}",
                       since:)
          end

          row(pull, pull.via == :direct ? :direct : :team, via_reason(pull))
        end

        def via_reason(pull)
          { direct: "direct", team: "team: #{pull.team}", code_owner: "code owner" }.fetch(pull.via)
        end

        # A review of mine on a commit a force-push removed has no range to show, so the whole PR is the answer.
        def rereview(pull)
          clone = pull.via == :direct && pull.my_last_review && @checkouts.for(pull.repo)
          return unless clone

          git = Isolation::Checkout.of(clone, shell_out_factory: @shell_out_factory)
          return unless ancestor?(git, pull)

          count = git.out("rev-list", "--count", "#{pull.my_last_review}..#{pull.head_sha}").to_i
          [pull.my_last_review, count] if count.positive?
        end

        def ancestor?(git, pull)
          Shell::Out.ok?(git.run("merge-base", "--is-ancestor", pull.my_last_review, pull.head_sha))
        end

        def row(pull, rank, reason, since: nil)
          fields = { "kind" => "pr", "url" => pull.url, **(since ? { "since" => since } : {}) }
          request = Request.load(fields, checkouts: @checkouts, shell_out_factory: @shell_out_factory)
          reason += ", no local checkout" unless request.repo_root
          Row.new(id: self.class.id_for(pull), rank:, reason:, request:, head_sha: pull.head_sha)
        rescue Request::Refused => e
          @notes.puts("skipped #{self.class.id_for(pull)}: #{e.message}")
          nil
        end

        # Deduplicated against every request, not only the ones the scope shows, so a hidden team
        # request never comes back as a match.
        def match_rows(requested)
          return note_no_orgs if @config.orgs.empty?

          seen = requested.to_set { |pull| [pull.repo, pull.number] }
          found = path_matches + keyword_matches
          fresh = found.select { |pull, _| seen.add?([pull.repo, pull.number]) }
          fresh.filter_map { |pull, why| row(pull, :path, why) }
        end

        def note_no_orgs
          @notes.puts("matches are on but `github` names no orgs, so no keyword or path search ran")
          []
        end

        def path_matches
          return [] if @config.paths.empty?

          @config.orgs.flat_map { |org| @reads.matches(query: search(org), notes: @notes) }.filter_map do |pull|
            path = pull.paths.find { |name| @config.paths.any? { |pattern| pattern.match?(name) } }
            [pull, path_reason(path)] if path || pull.paths_truncated
          end
        end

        # GitHub returns the first 100 changed files, so a miss on a longer PR proves nothing.
        def path_reason(path)
          return "path: #{path}" if path

          "path: #{@config.paths.map(&:inspect).join(" or ")}?, file list truncated"
        end

        def keyword_matches
          @config.orgs.product(@config.keywords).flat_map do |org, word|
            query = "#{search(org)} #{phrase(word)} in:title,body"
            @reads.matches(query:, notes: @notes).map { |pull| [pull, "keyword: #{word}"] }
          end
        end

        # Newest first, so the search cap drops the oldest pull requests.
        def search(org) = "#{MATCHES} org:#{org} updated:>=#{since.strftime("%Y-%m-%d")} sort:updated-desc"

        def phrase(word) = word.match?(/\s/) ? %("#{word.delete('"')}") : word

        def since = @clock.call - (@config.since_days * 86_400)
      end
    end
  end
end
