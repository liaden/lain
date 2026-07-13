# frozen_string_literal: true

module Lain
  # A capability set: the exact tools some agent or subagent is allowed to use.
  #
  # This is not a registry guarded by a permission layer. There is no policy to
  # audit -- "what can this subagent do" is answered by reading the one line that
  # constructed its Toolset. Possession *is* authorization. Attenuation
  # (`#only`, `#except`) is therefore the security primitive: it returns a new,
  # smaller, frozen Toolset, and because a Toolset can never grow or mutate, a
  # capability once dropped cannot be regained by the holder.
  #
  # `#to_schema` emits the provider-neutral tool array sorted by name and
  # normalized through {Lain::Canonical}. Sorting plus canonical serialization is
  # what keeps the schema byte-identical across constructions: a plain Hash
  # iterating in insertion order would silently break Anthropic's prompt cache,
  # with no error anywhere.
  class Toolset
    class UnknownTool < Error; end
    class DuplicateTool < Error; end

    include Enumerable

    # @param tools [Array<Lain::Tool>] the capabilities this set grants
    def initialize(tools = [])
      by_name = {}
      tools.each do |tool|
        key = tool.name.to_s
        raise DuplicateTool, "two tools are named #{key.inspect}" if by_name.key?(key)

        by_name[key] = tool
      end
      @by_name = by_name.freeze
      freeze
    end

    # Iterates tools in name order, so any Enumerable-derived operation (map,
    # to_a, sort) is itself deterministic rather than construction-order
    # dependent -- the same reason {#to_schema} sorts.
    def each(&block)
      return enum_for(:each) unless block

      names.each { |name| block.call(@by_name.fetch(name)) }
    end

    # Tool names, sorted. The canonical order everything else here derives from.
    def names
      @by_name.keys.sort
    end

    def include?(name)
      @by_name.key?(name.to_s)
    end

    # The tool by name, raising rather than returning nil: asking a capability
    # set for a capability it does not hold is a programming error, not a
    # value to branch on.
    def fetch(name)
      @by_name.fetch(name.to_s) { raise UnknownTool, "no tool named #{name.to_s.inspect}" }
    end
    alias [] fetch

    def size
      @by_name.size
    end

    def empty?
      @by_name.empty?
    end

    # Attenuate DOWN to exactly `names`. Requesting a tool this set does not hold
    # raises, so the constructing line cannot claim a capability that is not
    # really there -- the "read one line to know what it can do" guarantee stays
    # honest. Returns a new frozen Toolset; the receiver is untouched.
    def only(*names)
      keys = normalize(names)
      missing = keys.reject { |key| @by_name.key?(key) }
      raise UnknownTool, "cannot restrict to absent tools: #{missing.join(", ")}" unless missing.empty?

      self.class.new(keys.map { |key| @by_name.fetch(key) })
    end

    # Attenuate down by REMOVING `names`. Naming a tool not present raises for the
    # same reason {#only} does: an `except` list that references a phantom tool is
    # almost always a typo hiding a capability you meant to drop but did not.
    def except(*names)
      keys = normalize(names)
      missing = keys.reject { |key| @by_name.key?(key) }
      raise UnknownTool, "cannot exclude absent tools: #{missing.join(", ")}" unless missing.empty?

      self.class.new(@by_name.except(*keys).values)
    end

    # The provider-neutral tool array: each tool's schema, sorted by name, run
    # through {Lain::Canonical} so the bytes are stable across constructions.
    # `Canonical.dump(toolset.to_schema)` is therefore identical for two
    # Toolsets holding the same tools regardless of the order they were built in
    # -- which is precisely the invariant prompt caching depends on.
    def to_schema
      Canonical.normalize(map(&:to_schema))
    end

    def to_s
      "#<Lain::Toolset #{names.join(", ")}>"
    end
    alias inspect to_s

    private

    def normalize(names)
      names.flatten.map(&:to_s)
    end
  end
end
