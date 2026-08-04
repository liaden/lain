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
    include Algebra::Attenuation
    include Inspectable

    # The schema and its digest are built HERE rather than memoized on demand:
    # the object freezes itself on the next line, so a lazy `@digest ||=` is a
    # guaranteed FrozenError.
    #
    # @param tools [Array<Lain::Tool>] the capabilities this set grants
    def initialize(tools = [])
      @by_name = indexed(tools)
      @schema = Canonical.normalize(map(&:to_schema))
      @digest = Canonical.digest(@schema)
      freeze
    end

    # The content address of {#to_schema} -- the exact bytes prompt caching keys
    # on, and the whole of this set's identity as a value.
    attr_reader :digest

    # Iterates tools in name order, so any Enumerable-derived operation (map,
    # to_a, sort) is itself deterministic rather than construction-order
    # dependent -- the same reason {#to_schema} sorts.
    def each(&block)
      return enum_for(:each) unless block

      names.each { |name| yield(@by_name.fetch(name)) }
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

    # The security reading of the pair above, said where the registry can hold
    # it to laws: attenuation goes DOWN and only down. `#only` names what
    # survives, `#except` names what goes, `except(x) == only(names - x)`, and
    # chaining either can never widen the result -- a capability once dropped
    # cannot be regained by the holder.
    #
    # There is deliberately no join. Two Toolsets have no least upper bound in
    # this algebra, and none is offered: union exists only at CONSTRUCTION,
    # below the trust boundary, where {Tools::Subagent#child_union} assembles a
    # child's set out of tools the parent already holds.
    #
    # What the boundary covers, precisely: the MODEL-FACING surface -- the
    # rendered schema, and the `#include?`/`#fetch` pair
    # {Effect::Handler::Live} authorizes and dispatches with. No message on
    # THOSE adds a dropped capability back, which is what makes "possession is
    # authorization" survive contact with a subagent, and the monotonicity law
    # is how it stays checked rather than merely written down here.
    #
    # It is not a claim about the Ruby object graph, and must not be read as
    # one. The tools an attenuated set still yields are objects with surfaces of
    # their own: `only(:subagent).fetch("subagent").attenuates_from` hands back
    # the whole un-attenuated union (`tools/subagent.rb:90`). Reaching a tool's
    # own constructor arguments in-process is not the threat this boundary is
    # against; a spec pins both halves so neither reading drifts.
    #
    # The partiality is a law too: `only` outside the current set raises, and
    # `except` twice over the same names raises, because the second call is
    # naming a tool that is already gone.
    attenuation on: :only, dual: :except

    # The provider-neutral tool array: each tool's schema, sorted by name, run
    # through {Lain::Canonical} so the bytes are stable across constructions.
    # `Canonical.dump(toolset.to_schema)` is therefore identical for two
    # Toolsets holding the same tools regardless of the order they were built in
    # -- which is precisely the invariant prompt caching depends on.
    def to_schema
      @schema
    end

    # Value equality, defined as the canonical schema bytes: two Toolsets are
    # equal iff they present the same tools to the model. This is SCHEMA
    # equality, not behavioral equality -- two tools with identical schemas and
    # completely different `#perform` bodies compare equal, because the schema is
    # the whole of what the model, and the prompt cache, can see.
    #
    # `equal?` is untouched, so the specs pinning that a posture returns the very
    # same object still mean what they meant.
    #
    # Two siblings state the same idea: {Lain::ContentAddressed} (the digest trio
    # seven values include) and {Lain::Capability::DegradedSet}. This one is NOT
    # the module, and diverges from both on one word -- `instance_of?` where they
    # write `is_a?`. Both record the `is_a?` asymmetry as a latent caveat: under
    # subclassing `parent == child` holds while `child == parent` does not, and a
    # class-embedding `hash` then makes that a live ==/hash contract violation.
    # `instance_of?` is symmetric, so there is nothing to caveat. Converging all
    # three on `instance_of?` -- and then folding this class into the module --
    # is owed; until it lands, this comment is what says the three differ on
    # purpose rather than by drift.
    def ==(other)
      other.instance_of?(self.class) && digest == other.digest
    end
    alias eql? ==

    def hash
      [self.class, digest].hash
    end

    # to_s is the human-facing projection; inspect keeps the class-tagged,
    # debug-oriented form -- the DegradedSet convention.
    def to_s
      names.join(", ")
    end

    private

    # Name -> tool, frozen. A repeated name is refused rather than resolved:
    # {#fetch} would otherwise answer with whichever tool happened to be last.
    def indexed(tools)
      tools.each_with_object({}) do |tool, by_name|
        key = tool.name.to_s
        raise DuplicateTool, "two tools are named #{key.inspect}" if by_name.key?(key)

        by_name[key] = tool
      end.freeze
    end

    def normalize(names)
      names.flatten.map(&:to_s)
    end
  end
end

require_relative "toolset/disclosure"
