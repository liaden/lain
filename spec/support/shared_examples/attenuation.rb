# frozen_string_literal: true

# The laws of {Lain::Algebra::Attenuation} -- an operation that only ever takes
# capability away, and its dual, which says the same restriction from the other
# side.
#
# There is no battery here, and that is deliberate rather than unfinished:
# nothing in the tree refutes attenuation, and a battery exists only so a
# REFUTATION can be confirmed by a named law failing. `:monoid` has shipped
# without one for the same reason and is the precedent. Should a refutation
# arrive, this Data is already the shape spec/algebra_laws_spec.rb's BATTERIES
# takes -- `.from(config)` and `#to_h` of named predicates, as in
# elementwise.rb and pure.rb.
#
# == Why partiality is a law and not an edge case
#
# Two of the seven laws below are RAISES, pinned as first-class facts. That was
# a ruling, and the reasoning is worth keeping: a chained `except` over the same
# names could be restated as "run it twice from the parent", `f(p) == f(p)`,
# which is determinism wearing idempotence's clothes and would have held no
# matter what the operation did. The honest fact is that the second call names a
# capability that is already gone, and the operation refuses. Same for the
# composition law's second half -- attenuating again to anything outside the
# request raises -- without which the operation would look total, and the
# whole no-join reading would rest on nothing.
#
# == Monotonicity is where the absent join is checked, and it is bounded by the
# == REQUEST
#
# The one sentence to take from this file: **a capability the receiver lacked is
# not the security property; a capability the attenuation DROPPED is.**
#
# Bounding a result by the receiver's names is nearly free and certifies almost
# nothing -- `only` fetches out of the receiver's own index, so a result cannot
# name anything the receiver lacked unless the operation invents a tool. The law
# is therefore against what the attenuation was ASKED to keep:
# `observed(only(s, r)) ⊆ r`, and `observed(except(s, x)) ⊆ names(s) - x`. This
# was got wrong once, and the review that caught it is the reason the paragraph
# is this long.
#
# `observed` asks what a result hands out through ANY public message, probed
# with the names the receiver held -- the DROPPED ones especially, since those
# are the inputs an escape answers wrongly. It is a knob because only the
# generator knows the subject's surface, and the surface that matters is not the
# readable one: {Lain::Effect::Handler::Live} authorizes with `#include?` and
# dispatches with `#fetch`, so a set honest in `#names`, `#each`, `#to_schema`
# and `#digest` and lying in those two passes every other law here while a
# dropped tool executes end to end. spec/lain/toolset_spec.rb holds that set and
# runs it through the real handler.
#
# The default -- `names` alone -- is the weakest honest answer, and a generator
# that leaves it there is claiming only that the result's own list is bounded.
#
# == Reading a red from this group: check the MODE, not the count
#
# Every law here is `expect(holds.call).to be(true)`, so a law that RAISED and a
# law that is FALSE both show up as one failed example. They mean opposite
# things -- `Expected false to equal true` is the operation being wrong, while a
# `Toolset::UnknownTool` out of `#attenuate` is a law that never got evaluated
# and says nothing. This bit once: a deliberately-broken `only` returning the
# empty set was reported as taking down four laws, when two of those four had
# merely raised (the chained call asks an empty set for names it no longer
# holds, which is the operation working). It genuinely falsifies two.
#
# spec/algebra_laws_spec.rb keeps `:holds`, `:fails` and an Exception apart for
# exactly this reason, but only on the battery path, which attenuation does not
# take. Until it has a refutation, reading the failure text is the check.
#
# == The depth this group reaches, which is not everything
#
# `subjects` is always the freshly-constructed sets a generator hands over, so
# **monotonicity and identity are never applied to an already-attenuated
# subject**; only composition and the two refusals reach depth 2, and they reach
# it through an intermediate the law itself builds. That limit is deliberate and
# is not fixable from here: putting attenuated subjects INTO the population would
# mean building the population with the operation under test, which is exactly
# the vacuity defect (`reduce(Identity, :>>)` in the monoid generators) that a
# review of this chunk had already found once. A population that collapses when
# the operator does proves nothing about the operator.
#
# Include with a Hash, built where `include_examples` is called so its callables
# close over locals rather than over example-group methods:
#
#   population  [#call -> Array<[subject, names]>]  the draws: a subject paired
#                                                   with the names some caller
#                                                   might request of it. Named
#                                                   `population` because that is
#                                                   one of the two knobs
#                                                   spec/algebra_laws_spec.rb's
#                                                   barren check reads.
#   operation   [Symbol]                            the attenuation; folded in
#                                                   from the registry by the
#                                                   sweep, stated by hand at a
#                                                   direct call site.
#   dual        [Symbol]                            its dual, same provenance.
#   refusal     [Class]                             the error a request outside
#                                                   the subject raises.
#   names       [#call(subject) -> Array]            the capability list, which
#                                                   duality is stated against.
#                                                   Defaults to `#names`.
#   observed    [#call(subject) -> Array]            every capability name the
#                                                   subject reveals. Defaults to
#                                                   `names`.
#   equal       [#call(a, b) -> bool]                defaults to `==`.
module AlgebraLaws
  Attenuation = Data.define(:draws, :operation, :dual, :names, :observed, :refusal, :same) do
    def self.from(config)
      names = config.fetch(:names, :names.to_proc)
      new(draws: config.fetch(:population).call, operation: config.fetch(:operation),
          dual: config.fetch(:dual), names:,
          observed: config.fetch(:observed, ->(result, _candidates) { names.call(result) }),
          refusal: config.fetch(:refusal), same: config.fetch(:equal, ->(a, b) { a == b }))
    end

    def to_h
      { "re-requesting the same names lands in the same place" => method(:idempotent?),
        "chaining the dual over the same names refuses" => method(:dual_refuses_repetition?),
        "attenuating again inside the request lands where that request alone lands" => method(:composes?),
        "attenuating again outside the request refuses" => method(:refuses_outside_the_request?),
        "the dual keeps exactly what the operation would have been asked to keep" => method(:dual?),
        "reveals no capability the attenuation dropped" => method(:monotonic?),
        "the whole list and the empty exclusion both change nothing" => method(:identity?) }
    end

    # A special case of {#composes?}, and kept anyway. `subsets(request)`
    # contains `request`, so this body is character-for-character the
    # composition triple with `smaller == request`, and it is strictly weaker:
    # thirteen falsifications of Toolset's attenuation took composition down and
    # not one of them reached this. It survives because it is the law a reader
    # of the card came here to find -- "re-requesting the same names is
    # permitted and stable" -- and reading it out of `composes?` costs more than
    # the duplicated line does.
    def idempotent?
      draws.all? do |subject, request|
        once = attenuate(subject, request)
        same.call(attenuate(once, request), once)
      end
    end

    def dual_refuses_repetition?
      repeatable.all? { |subject, request| refused? { drop(drop(subject, request), request) } }
    end

    def composes?
      chains.all? do |subject, request, smaller|
        same.call(attenuate(attenuate(subject, request), smaller), attenuate(subject, smaller))
      end
    end

    def refuses_outside_the_request?
      overreaches.all? { |subject, request, beyond| refused? { attenuate(attenuate(subject, request), beyond) } }
    end

    def dual?
      draws.all? { |subject, request| same.call(drop(subject, request), attenuate(subject, outside(subject, request))) }
    end

    def monotonic?
      bounded.all? { |result, allowed, candidates| (observed.call(result, candidates) - allowed).empty? }
    end

    def identity?
      subjects.all? do |subject|
        same.call(attenuate(subject, names.call(subject)), subject) && same.call(drop(subject, []), subject)
      end
    end

    # SENT rather than public_sent, like every other group here:
    # {Lain::Algebra.answers?} admits a private operation, so "does this class
    # answer it?" stays a different question from "is it public?".
    def attenuate(subject, request) = subject.send(operation, *request)

    def drop(subject, request) = subject.send(dual, *request)

    def outside(subject, request) = names.call(subject) - request

    # An expected raise, read as a predicate so every law stays a plain boolean.
    # Narrow on purpose: any OTHER exception propagates rather than being
    # counted as a refusal, because a partiality law confirmed by a NoMethodError
    # would confirm nothing -- the same trap spec/algebra_laws_spec.rb's battery
    # keeps :fails and an Exception apart for.
    def refused?
      yield
      false
    rescue refusal
      true
    end

    # Every (draw, subset-of-its-request) triple. Exhaustive over the subsets
    # rather than sampled: composition is where a partial operation's edges are,
    # and the empty subset and the whole request are both edges.
    def chains
      draws.flat_map { |subject, request| subsets(request).map { |smaller| [subject, request, smaller] } }
    end

    def subsets(request) = (0..request.size).flat_map { |size| request.combination(size).to_a }

    # The other half of composition: a second request that is NOT inside the
    # first, built as the first plus one name the receiver holds and the request
    # left out. Close to the request on purpose, so what the raise is about is
    # the one extra name and not a stranger.
    def overreaches
      draws.flat_map do |subject, request|
        outside(subject, request).map { |name| [subject, request, request + [name]] }
      end
    end

    # Each side of the pair, the bound it is held to, and the names worth
    # probing it WITH.
    #
    # The bound is the REQUEST, and that choice is the whole law. `only` fetches
    # out of the receiver's own index, so bounding by the receiver's names is
    # nearly free -- a result could only exceed it by inventing a tool. Bounding
    # by what the attenuation was ASKED to keep is what refuses a set that
    # quietly held on to something.
    #
    # The candidates are everything the receiver held, because the DROPPED names
    # are the interesting inputs to an `#include?`/`#fetch` probe, and the
    # retained ones are what stops a probe passing by answering no to
    # everything.
    def bounded
      draws.flat_map do |subject, request|
        held = names.call(subject)
        [[attenuate(subject, request), request, held], [drop(subject, request), held - request, held]]
      end
    end

    def subjects = draws.map(&:first).uniq

    # Draws the operation genuinely acts on. A population of whole-list requests
    # would make every law above a statement about the identity, which is the
    # quietest way this group could certify nothing.
    def attenuating = draws.reject { |subject, request| same.call(attenuate(subject, request), subject) }

    # Draws whose request names something to exclude. `except()` over no names
    # is the identity, and chaining the identity is not the fact the raise law
    # is about.
    def repeatable = draws.reject { |_subject, request| request.empty? }
  end
end

RSpec.shared_examples "an attenuation" do |config|
  laws = AlgebraLaws::Attenuation.from(config)

  laws.to_h.each { |law, holds| it(law) { expect(holds.call).to be(true) } }

  # Nested, so the including group's own `examples` are exactly the seven laws
  # above -- the shape spec/algebra_laws_spec.rb's battery/group pin reads, kept
  # even though attenuation has no battery to be pinned against yet.
  context "when reading those laws over these draws" do
    it "includes a draw the operation genuinely attenuates" do
      expect(laws.attenuating).not_to be_empty
    end

    it "includes a draw whose request names something, so the chained dual is read" do
      expect(laws.repeatable).not_to be_empty
    end

    it "includes a draw holding more than its request, so both refusals are read" do
      expect(laws.overreaches).not_to be_empty
    end
  end
end
