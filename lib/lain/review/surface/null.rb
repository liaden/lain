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
      # cannot quietly become optional or a `**kwargs` catch-all.
      #
      # A KEYWORD keeps its real name, because a keyword IS its name at every
      # call site -- so `scope:` and `kind:` cannot be underscore-prefixed and the
      # two methods carrying them keep an inline disable. A POSITIONAL's name is
      # private to the method, so the three methods below that take only
      # positionals say so plainly rather than disabling a cop that was right.
      # That distinction arrived with a review panel: pinning positional names
      # refused `def thread(_anchor)` as "the wrong shape".
      class Null
        # @return [nil]
        def present(_changeset, scope:) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        def focus = nil

        # @return [nil]
        def annotate(_anchor, _text, kind:) = nil # rubocop:disable Lint/UnusedMethodArgument

        # @return [nil]
        def mark(_hunk_key, _state) = nil

        # @return [nil]
        def thread(_anchor) = nil

        # @return [nil]
        #
        # OPEN TENSION, recorded rather than resolved: the AC requires every
        # message to return `nil`, but `#verdict` (like `#thread`) is a QUERY,
        # and {Sink::Null#write} deliberately does NOT return `nil` -- it returns
        # the byte count, precisely so no caller has to nil-check it. The same
        # argument applies here: `nil` is indistinguishable from "no verdict yet"
        # and "this surface cannot tell you". Left as `nil` because deciding the
        # query's real shape belongs to the object that consumes one.
        def verdict = nil

        # @return [nil]
        def settle(_verdict) = nil

        # @return [nil]
        def refuse(_message) = nil
      end
    end
  end
end
