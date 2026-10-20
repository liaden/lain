# frozen_string_literal: true

module Lain
  # The one rule every model-keyed table resolves a name by: the exact key,
  # else the longest key the name contains. A family fix to a table's rows then
  # lands in that table alone.
  class ModelTable
    # A name two equal-length keys both match, which Hash order must not decide.
    class Ambiguous < Lain::Error; end

    # @param keys [Enumerable<String>] family tokens and exact model ids
    def initialize(keys)
      @keys = keys.map { |key| -key.to_s }.freeze
      freeze
    end

    # @param name [String]
    # @return [String, nil] the matching key; nil when none matches
    # @raise [Ambiguous] when 2 keys of the longest length both match
    def key_for(name)
      return name if @keys.include?(name)

      contained = @keys.select { |key| name.include?(key) }
      longest = contained.max_by(&:length)
      tied = contained.select { |key| key.length == longest.length } if longest
      raise Ambiguous, "#{name.inspect} matches both #{tied.join(" and ")}" if tied && tied.length > 1

      longest
    end
  end
end
