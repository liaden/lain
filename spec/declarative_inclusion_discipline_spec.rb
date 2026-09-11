# frozen_string_literal: true

# Mechanical enforcement of Carrier's InclusionValidator override
# (lib/lain/declarative/carrier.rb): "fixes all ~58 sites at once" is only
# true while nothing regrows a bare ActiveModel inclusion validator around a
# non-scalar, so a whole-tree sweep is what keeps the claim honest instead of
# merely true on the day it was measured. It sits at spec/*_discipline_spec.rb
# with its siblings (output_discipline_spec.rb, tool_bounds_discipline_spec.rb)
# for their reason: the subject is every Carrier subclass lib/ ships, not one
# of them, and a gate nobody finds gets duplicated or disabled.
#
# Named classes under `Lain::` only, tool_bounds_discipline_spec.rb's reason:
# an anonymous carrier a spec builds locally (carrier_spec.rb's own fixtures,
# for one) would make the subject set depend on which files a `parallel_tests`
# worker happened to load. Named through `#declarer`, not `#name`: `declare do
# ... end` (Lain::Project, among others) mints an ANONYMOUS carrier class, so
# `#name` alone would silently drop every declaration that uses it. `#declarer`
# is the class the declaration belongs to either way -- itself for a named
# subclass, the enclosing class for an anonymous one -- so it is always named
# when the declaration lives in lib/.
module DeclarativeInclusionDiscipline
  module_function

  def carrier_classes
    ObjectSpace.each_object(Class).select do |klass|
      klass < Lain::Declarative::Carrier && klass.respond_to?(:declarer) &&
        klass.declarer.name.to_s.start_with?("Lain::")
    rescue StandardError
      false
    end
  end

  # (klass, attribute) for every attribute an InclusionValidator sits on
  # whose type does no coercion -- the exact shape Carrier's own
  # InclusionValidator override exists to guard, since a typed attribute's
  # cast already turns a non-scalar into something else (or refuses it)
  # before inclusion ever runs.
  def untyped_inclusion_sites(klass)
    klass.validators.grep(ActiveModel::Validations::InclusionValidator).flat_map do |validator|
      validator.attributes.select { |attribute| untyped?(klass, attribute) }.map { |attribute| [klass, attribute] }
    end
  end

  def untyped?(klass, attribute) = klass.attribute_types[attribute.to_s].instance_of?(ActiveModel::Type::Value)

  def accepts_empty_array?(klass, attribute)
    carrier = klass.new(attribute => [])
    carrier.valid?
    carrier.errors[attribute].empty?
  end
end

RSpec.describe "declarative inclusion discipline" do
  let(:sites) do
    DeclarativeInclusionDiscipline.carrier_classes.flat_map do |klass|
      DeclarativeInclusionDiscipline.untyped_inclusion_sites(klass)
    end
  end

  it "sweeps a real subject set, so an empty sweep cannot read as a pass" do
    # Measured 2026-09-11 against the tree this card landed on: 51 sites
    # across ~30 files. A floor, not a pin -- the exact count moves as the
    # tree grows, but a sweep finding a handful again would mean the
    # `#declarer` resolution above stopped working.
    expect(sites.size).to be >= 40
  end

  it "refuses an empty Array on every untyped inclusion-validated attribute in lib/" do
    offenders = sites.select do |klass, attribute|
      DeclarativeInclusionDiscipline.accepts_empty_array?(klass, attribute)
    end

    expect(offenders).to be_empty, lambda {
      listing = offenders.map { |klass, attribute| "  #{klass}##{attribute}" }.join("\n")
      "An untyped attribute validated by inclusion: must refuse a non-scalar before membership is " \
        "tested (Lain::Declarative::Carrier::InclusionValidator). These accept an empty Array:\n#{listing}"
    }
  end
end
