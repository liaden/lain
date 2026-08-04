# frozen_string_literal: true

# Building one of every Data subclass, for the registry sweeps that ask a property of a
# WHOLE set rather than one class at a time. A constructor guarded tightly enough to
# refuse every dummy is reported, never skipped -- a sweep that quietly covers half its
# registry reads exactly like one that covers all of it.
module GenericBuild
  module_function

  # Deeply frozen, so anything unshareable in the result came from the constructor.
  DUMMIES = ["x", 1, :s, [].freeze, {}.freeze, true, nil, 1.0].freeze

  # @return [Array(Array<Array(Class, Data)>, Array<Class>)] built pairs, and refusals
  def partition(classes)
    built = []
    unreached = []
    classes.each do |klass|
      instance = build(klass)
      instance ? built << [klass, instance] : unreached << klass
    end
    [built, unreached]
  end

  def build(klass)
    DUMMIES.each do |dummy|
      return klass.new(**klass.members.to_h { |member| [member, dummy] })
    rescue StandardError
      next
    end
    nil
  end

  # Every Data subclass reachable under Lain, by constant walk.
  def value_classes(root = Lain, seen = {}.compare_by_identity)
    root.constants(false).each_with_object([]) do |name, found|
      child = resolve(root, name)
      next if child.nil? || seen.key?(child)

      seen[child] = true
      found << child if child.is_a?(Class) && child < Data
      found.concat(value_classes(child, seen))
    end
  end

  def resolve(root, name)
    child = root.const_get(name)
    child if child.is_a?(Module) && child.name&.start_with?("Lain")
  rescue StandardError, LoadError
    nil
  end
end
