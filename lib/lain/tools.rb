# frozen_string_literal: true

module Lain
  # Concrete tool implementations. {Lain::Tool} is the abstract shape; each
  # class here is a capability an Agent's {Lain::Toolset} can be handed. Tools
  # are capabilities, not permissions -- the tier each one sits at, and where
  # the security boundary really is, is CLAUDE.md's "secret boundary" rule.
  module Tools
  end
end
