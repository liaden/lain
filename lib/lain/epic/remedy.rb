# frozen_string_literal: true

module Lain
  module Epic
    # The command lines an epic refusal or notice tells the operator to run. The
    # slug is a required argument of every spelling, so a remedy that names no
    # epic cannot be written; a caller that does not know the slug passes the
    # placeholders ISSUE_ID and SLUG (and ADDRESS for a
    # changeset digest), the only three an operator is ever shown.
    module Remedy
      module_function

      # @param issue [String]
      # @param slug [String]
      # @param resume [Boolean]
      # @return [String]
      def land(issue, slug, resume: false)
        ["lain epic land #{issue} #{slug}", ("--resume" if resume)].compact.join(" ")
      end

      # @param stage [String]
      # @param slug [String]
      # @param issue [String, nil]
      # @param digest [String, nil]
      # @return [String]
      def submit(stage, slug, issue: nil, digest: nil)
        ["lain epic submit #{stage} #{slug}", issue && "--issue #{issue}", digest && "--digest #{digest}"]
          .compact.join(" ")
      end

      # @param slug [String]
      # @param local [Boolean]
      # @return [String]
      def finish(slug, local: false) = ["lain epic finish #{slug}", ("--local" if local)].compact.join(" ")

      # @param slug [String]
      # @return [String]
      def queue(slug) = "lain epic queue #{slug}"

      # @param slug [String]
      # @return [String]
      def chat(slug) = "lain chat --epic #{slug}"
    end
  end
end
