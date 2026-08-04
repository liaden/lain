# frozen_string_literal: true

module Lain
  module Review
    module Surface
      # The `/dev/null` of review surfaces. Same duck as any real one --
      # {Surface::Text}, {Surface::Neovim} -- but sends every message
      # nowhere. Every review-model spec runs against this so none of them
      # spawns nvim, exactly the role {Sink::Null} plays for tool output.
      #
      # Every method's parameter LIST matters, not just its behavior:
      # `spec/support/shared_examples/review_surface.rb` asserts the exact
      # shape (positional vs. required keyword) against `Method#parameters`,
      # so a keyword here cannot quietly become optional or a `**kwargs`
      # catch-all without failing that check for every adapter, not only
      # this one. That is also why every argument keeps its real, documented
      # name instead of an underscore-prefixed placeholder Rubocop would
      # otherwise suggest -- renaming would change what `Method#parameters`
      # reports and break that very check. `Compaction::Boundary#initialize`
      # (`compaction/boundary.rb:120`) is the same tradeoff already made
      # once: an inline disable, not a name that lies about the port.
      class Null
        # @return [nil]
        def present(changeset, scope:) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        def annotate(anchor, text, kind:) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        def mark(hunk_key, state) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        def thread(anchor) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        #
        # OPEN TENSION, recorded for T13 rather than resolved here: this
        # card's own AC requires every message to return `nil`, but
        # `#verdict` (like `#thread`) is a QUERY, not a command, and
        # {Sink::Null#write} deliberately does NOT return `nil` -- it
        # returns the byte count `IO#write` would, precisely so no caller
        # ever has to `nil`-check it. The same argument applies here: a
        # caller of a real surface's `#verdict` needs an actual answer, and
        # `nil` is indistinguishable from "no verdict yet" and "this surface
        # cannot tell you." Left as `nil` because deciding the query's real
        # shape (a verdict value? a null verdict object?) is T13's call, as
        # the object that actually consumes one -- not a decision to
        # preempt from the Null adapter alone.
        def verdict = nil

        # @return [nil]
        def refuse(message) = nil # rubocop:disable Lint/UnusedMethodArgument
      end
    end
  end
end
