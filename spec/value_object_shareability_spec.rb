# frozen_string_literal: true

# CLAUDE.md pins `Ractor.shareable?` on every value object, but it was asked 267 times
# one object at a time -- individually correct, collectively blind. Nothing asked it of
# the WHOLE set, so a new Data subclass holding a mutable default shipped green.
module ValueObjectSweepSupport
  module_function

  # Deeply frozen stand-ins, tried in order until a constructor accepts one. A validator
  # that refuses all of them puts its class in UNREACHED rather than passing vacuously.
  DUMMIES = ["x", 1, :s, [].freeze, {}.freeze, true, nil, 1.0].freeze

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

  # nil means "no dummy satisfied this constructor".
  def build(klass)
    DUMMIES.each do |dummy|
      return klass.new(**klass.members.to_h { |member| [member, dummy] })
    rescue StandardError
      next
    end
    nil
  end

  BUILT, UNREACHED = value_classes.sort_by(&:name)
                                  .map { |klass| [klass, build(klass)] }
                                  .partition { |_, instance| instance }
                                  .then { |built, unreached| [built, unreached.map(&:first)] }
end

RSpec.describe "every Lain value object" do
  built = ValueObjectSweepSupport::BUILT
  unreached = ValueObjectSweepSupport::UNREACHED

  it "is a Data subclass the sweep can actually reach" do
    expect(built.size + unreached.size).to be > 250
    # A constructor guarded tightly enough to refuse every dummy is not a defect; a
    # sweep that quietly covers half the suite is. Fail if reach drops off a cliff.
    expect(built.size.fdiv(built.size + unreached.size)).to be > 0.75
  end

  it "holds no reachable mutable state when built from deeply frozen members" do
    offenders = built.reject { |_, instance| Ractor.shareable?(instance) }
                     .map { |klass, instance| "#{klass.name}: #{ShareabilityMatcherSupport.offender(instance)}" }

    expect(offenders).to be_empty
  end

  # Named, not skipped: this is the sweep's blind spot, and it is reviewable.
  it "names the constructors no generic dummy satisfies" do
    expect(unreached.map(&:name)).to all(start_with("Lain::"))
  end
end
