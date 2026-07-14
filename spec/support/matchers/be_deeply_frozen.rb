# frozen_string_literal: true

# Shared by be_deeply_frozen and be_ractor_shareable: when Ractor.shareable?
# says no, find the node that MAKES it no and name its path -- the actionable
# diagnosis is `@blocks[1]["text"] (String, unfrozen)`, never a shrug at the
# top-level object. (be_ractor_shareable.rb references this constant only at
# match time, inside failure_message blocks, so the support glob's load order
# does not bind the two files.)
module ShareabilityMatcherSupport
  module_function

  # Depth-first: a shareable subtree cannot contain an offender, so prune it;
  # descend into everything else and prefer the deepest culprit (the leaf is
  # what the fix will touch). When none of a node's children are at fault, the
  # node itself is (an unfrozen wrapper of frozen parts, or an inherently
  # unshareable value like a Proc). Cycles are cut by an identity-keyed seen
  # set -- a revisited node was already judged on its first path.
  def offender(root)
    find(root, "", {}.compare_by_identity) ||
      raise(ArgumentError, "no offender: #{root.inspect} is Ractor-shareable")
  end

  def find(node, path, seen)
    return nil if Ractor.shareable?(node) || seen.key?(node)

    seen[node] = true
    deepest = children_of(node, path).lazy.filter_map { |segment, child| find(child, segment, seen) }.first
    deepest || label(node, path)
  end

  def children_of(node, path)
    case node
    when Array then node.each_with_index.map { |child, index| ["#{path}[#{index}]", child] }
    when Hash then hash_children(node, path)
    # Struct and Data members are not instance_variables in CRuby; walk #to_h.
    when Struct, Data then node.to_h.map { |name, value| [attr_segment(path, name), value] }
    else ivar_children(node, path)
    end
  end

  def hash_children(node, path)
    node.flat_map do |key, value|
      [["#{path}.key(#{key.inspect})", key], ["#{path}[#{key.inspect}]", value]]
    end
  end

  def ivar_children(node, path)
    node.instance_variables.map { |name| [attr_segment(path, name), node.instance_variable_get(name)] }
  end

  def attr_segment(path, name)
    path.empty? ? name.to_s : "#{path}.#{name}"
  end

  def label(node, path)
    location = path.empty? ? "the object itself" : path
    state = node.frozen? ? "frozen but not Ractor-shareable" : "unfrozen"
    "#{location} (#{node.class}, #{state})"
  end
end

# The value-object check CLAUDE.md asks for, as one assertion instead of the
# two-line pair (`expect(x).to be_frozen` then
# `expect(Ractor.shareable?(x)).to be(true)`) repeated at every value-object
# spec. `frozen?` alone would pass for a shallow freeze that leaves a mutable
# ivar reachable; `Ractor.shareable?` is the mechanical check that NOTHING
# reachable is mutable, so both must hold.
RSpec::Matchers.define :be_deeply_frozen do
  match do |actual|
    @top_level_frozen = actual.frozen?
    @top_level_frozen && Ractor.shareable?(actual)
  end

  failure_message do |actual|
    if @top_level_frozen
      "expected #{actual.inspect} to be deeply frozen, but Ractor.shareable? is false -- " \
        "first offender: #{ShareabilityMatcherSupport.offender(actual)}"
    else
      "expected #{actual.inspect} to be frozen, but #frozen? is false"
    end
  end

  failure_message_when_negated do |actual|
    "expected #{actual.inspect} not to be deeply frozen, but it is both #frozen? and Ractor.shareable?"
  end
end
