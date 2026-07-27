# frozen_string_literal: true

# The sweep that turns {Lain::Algebra}'s declarations into obligations.
#
# A1 put the claims in `lib/`, beside the operations they are about, and made
# them enumerable. That is only worth something if something enumerates them: a
# marker nothing reads is decoration, and a marker read by a hand-maintained
# list in a spec is decoration with extra steps. So this file walks
# {Lain::Algebra.registry} itself and names no class and no operation of its
# own -- declare a structure anywhere in `lib/` and it is swept; delete one and
# its generator is orphaned and says so.
#
# == What a declaration costs its author
#
# A generator, in spec/support/algebra_generators.rb, keyed by the declaring
# class and the operation. No generator, no proof: the coverage example fails
# naming exactly what is missing. That is the point -- a structure cannot be
# claimed without supplying the means to prove it.
#
# == Declarations run the shared groups; refutations run a battery
#
# A declaration is held to `spec/support/shared_examples/*` UNCHANGED. Those
# groups are also the differential oracle for the Rust port
# (spec/lain/rust/timeline_spec.rb runs the same file against
# {Lain::Ext::Timeline}), so bending one to suit this sweep would silently bend
# that. Note the direction of the dependency, too: a declaration is what makes
# the laws RUN HERE, never a precondition for running them anywhere else --
# a Rust-backed Timeline cannot carry a Ruby concern and must not have to.
#
# A refutation cannot use those groups: RSpec has no "expect this group to
# fail", and improvising one would be the loosest thing in this file. So a
# refuted operation goes through a BATTERY -- the same laws, transcribed from
# the group that owns them, as predicates answering :holds, :fails, or the
# Exception they raised. Three outcomes and not two, because the trap is real:
# run `#causal_meets` through the semilattice laws naively and associativity
# dies of NoMethodError on Array, which proves exactly nothing about
# associativity. A refutation is confirmed only by :fails, and a raise from any
# law fails the sweep.
#
# == How the battery is pinned to the group it transcribes
#
# Two readings of one law set can drift, in two directions, and BOTH are
# checked. A battery law that grew STRONGER than the group's would refute
# something true -- so every declaration whose structure has a battery is run
# through the battery too, where that shows up at once as a false failure. And
# a battery law that was gutted, deleted or renamed would quietly stop judging,
# while every remaining law stayed green -- so the battery's law NAMES are
# matched against the descriptions of the examples the shared group actually
# contributed. RSpec inlines a shared group's examples into the including
# group, so reading `examples` immediately after `include_examples` gives that
# group's own law names, and one set comparison catches a gutted battery and a
# drifted group alike.
#
# == Whose claim is asserted, and where
#
# The registry's `identity` and `analysis` are folded into the law run, so a
# declaration is load-bearing rather than merely enumerated. A refutation's
# `reason` is held to the same standard: recording prose and asserting two
# lines away that it is non-empty is not evidence of anything, so a generator
# must also EXHIBIT what the reason says -- `#causal_meets` answering more than
# one maximal lower bound, `PurgeFailedInputs` giving one message two images
# according to position.

