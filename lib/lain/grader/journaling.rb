# frozen_string_literal: true

module Lain
  module Grader
    # Decorates ANY `#grade` duck with a durable attestation: the returned
    # {Grade} passes through UNCHANGED, and a {Telemetry::GradeRecord} journals
    # alongside it. {Telemetry::Verdict} is {Verified}'s own second-pass
    # record, but a PLAIN Grade -- the shape every OTHER grader answers with --
    # was never journaled at all.
    #
    # `criteria_digest` travels alongside so a later {Bench::DryReplay} read
    # recovers which criteria a run was graded against straight from the record,
    # with no live Gherkin doc to re-parse.
    class Journaling
      # @param inner [#grade] any grader duck; `inner.class.name` is what
      #   {Telemetry::GradeRecord#grader} attributes the verdict to
      # @param criteria_digest [String, nil] the {Gherkin::Criteria#digest}
      #   this grader judges against, when known
      # @param journal [#<<] where {Telemetry::GradeRecord} records land; the
      #   Null channel by default, so no caller guards `if journal`
      # @param subject_digest [#call, nil] `(subject) -> String`, the subject's
      #   content address. When given, it ALWAYS wins -- the caller knows the
      #   subject's shape better than any duck-typed fallback here could.
      #   Absent, {#grade} falls back to `subject.digest` (when the subject
      #   answers one), then {Canonical.digest} for a bare String subject, and
      #   raises rather than guess further.
      def initialize(inner:, criteria_digest: nil, journal: Channel::Null::INSTANCE, subject_digest: nil)
        @inner = inner
        @criteria_digest = criteria_digest
        @journal = journal
        @subject_digest = subject_digest
      end

      # @param subject [Object] passed straight through to the inner grader
      # @return [Grade] the inner grader's verdict, unchanged
      def grade(subject)
        grade = @inner.grade(subject)
        @journal << Telemetry::GradeRecord.from(grade, grader: @inner.class.name,
                                                       subject_digest: digest_for(subject),
                                                       criteria_digest: @criteria_digest)
        grade
      end

      private

      # An injected callable wins outright; a subject that already carries its
      # own content address is trusted verbatim and never rehashed; a bare
      # String is hashed directly; anything else is a loud, named failure.
      def digest_for(subject)
        return @subject_digest.call(subject) if @subject_digest
        return subject.digest if subject.respond_to?(:digest)
        return Canonical.digest(subject) if subject.is_a?(String)

        # Raised when a subject cannot be addressed for the journal. Loud beats an
        # ADDRESS-derived attestation: hashing `subject.to_s` would journal a
        # digest keyed on the subject's `Object#inspect` identity -- its memory
        # address -- rather than its content, which LOOKS content-addressed but is
        # not reproducible across processes, or even across two objects that mean
        # the same thing.
        raise Error,
              "cannot address a #{subject.class} subject for the journal -- pass subject_digest: " \
              "or give it a canonical #digest"
      end
    end
  end
end
