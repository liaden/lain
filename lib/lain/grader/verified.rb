# frozen_string_literal: true

module Lain
  module Grader
    # Decorates a FINDING-PRODUCING grader with a second refutation pass: the
    # {#inner} grader emits raw findings, an injected {#refuter} judges each one
    # in a SEPARATE context, and only survivors come back out. The shape is
    # {Effect::Handler::Recorded}'s decoration idiom one level up -- `inner`
    # untouched, wrapped by an object that only intercepts what it cares about.
    #
    # A finding-producing grader is distinct from the scalar {Fixture}/{Recall}/
    # {Rubric} convention (grader.rb's module doc: every grader answers `#grade`
    # with ONE {Grade}) -- here `#grade(subject)` answers an Enumerable of raw
    # findings instead, and Verified is generic over whatever that Enumerable
    # holds, so long as each element survives `#to_s` (the refuter's own
    # requirement, inherited from {Rubric}).
    #
    # Every survivor comes back wrapped as a {Finding}: the raw finding paired
    # with the {Grade} that verified it, so a caller reads the claim alongside
    # its verdict. A REFUTED finding is dropped, not returned and not counted --
    # the entire point of a two-pass verifier is that a false positive that
    # reaches a human costs more than the second model call that would have
    # caught it.
    #
    # Every refutation journals as a {Telemetry::Verdict} BEFORE the filter
    # decision is applied, keyed by the finding's own content digest -- so a
    # reader asking "why did N drop to N-1" gets the refuted finding's `why`
    # too, not just the survivors', and {Refuter::Recorded.from_journal} can
    # replay the exact filtered set later with no model call.
    class Verified
      # One surviving finding: the raw finding, and the Grade that verified it.
      # `finding` is defensively `dup.freeze`d -- the same trap {Telemetry::Verdict}
      # and {Telemetry::WriteRefused} guard against: `Data.define` freezes the
      # instance itself but not a mutable object reachable THROUGH it, and one
      # unfrozen member is enough to make the value non-`Ractor.shareable?`.
      # `Grade` is already deeply frozen by its own constructor, so only
      # `finding` needs the treatment here.
      Finding = Data.define(:finding, :grade) do
        def initialize(finding:, grade:)
          super(finding: finding.dup.freeze, grade:)
        end
      end

      # @param inner [#grade] a finding-producing grader
      # @param refuter [#refute] judges ONE finding, in a separate context. No
      #   default -- {Refuter} needs a provider and model to construct, so the
      #   caller always names one explicitly (a live {Refuter} to judge for
      #   real, a {Refuter::Recorded} to replay journaled verdicts). Injectable
      #   so an oracle-backed refuter can swap in later with no change here.
      # @param journal [#<<] where {Telemetry::Verdict} records land; the Null
      #   channel by default, so no caller guards `if journal` (the same
      #   default {Middleware::JournalRequests} uses)
      def initialize(inner:, refuter:, journal: Channel::Null::INSTANCE)
        @inner = inner
        @refuter = refuter
        @journal = journal
      end

      # @param subject passed straight through to the inner grader
      # @return [Enumerable<Finding>] only the findings that survived refutation
      def grade(subject)
        @inner.grade(subject).filter_map { |finding| verify(finding) }
      end

      private

      # Judge, journal, THEN filter -- in that order, so a refuted finding
      # still leaves a Verdict record behind.
      def verify(finding)
        grade = @refuter.refute(finding)
        @journal << Telemetry::Verdict.new(digest: Canonical.digest(finding.to_s), survived: grade.pass?,
                                           score: grade.score, why: grade.why)
        Finding.new(finding:, grade:) if grade.pass?
      end
    end
  end
end