# The four laws of "a meet semilattice under ancestry", transcribed from
# spec/support/shared_examples/meet_semilattice.rb -- including its defaults,
# because a battery that defaulted differently would be judging a different
# operation. Exhaustive rather than sampled: a refutation has to be
# DEMONSTRATED, and a sampled one that happened to miss its own witness would
# report a false confirmation half the time.
#
# {AlgebraLaws::Elementwise}, the other battery, lives in
# spec/support/shared_examples/elementwise.rb, where it doubles as the shared
# group for that structure.
module AlgebraLaws
  MeetSemilattice = Data.define(:elements, :meet, :below, :same) do
    def self.from(config)
      new(elements: AlgebraLaws.witnesses(config.fetch(:population).call),
          meet: config.fetch(:meet, ->(a, b) { a.meet(b) }),
          below: config.fetch(:ancestor_of, ->(m, a) { m.ancestor_of?(a) }),
          same: config.fetch(:equal, ->(a, b) { a == b }))
    end

    def to_h
      { "is idempotent" => method(:idempotent?),
        "is commutative" => method(:commutative?),
        "is associative" => method(:associative?),
        "orders a meet below both operands" => method(:below_both?) }
    end

    def idempotent? = elements.all? { |a| same.call(meet.call(a, a), a) }

    def commutative? = pairs.all? { |a, b| same.call(meet.call(a, b), meet.call(b, a)) }

    def associative?
      triples.all? do |a, b, c|
        same.call(meet.call(meet.call(a, b), c), meet.call(a, meet.call(b, c)))
      end
    end

    def below_both?
      pairs.all? do |a, b|
        lower = meet.call(a, b)
        below.call(lower, a) && below.call(lower, b)
      end
    end

    def pairs = elements.permutation(2)

    def triples = elements.permutation(3)
  end

  # A structure with no entry here is unprovable, and the sweep says so rather
  # than skipping it: `:pure` is in {Lain::Algebra::STRUCTURES} and nothing
  # declares it yet, so the first `pure on:` line will fail here, naming
  # itself, until someone writes its laws. That failure is the feature.
  GROUPS = {
    monoid: "a monoid",
    commutative_monoid: "a commutative monoid",
    meet_semilattice: "a meet semilattice under ancestry",
    elementwise: "an elementwise map",
    pure: "a pure operation"
  }.freeze

  BATTERIES = { meet_semilattice: MeetSemilattice, elementwise: Elementwise, pure: Pure }.freeze

  # What the REGISTRY contributes to a law run, by structure. Asked by
  # respond_to? rather than by record type: a Declaration answers #identity and
  # #analysis and a Refutation answers neither, which is the honest shape --
  # what evidence a claim carries depends on what it claims.
  #
  # `operation` is evidence too, and for the same reason the others are: a group
  # that assumed WHICH method it was judging could be handed a generator that
  # proved a different one. Both structures whose laws invoke the subject take
  # it, so `pure on: :blocks` cannot be discharged by exercising `#ranges`.
  EVIDENCE = { monoid: :identity, commutative_monoid: :identity,
               elementwise: %i[operation analysis], pure: %i[operation] }.freeze

  # The knobs that carry a population, whichever structure supplies one. An
  # empty population makes every `all?` law vacuously true, which is the
  # quietest way this whole file could certify nothing.
  POPULATIONS = %i[population spans].freeze

  # How many members of a population the exhaustive battery reasons over.
  # Taken from the END of it on purpose: {MeetSemilatticePopulations#union_graph}
  # builds its fan-ins and its unanchored stranger last, and those are the
  # shapes a meet law actually bends on.
  WITNESSES = 4

  module_function

  def witnesses(population) = population.last(WITNESSES)

  # The knobs a generator supplies, plus what `lib/` declared. Folding the
  # registry's own evidence in is what keeps the declaration load-bearing: the
  # monoid laws run against the DECLARED unit, and the elementwise laws against
  # the DECLARED analysis, so a wrong entry breaks a law rather than sitting
  # there looking plausible.
  def config(entry, knobs) = knobs.merge(evidence(entry))

  # Lazy identities re-invoke their thunk on every read (a frozen Data has
  # nowhere to memoize), and Timeline's would mint a fresh Store each time. Read
  # once, here, and the whole run shares the answer.
  def evidence(entry)
    Array(EVIDENCE[entry.structure]).select { |field| entry.respond_to?(field) }
                                    .to_h { |field| [field, entry.public_send(field)] }
  end

  # Every law of `structure`, classified. An Exception is returned rather than
  # raised so that "the law is false" and "the operation is the wrong type to
  # be asked" stay distinguishable -- the second is not a refutation.
  def run(structure, config)
    battery(structure, config).transform_values do |law|
      law.call ? :holds : :fails
    rescue StandardError => e
      e
    end
  end

  def battery(structure, config) = BATTERIES.fetch(structure).from(config).to_h

  def battery?(structure) = BATTERIES.key?(structure)

  def provable?(entry) = GROUPS.key?(entry.structure) && !AlgebraGenerators.knobs_for(entry).nil?

  def refutable?(entry) = battery?(entry.structure) && !AlgebraGenerators.knobs_for(entry).nil?

  def barren?(knobs) = POPULATIONS.filter_map { |knob| knobs[knob] }.any? { |source| source.call.empty? }

  # A generator is keyed [subject, operation] and therefore serves EVERY claim
  # about that operation -- which the declaration side already handles, since
  # each structure's group reads only the knobs it needs. `refutes:` and
  # `exhibits:` were the one place that multiplicity was unhandled: a class
  # refuting two structures on one operation held the second battery to the
  # first's law name, and no phrasing of the generator could say otherwise.
  #
  # So both may be keyed BY STRUCTURE, and stay flat when only one structure is
  # refuted. Told apart by the keys rather than by a flag: a per-structure form's
  # top-level keys are all STRUCTURES, while a flat `exhibits:` is keyed by its
  # own prose and a flat `refutes:` is not a Hash at all. Every generator written
  # before this distinction existed reads unchanged.
  def for_structure(knob, structure)
    return knob unless per_structure?(knob)

    knob.fetch(structure)
  end

  def per_structure?(knob)
    knob.is_a?(Hash) && !knob.empty? && knob.keys.all? { |key| Lain::Algebra::STRUCTURES.include?(key) }
  end

  def name(claim) = "#{claim.first}##{claim.last}"

  def name_all(claims) = claims.empty? ? "nothing" : claims.map { |claim| name(claim) }.join(", ")

  def name_entry(entry) = "#{name([entry.subject, entry.operation])} claims :#{entry.structure}"
