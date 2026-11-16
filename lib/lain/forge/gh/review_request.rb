# frozen_string_literal: true

require "time"

module Lain
  module Forge
    class Gh
      ReviewRequest = Data.define(:repo, :number, :title, :url, :head_sha, :author, :paths, :paths_truncated,
                                  :requested_at, :via, :team, :my_last_review)

      # One open pull request asking for my review, read from a single GraphQL search node.
      #
      # `via` says how the ask reached me: named directly, through a team of mine (`team` is its
      # organization-qualified slug, "org/slug"), or as a code owner. `my_last_review` is the commit
      # of my latest review, or nil when I have none or GitHub no longer knows its commit.
      # `paths_truncated` is true when the PR changes more files than `paths` holds.
      #
      # Built from a search node by {.from_node}.
      class ReviewRequest
        # @param node [Hash] one `PullRequest` node of the review-requests query
        # @param viewer [String, nil] the login the query ran as
        # @param teams [#include?] the organization-qualified slugs ("org/slug") of my teams
        # @return [ReviewRequest, nil] nil for a draft, or a node that names neither me nor a team of mine
        def self.from_node(node, viewer:, teams:)
          return nil if node["isDraft"]

          ask = ask_of(node, viewer, teams) or return nil
          build(node, viewer, ask)
        end

        # @api private
        def self.ask_of(node, viewer, teams)
          asks = node.dig("reviewRequests", "nodes").to_a
          asks.find { |ask| viewer && ask.dig("requestedReviewer", "login") == viewer } ||
            asks.find { |ask| teams.include?(qualified(ask["requestedReviewer"])) }
        end

        # @api private
        def self.qualified(reviewer)
          slug = reviewer["slug"] or return nil
          "#{reviewer.dig("organization", "login")}/#{slug}"
        end

        # @api private
        def self.build(node, viewer, ask)
          reviewer = ask["requestedReviewer"]
          team = qualified(reviewer)
          new(**identity(node), paths: paths(node), paths_truncated: truncated?(node),
                                requested_at: requested_at(node, reviewer), via: via(ask, team),
                                team: team&.-@, my_last_review: my_last_review(node, viewer))
        end

        # @api private
        def self.identity(node)
          { repo: node.dig("repository", "nameWithOwner"), number: node["number"], title: node["title"],
            url: node["url"], head_sha: node["headRefOid"], author: node.dig("author", "login") }
            .transform_values { |value| value.is_a?(String) ? -value : value }
        end

        # @api private
        def self.paths(node) = node.dig("files", "nodes").to_a.map { |file| -file["path"] }.freeze

        # @api private
        def self.truncated?(node) = node.dig("files", "totalCount").to_i > node.dig("files", "nodes").to_a.size

        # @api private
        def self.via(ask, team)
          return :code_owner if ask["asCodeOwner"]

          team ? :team : :direct
        end

        # @api private
        def self.requested_at(node, reviewer)
          events = node.dig("timelineItems", "nodes").to_a.select do |event|
            asked = event["requestedReviewer"]
            asked && (asked["login"] ? asked["login"] == reviewer["login"] : qualified(asked) == qualified(reviewer))
          end
          stamps = events.map { |event| Time.iso8601(event["createdAt"]).freeze }
          stamps.max
        end

        # @api private
        def self.my_last_review(node, viewer)
          mine = node.dig("latestReviews", "nodes").to_a.find { |review| review.dig("author", "login") == viewer }
          oid = mine&.dig("commit", "oid")
          oid&.-@
        end

        private_class_method :ask_of, :qualified, :truncated?, :build, :identity, :paths, :via, :requested_at,
                             :my_last_review
      end
    end
  end
end
