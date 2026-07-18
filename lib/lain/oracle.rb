# frozen_string_literal: true

# Children reference the Oracle module's error classes and the Definition value
# object, so definition.rb loads first; the tiers depend on it.
require_relative "oracle/definition"
require_relative "oracle/heuristic"
require_relative "oracle/model"