end

RSpec.describe "the algebra registry, held to the laws it claims" do
  registry = Lain::Algebra.registry
  claims = registry.map { |entry| [entry.subject, entry.operation] }.uniq

  describe "coverage" do
    # An empty registry would satisfy every "all declarations are covered"
    # phrasing vacuously, which is the one way this whole file could go green
    # while proving nothing.
    it "makes at least one claim" do
      expect(registry.to_a).not_to be_empty
    end

    # Both directions. Missing is the card's obligation -- a declaration with
    # no means of proof. Orphaned is its mirror and is what stops the vacuum:
    # delete every declaration in `lib/` and seven generators are left holding
    # proofs of nothing, and this fails.
    it "registers exactly one generator per claim: none missing, none orphaned" do
      missing = claims - AlgebraGenerators.claims
      orphaned = AlgebraGenerators.claims - claims
      expect([missing, orphaned]).to eq([[], []]), lambda {
        "claimed with no generator in spec/support/algebra_generators.rb, so unprovable: " \
          "#{AlgebraLaws.name_all(missing)}; registered as a generator for a claim nobody makes: " \
          "#{AlgebraLaws.name_all(orphaned)}"
      }
    end

    # Every law here quantifies over a population, so an empty one turns `all?`
    # into "true, of nothing" and the sweep into a green certificate of
    # silence. It is also what turns a meet population into a confusing
    # NoMethodError on nil rather than a sentence.
    it "gives every generator something to reason over" do
      barren = AlgebraGenerators.registered.select { |_claim, knobs| AlgebraLaws.barren?(knobs) }
      expect(barren.keys.map { |claim| AlgebraLaws.name(claim) }).to eq([])
    end

    it "knows a law group for every structure declared" do
      unknown = registry.declarations.reject { |entry| AlgebraLaws::GROUPS.key?(entry.structure) }
      expect(unknown.map { |entry| AlgebraLaws.name_entry(entry) }).to eq([])
    end

    it "knows a law battery for every structure refuted" do
      unknown = registry.refutations.reject { |entry| AlgebraLaws.battery?(entry.structure) }
      expect(unknown.map { |entry| AlgebraLaws.name_entry(entry) }).to eq([])
    end

    it "runs a law group against every declaration" do
      unproven = registry.declarations.reject { |entry| AlgebraLaws.provable?(entry) }
      expect(unproven.map { |entry| AlgebraLaws.name_entry(entry) }).to eq([])
    end

    it "runs a law battery against every refutation" do
      unconfirmed = registry.refutations.reject { |entry| AlgebraLaws.refutable?(entry) }
      expect(unconfirmed.map { |entry| AlgebraLaws.name_entry(entry) }).to eq([])
    end
  end

  registry.declarations.select { |entry| AlgebraLaws.provable?(entry) }.each do |declaration|
    config = AlgebraLaws.config(declaration, AlgebraGenerators.knobs_for(declaration))

    describe "#{declaration.subject}##{declaration.operation}, declared :#{declaration.structure}" do
      include_examples AlgebraLaws::GROUPS.fetch(declaration.structure), config

      # Read HERE and not inside an example: at this point in the group body
      # the only examples defined are the ones the shared group just
      # contributed, so this IS that group's list of laws, by name.
      group_laws = examples.map(&:description)

      if AlgebraLaws.battery?(declaration.structure)
        it "holds every law of the battery its refutations are judged by" do
          outcomes = AlgebraLaws.run(declaration.structure, config)
          expect(outcomes.values.uniq).to eq([:holds]), -> { outcomes.inspect }
        end

        # Without this, a battery law deleted or renamed simply stops running
        # and every example above stays green -- the differential fork the
        # shared groups exist to prevent, reappearing one level up.
        #
        # What a NAME pin does not catch is a battery law whose BODY went
        # trivially true under an unchanged name, and that is not a hole worth
        # a mutation harness: a battery law only has to have teeth where a
        # refutation rests on it, and there the teeth are asserted directly --
        # `refutes:` demands :fails, so a gummed law reports :holds and the
        # refutation fails. For every other law the shared group above IS the
        # assertion and the battery is a redundant echo of it. Should a
        # refutation ever come to rest on one of those, the same `refutes:`
        # check starts biting on it too, exactly when it begins to matter.
        it "judges refutations by exactly the laws this group asserts" do
          expect(AlgebraLaws.battery(declaration.structure, config).keys).to match_array(group_laws)
        end
      end
    end
  end

  registry.refutations.select { |entry| AlgebraLaws.refutable?(entry) }.each do |refutation|
    knobs = AlgebraGenerators.knobs_for(refutation)
    config = AlgebraLaws.config(refutation, knobs)
    refutes = AlgebraLaws.for_structure(knobs.fetch(:refutes), refutation.structure)
    exhibits = AlgebraLaws.for_structure(knobs.fetch(:exhibits, {}), refutation.structure)

    describe "#{refutation.subject}##{refutation.operation}, refuted as :#{refutation.structure}" do
      let(:outcomes) { AlgebraLaws.run(refutation.structure, config) }

      # The generator names which law the refutation turns on, so a refutation
      # cannot be confirmed by whichever law happened to break -- including one
      # that broke on a typo'd operation name.
      it "fails #{refutes.inspect}, which is what makes the refutation true" do
        expect(outcomes).to include(refutes => :fails)
      end

      # The escalation trigger, mechanised: a law that raised was never
      # evaluated, so it can neither confirm nor deny anything.
      it "raises from no law -- a refutation confirmed by an error proves nothing" do
        expect(outcomes.reject { |_law, outcome| outcome.is_a?(Symbol) }).to eq({})
      end

      it "says why, in the registry" do
        expect(refutation.reason).not_to be_empty
      end

      # A failing law says the structure is absent. It does not say the
      # recorded prose is WHY it is absent -- so the witness has to show the
      # reason itself, or `reason` is a comment whose length this file has been
      # measuring.
      it "exhibits that reason rather than only stating it" do
        expect(exhibits).not_to be_empty
      end

      exhibits.each do |shown, holds|
        it("exhibits its recorded reason: #{shown}") { expect(holds.call).to be(true) }
      end
    end
  end
end
