# frozen_string_literal: true

# CLAUDE.md pins `Ractor.shareable?` on every value object, but it was asked 267 times
# one object at a time -- individually correct, collectively blind. Nothing asked it of
# the WHOLE set, so a new Data subclass holding a mutable default would ship green.
RSpec.describe "every Lain value object" do
  built, unreached = GenericBuild.partition(GenericBuild.value_classes)

  it "is reachable often enough for the sweep to mean something" do
    expect(built.size + unreached.size).to be > 250
    expect(built.size.fdiv(built.size + unreached.size)).to be > 0.75
  end

  it "holds no reachable mutable state when built from deeply frozen members" do
    offenders = built.reject { |_, instance| Ractor.shareable?(instance) }
                     .map { |klass, instance| "#{klass}: #{ShareabilityMatcherSupport.offender(instance)}" }

    expect(offenders).to be_empty
  end

  # Named, not skipped: this is the sweep's blind spot, and it is reviewable.
  it "names the constructors no generic dummy satisfies" do
    expect(unreached.map(&:name)).to all(start_with("Lain::"))
  end
end
