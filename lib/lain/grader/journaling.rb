# frozen_string_literal: true

module Lain
  module Grader
    # Decorates ANY `#grade` duck -- {Fixture}, {Recall}, {Rubric},
    # {TestHarness}, ... -- with a durable attestation: the returned {Grade}
    # passes through UNCHANGED, and a {Telemetry::GradeRecord} journals
    # alongside it. This closes the GG-5 gap the plan names: {Telemetry::Verdict}
    # is {Verified}'s own second-pass record, but a PLAIN Grade -- the shape
    # every OTHER grader answers with -- was never journaled at all.
    #
    # The shape is {Verified}'s own decorate-and-journal idiom, one level up:
    # `inner` untouched, wrapped by an object that only intercepts what it
    # cares about. `criteria_digest` -- the {Gherkin::Criteria#digest} this
    # grader judges against, when the subject was generated from parsed
    # Gherkin acceptance criteria -- travels alongside so a later
    # {Bench::DryReplay} read recovers "which criteria was this run graded
    # against" straight from the record, with no live Gherkin doc to re-parse.
    class Journaling
      # Raised when a subject cannot be addressed for the journal: no injected
      # `subject_digest:` callable, the subject has no `#digest` of its own,
      # and it is not a String {Canonical.digest} can hash directly. Loud beats
      # an ADDRESS-derived attestation -- hashing `subject.to_s` would journal
      # a digest keyed on the subject's `Object#inspect` identity (its memory
      # address) rather than its content, a fake-looking attestation that
      # LOOKS content-addressed but is not reproducible across processes or
      # even across two objects that mean the same thing.
      class UndigestableSubject < Lain::Error; end

      # @param inner [#grade] any grader duck; `inner.class.name` is what
      #   {Telemetry::GradeRecord#grader} attributes the verdict to
      # @param criteria_digest [String, nil] the {Gherkin::Criteria#digest}
      #   this grader judges against, when known
      # @param journal [#<<] where {Telemetry::GradeRecord} records land; the
      #   Null channel by default, the same "no caller guards `if journal`"
      #   idiom {Verified} uses
      # @param subject_digest [#call, nil] `(subject) -> String`, the subject's
      #   content address. When given, it ALWAYS wins -- the caller knows the
      #   subject's shape better than any duck-typed fallback here could.
      #   Absent, {#grade} falls back to `subject.digest` (when the subject
      #   answers one), then {Canonical.digest} for a bare String subject, and
      #   raises {UndigestableSubject} rather than guess further.
      def initialize(inner:, criteria_digest: nil, journal: Channel::Null::INSTANCE, subject_digest: nil)
        @inner = inner
        @criteria_digest = criteria_digest
        @journal = journal
        @subject_digest = subject_digest
      end

      # @param subject passed straight through to the inner grader
      # @return [Grade] the inner grader's verdict, unchanged
      def grade(subject)
        grade = @inner.grade(subject)
        @journal << Telemetry::GradeRecord.from(grade, grader: @inner.class.name,
                                                       subject_digest: digest_for(subject),
                                                       criteria_digest: @criteria_digest)
        grade
      end

      private

      # The resolution order the orchestrator's ruling pins: an injected
      # callable wins outright; a subject that already carries its own
      # content address is trusted verbatim (never rehashed); a bare String
      # subject is hashed directly; anything else is a loud, named failure --
      # never a silent `subject.to_s` hash of an address the subject never
      # chose to be identified by.
      def digest_for(subject)
        return @subject_digest.call(subject) if @subject_digest
        return subject.digest if subject.respond_to?(:digest)
        return Canonical.digest(subject) if subject.is_a?(String)

        raise UndigestableSubject,
              "cannot address a #{subject.class} subject for the journal -- pass subject_digest: " \
              "or give it a canonical #digest"
      end
    end
  end
end
