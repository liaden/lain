# frozen_string_literal: true

module Lain
  class Toolset
    # Strategy: how a Toolset's tools surface in a Request. {Upfront} renders
    # the full schema array, {Deferred} a searchable catalog. A further arm is
    # a third subclass, never an edit here or in {Lain::Toolset}. The base
    # class names the one message an arm must answer and carries no behavior.
    class Disclosure
      # @param _toolset [Lain::Toolset] the capability set to render
      # @return the provider-neutral tool schema for this arm's disclosure
      def render(_toolset)
        raise Error, "#{self.class} must define #render"
      end
    end
  end
end

# Subclasses reopen Toolset::Disclosure, so they load after the class body above.
require_relative "disclosure/upfront"
require_relative "disclosure/deferred"
