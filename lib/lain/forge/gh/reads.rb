# frozen_string_literal: true

module Lain
  module Forge
    class Gh
      # The read-only gh calls a pull request review makes, run as the configured account.
      #
      # Apart from {Gh} on purpose: Gh is a closed set of landing verbs written in three mirrors,
      # and a read has no landing to fold into. This runs the subprocess and hands it back
      # unjudged; each caller keeps its own reading of a refusal.
      class Reads
        # gh refused the search, or GitHub answered with errors. A {Lain::Error}, so the chat renders
        # it and stays up.
        class Refused < Error; end

        MY_TEAMS = <<~GRAPHQL.tr("\n", " ").squeeze(" ").strip
          organizations(first: 100) { nodes { login
            member: teams(first: 100, role: MEMBER) { nodes { slug } }
            admin: teams(first: 100, role: ADMIN) { nodes { slug } } } }
        GRAPHQL

        def self.search_query(viewer_fields)
          <<~GRAPHQL
            query($q: String!) {
              viewer { login #{viewer_fields} }
              search(query: $q, type: ISSUE, first: 50) {
                issueCount
                nodes {
                  ... on PullRequest {
                    number title url isDraft headRefOid
                    author { login }
                    repository { nameWithOwner }
                    files(first: 100) { totalCount nodes { path } }
                    timelineItems(itemTypes: REVIEW_REQUESTED_EVENT, last: 30) {
                      nodes { ... on ReviewRequestedEvent {
                        createdAt
                        requestedReviewer { ... on User { login } ... on Team { slug organization { login } } }
                      } }
                    }
                    reviewRequests(first: 20) {
                      nodes { asCodeOwner
                        requestedReviewer { __typename ... on User { login }
                          ... on Team { slug organization { login } } } }
                    }
                    latestReviews(first: 20) { nodes { author { login } commit { oid } } }
                  }
                }
              }
            }
          GRAPHQL
        end
        private_class_method :search_query

        REVIEW_REQUESTS = search_query(MY_TEAMS)
        # A match never reads my teams, so its query does not fetch them.
        MATCHES = search_query("")

        # The `--json` fields the review reads, and nothing else.
        PR_FIELDS = %w[baseRefName baseRefOid headRefOid].freeze

        # @param cwd [String] where gh runs, which is how it resolves WHICH repository it asks about
        # @param account [Account, Account::None] whose token every gh child runs with
        # @param timeout [Numeric] seconds one gh call may take
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(cwd:, account:, timeout: DEFAULT_TIMEOUT, shell_out_factory: Shell::Out.public_method(:new))
          @cwd = cwd.to_s
          @account = account
          @timeout = timeout
          @shell_out_factory = shell_out_factory
          freeze
        end

        # @param ref [String] a number, URL or branch, as the human wrote it
        # @return [#stdout, #stderr, #exitstatus] the finished `gh pr view`
        # @raise [Account::Refused] when gh has no token for the configured account
        # @raise [Shell::Out::Timeout, Errno::ENOENT]
        def pr_refs(ref:) = run("pr", "view", ref, "--json", PR_FIELDS.join(","))

        # @param ref [String] as for {#pr_refs}
        # @return [#stdout, #stderr, #exitstatus] the finished `gh pr diff`
        def pr_diff(ref:) = run("pr", "diff", ref)

        # Every open pull request a search names that asks for my review, in 1 GraphQL call.
        #
        # The query reads a fixed window, silently: my first 100 organizations, my first 100 teams
        # per role (member, admin) in each, a PR's first 100 changed files (flagged by
        # paths_truncated on each request), and its last 30 review-request events.
        #
        # @param query [String] a GitHub issue search, e.g. `is:open is:pr review-requested:@me`
        # @return [Array<ReviewRequest>] drafts dropped
        # @raise [Refused] with gh's own message when gh exits non-zero or GraphQL answers errors
        # @raise [Account::Refused] when gh has no token for the configured account
        def review_requests(query:)
          search(REVIEW_REQUESTS, query) { |node, viewer, teams| ReviewRequest.from_node(node, viewer:, teams:) }
        end

        # Every open pull request a search names, asked of me or not, in the same 1 GraphQL call and
        # window as {#review_requests}.
        #
        # @param query [String] a GitHub issue search
        # @param notes [#puts] told when the search matched more pull requests than the 50 it returns
        # @return [Array<ReviewRequest>] each with `via: :match`; drafts dropped
        # @raise [Refused] with gh's own message when gh exits non-zero or GraphQL answers errors
        # @raise [Account::Refused] when gh has no token for the configured account
        def matches(query:, notes: Sink::Null.new)
          search(MATCHES, query, notes:) { |node, viewer, _teams| ReviewRequest.from_match(node, viewer:) }
        end

        # The token stays out of every inspect: the account's own inspect names no token.
        def inspect = "#<#{self.class.name} #{@account.inspect}>"

        private

        def search(graphql, query, notes: Sink::Null.new, &block)
          shell = run("api", "graphql", "-f", "query=#{graphql}", "-f", "q=#{query}")
          raise Refused, shell.stderr.to_s.strip unless shell.exitstatus.zero?

          parse(shell.stdout, notes, &block)
        end

        def parse(body, notes)
          answer = JSON.parse(body)
          errors = answer["errors"]
          raise Refused, errors.map { |error| error["message"] }.join("; ") if errors

          viewer = answer.dig("data", "viewer")
          teams = my_teams(viewer)
          nodes = answer.dig("data", "search", "nodes")
          note_unshown(answer.dig("data", "search", "issueCount").to_i, nodes.size, notes)
          nodes.filter_map { |node| yield(node, viewer["login"], teams) }
        end

        def note_unshown(total, shown, notes)
          return unless total > shown

          notes.puts("search matched #{total} pull requests and showed #{shown}; #{total - shown} not shown")
        end

        def my_teams(viewer)
          viewer.dig("organizations", "nodes").to_a.flat_map do |org|
            (org.dig("member", "nodes").to_a + org.dig("admin", "nodes").to_a).map do |team|
              "#{org["login"]}/#{team["slug"]}"
            end
          end.to_set
        end

        def run(*argv)
          shell = @shell_out_factory.call("gh", *argv, cwd: @cwd, timeout: @timeout,
                                                       environment: @account.environment)
          shell.run_command
          shell
        end
      end
    end
  end
end
