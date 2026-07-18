# frozen_string_literal: true

module Lain
  class Toolset
    # Strategy: how a Toolset's tools surface in a Request. {Upfront} is the
    # default arm -- today's full schema array, unchanged -- and is the only
    # one that exists yet; a future arm (e.g. a deferred, on-demand
    # disclosure) is a second subclass, never an edit here or in
    # {Lain::Toolset}. The base class names the one message an arm must
    # answer and otherwise carries no behavior of its own.
    class Disclosure
      class NotImplemented < Error; end

      # @param _toolset [Lain::Toolset] the capability set to render
      # @return the provider-neutral tool schema for this arm's disclosure
      def render(_toolset)
        raise NotImplemented, "#{self.class} must define #render"
      end
    end
  end
end

# Subclasses reopen Toolset::Disclosure, so they load after the class body above.
require_relative "disclosure/upfront"
require_relative "disclosure/deferred"
