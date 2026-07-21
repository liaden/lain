# frozen_string_literal: true

require "stringio"

# Grader::Journaling decorates ANY #grade duck with a durable attestation: the
# Grade passes through unchanged, and a Telemetry::GradeRecord journals
# alongside it -- the GG-5 gap the plan names, since Telemetry::Verdict is
# Verified's own second-pass record and a PLAIN Grade was never journaled
# before this.
#
# Panel ruling (REQUEST-CHANGES round): the subject digest must NEVER be a
# silent `subject.to_s` hash -- that addresses the subject's Object identity
# (its `inspect`/memory address), not its content, a fake-looking attestation
# that is not reproducible. The resolution order is pinned: an injected
# `subject_digest:` callable wins outright; else a subject's own `#digest` is
# trusted verbatim; else a bare String subject is hashed directly; else a
# named UndigestableSubject error, loud rather than guessed.
RSpec.describe Lain::Grader::Journaling do
  # A minimal #grade test double: answers whatever Grade it was built with,
  # ignoring the subject -- for the tests that only care about pass-through/
  # defaulting, not a real grader. A singleton method on a plain Object (not
  # an anonymous Struct/Class) so `.class.name` -- what Journaling attributes
  # the record to -- is a real, non-nil String, the same as any shipped grader.
  def stub_grader(grade)
    Object.new.tap { |double| double.define_singleton_method(:grade) { |_subject| grade } }
  end

  let(:rspec_mini) { File.expand_path("../../fixtures/projects/rspec_mini", __dir__) }
  let(:worker_env) { Lain::WorkerEnv.new(cwd: rspec_mini, env: ENV.to_h) }
  let(:criteria_digest) { Lain::Canonical.digest("some criteria") }
  # WorkerEnv carries no #digest of its own (its `cwd`/`env` are sent-not-stored,
  # never content-addressed), so every scenario that grades one injects a
  # callable -- the resolution order's own top case.
  let(:worker_env_digest) { ->(env) { Lain::Canonical.digest(env.cwd) } }

  describe "#grade" do
    it "returns the Grade unchanged and journals one grade_record with score, subject digest, and criteria digest" do
      inner = Lain::Grader::TestHarness.new(rspec_mini)
      journal = []

      decorated = described_class.new(inner:, criteria_digest:, journal:, subject_digest: worker_env_digest)
      grade = decorated.grade(worker_env)

      expect(grade).to be_a(Lain::Grader::Grade)
      expect(journal.size).to eq(1)
      record = journal.first
      expect(record).to be_a(Lain::Telemetry::GradeRecord)
      expect(record.grader).to eq("Lain::Grader::TestHarness")
      expect(record.score).to eq(grade.score)
      expect(record.pass).to eq(grade.pass?)
      expect(record.why).to eq(grade.why)
      expect(record.subject_digest).to eq(Lain::Canonical.digest(rspec_mini))
      expect(record.criteria_digest).to eq(criteria_digest)
    end

    it "passes the inner Grade through byte-identically, decoration only observes it" do
      grade = Lain::Grader::Grade.new(score: 0.75, why: "3/4 examples passed")
      inner = stub_grader(grade)

      returned = described_class.new(inner:, journal: []).grade("some subject")

      expect(returned).to equal(grade)
    end

    it "defaults criteria_digest to nil, journaled as the record's absent value" do
      grade = Lain::Grader::Grade.new(score: 1.0, why: "all good")
      journal = []

      described_class.new(inner: stub_grader(grade), journal:).grade("subject")

      expect(journal.first.criteria_digest).to be_nil
    end

    it "defaults to the Null journal, so no caller has to guard `if journal`" do
      grade = Lain::Grader::Grade.new(score: 1.0, why: "all good")

      expect { described_class.new(inner: stub_grader(grade)).grade("subject") }.not_to raise_error
    end

    describe "subject digest resolution" do
      it "raises a named UndigestableSubject naming the subject's class when nothing can address it" do
        grade = Lain::Grader::Grade.new(score: 1.0, why: "all good")
        subject = Object.new

        expect { described_class.new(inner: stub_grader(grade), journal: []).grade(subject) }
          .to raise_error(described_class::UndigestableSubject, /Object/)
      end

      it "hashes a String subject directly, stably across two calls" do
        grade = Lain::Grader::Grade.new(score: 1.0, why: "all good")
        journal = []
        decorated = described_class.new(inner: stub_grader(grade), journal:)

        decorated.grade("the same subject")
        decorated.grade("the same subject")

        expect(journal.map(&:subject_digest).uniq.size).to eq(1)
        expect(journal.first.subject_digest).to eq(Lain::Canonical.digest("the same subject"))
      end

      it "trusts a subject's own #digest verbatim, never rehashing it" do
        subject = Struct.new(:digest).new("blake3:already-addressed")
        grade = Lain::Grader::Grade.new(score: 1.0, why: "all good")
        journal = []

        described_class.new(inner: stub_grader(grade), journal:).grade(subject)

        expect(journal.first.subject_digest).to eq("blake3:already-addressed")
      end

      it "prefers an injected subject_digest callable over the subject's own #digest" do
        subject = Struct.new(:digest).new("blake3:subjects-own-digest")
        grade = Lain::Grader::Grade.new(score: 1.0, why: "all good")
        journal = []

        described_class.new(inner: stub_grader(grade), journal:,
                            subject_digest: ->(_subject) { "blake3:injected-wins" })
                       .grade(subject)

        expect(journal.first.subject_digest).to eq("blake3:injected-wins")
      end
    end

    it "propagates a raising inner grader's exception unchanged, journaling nothing" do
      inner = Object.new.tap do |double|
        double.define_singleton_method(:grade) { |_subject| raise "the inner grader blew up" }
      end
      journal = []

      expect { described_class.new(inner:, journal:).grade("subject") }
        .to raise_error(RuntimeError, "the inner grader blew up")
      expect(journal).to be_empty
    end
  end

  describe Lain::Telemetry::GradeRecord do
    it "is Ractor-shareable (no reachable mutable state)" do
      record = described_class.new(grader: +"Lain::Grader::TestHarness", score: 0.5, pass: false,
                                   why: +"half passed", subject_digest: +"blake3:abc",
                                   criteria_digest: +"blake3:def")

      expect(Ractor.shareable?(record)).to be(true)
    end
  end

  describe "replay: a Journal containing a grade_record round-trips the attestation" do
    it "recovers the criteria digest and grader class from records read by type" do
      io = StringIO.new
      real_journal = Lain::Journal.new(io:)
      inner = Lain::Grader::TestHarness.new(rspec_mini)

      described_class.new(inner:, criteria_digest:, journal: real_journal, subject_digest: worker_env_digest)
                     .grade(worker_env)

      records = Lain::Journal.records(io.string.each_line, type: "grade_record").to_a

      expect(records.size).to eq(1)
      expect(records.first.fetch("criteria_digest")).to eq(criteria_digest)
      expect(records.first.fetch("grader")).to eq("Lain::Grader::TestHarness")
      expect(records.first.fetch("type")).to eq("grade_record")
    end
  end
end
