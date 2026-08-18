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
      # `Surface.check!` and `spec/support/shared_examples/review_surface.rb`
      # both assert the shape through `Surface.shape_of`, so a keyword here
      # cannot quietly become optional or a `**kwargs` catch-all without
      # failing for every adapter, not only this one.
      #
      # A KEYWORD keeps its real name, because a keyword IS its name at every
      # call site -- so `scope:` and `kind:` cannot be underscore-prefixed and
      # the two methods carrying them keep an inline disable,
      # `Compaction::Boundary#initialize`'s (`compaction/boundary.rb:120`) same
      # tradeoff. A POSITIONAL's name is private to the method, and the three
      # methods below that take only positionals say so plainly rather than
      # disabling a cop that was right. That distinction arrived with a T19
      # review panel: pinning positional names refused `def thread(_anchor)` as
      # "the wrong shape", and five disables on one small class were the smell
      # pointing at it.
      class Null
        # @return [nil]
        def present(_changeset, scope:) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        def annotate(_anchor, _text, kind:) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        def mark(_hunk_key, _state) = nil

        # @return [nil]
        def thread(_anchor) = nil

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
        def settle(_verdict) = nil

        # @return [nil]
        def refuse(_message) = nil
      end
    end
  end
end
