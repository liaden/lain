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

        REVIEW_REQUESTS = <<~GRAPHQL
          query($q: String!) {
            viewer { login
              organizations(first: 100) { nodes { login
                member: teams(first: 100, role: MEMBER) { nodes { slug } }
                admin: teams(first: 100, role: ADMIN) { nodes { slug } } } } }
            search(query: $q, type: ISSUE, first: 50) {
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
          shell = run("api", "graphql", "-f", "query=#{REVIEW_REQUESTS}", "-f", "q=#{query}")
          raise Refused, shell.stderr.to_s.strip unless shell.exitstatus.zero?

          parse(shell.stdout)
        end

        # The token stays out of every inspect: the account's own inspect names no token.
        def inspect = "#<#{self.class.name} #{@account.inspect}>"

        private

        def parse(body)
          answer = JSON.parse(body)
          errors = answer["errors"]
          raise Refused, errors.map { |error| error["message"] }.join("; ") if errors

          viewer = answer.dig("data", "viewer")
          teams = my_teams(viewer)
          answer.dig("data", "search", "nodes")
                .filter_map { |node| ReviewRequest.from_node(node, viewer: viewer["login"], teams:) }
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
