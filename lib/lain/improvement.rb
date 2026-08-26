# frozen_string_literal: true

require "json"
require "time"

module Lain
  # Durable notes about lain ITSELF, noticed while dogfooding, for an offline
  # pass to fold later. Deliberately not a {Telemetry} event on the per-session
  # {Lain::Journal}: a Journal is scoped to ONE project's ONE run, but a note
  # about lain belongs to every project lain has ever run in, so it lands in the
  # cross-project file {Paths#improvements_path} names.
  #
  # `Sink` (reopened below) is the one writer and this record only describes
  # itself -- the {Memory::Item}/{Memory::Recorder} split.
  Improvement = Data.define(:note, :kind, :evidence_digests, :project_hash, :session, :at) do
    include Telemetry::Journalable

    # `LINE_MAX_BYTES` is reached via `self.class::`, not by bare name: this
    # block is lexically scoped to `Lain` (the trap {Request::SYSTEM_PREFIX}
    # documents), not to the reopened `Improvement` below where it lives.
    def initialize(note:, kind:, project_hash:, session:, evidence_digests: [], at: Time.now.utc)
      self.class.check!(note:, kind:, project_hash:, session:)

      super(**normalized(note:, kind:, project_hash:, session:, evidence_digests:, at:))
      assert_within_line_budget!
    end

    # One NDJSON line, newline included: the exact bytes {Sink#append} writes in
    # its single `write` call.
    def line
      "#{JSON.generate(to_journal)}\n"
    end

    private

    def normalized(note:, kind:, project_hash:, session:, evidence_digests:, at:)
      {
        note: -note.to_s,
        kind: -kind.to_s,
        evidence_digests: normalized_digests(evidence_digests),
        project_hash: -project_hash.to_s,
        session: -session.to_s,
        at: normalized_at(at)
      }
    end

    def normalized_digests(evidence_digests)
      Array(evidence_digests).map { |digest| -digest.to_s }.freeze
    end

    def normalized_at(at)
      at.is_a?(Time) ? -at.utc.iso8601(6) : -at.to_s
    end

    # A caller-supplied evidence_digests list can blow the cross-process
    # line-atomicity budget even under NOTE_MAX_BYTES -- fail construction
    # loudly rather than write a line that risks tearing across two writes.
    def assert_within_line_budget!
      budget = self.class::LINE_MAX_BYTES
      return if line.bytesize <= budget

      raise ArgumentError,
            "record exceeds the #{budget}-byte line budget (#{line.bytesize} bytes) once " \
            "evidence_digests is included -- trim the list"
    end
  end

  class Improvement
    include Declarative

    # Reopened rather than declared inside the `Data.define(...) do ... end`
    # block above: a `module`/`class` keyword written INSIDE that block is
    # lexically scoped to `Lain`, not to the Data-defined class -- the same trap
    # {Request::SYSTEM_PREFIX} documents.

    # The closed kind vocabulary: a knob lain's USER could turn, a bug, a feature
    # lain lacks, or a doc gap.
    KINDS = %w[knob bug missing-feature doc].freeze

    # A caller composes `note` freely and everything else in a record is small
    # and structured, so bounding `note` is what keeps an ordinary record well
    # inside {LINE_MAX_BYTES}.
    NOTE_MAX_BYTES = 2048

    # PIPE_BUF, the conservative cross-process line-atomicity bound: a single
    # `write(2)` of at most this many bytes to a file opened O_APPEND cannot
    # interleave with another writer's own single write, on every filesystem this
    # harness runs on. Every record is asserted against it at construction rather
    # than hoped to stay under it.
    LINE_MAX_BYTES = 4096

    # Inline rather than on a carrier of its own -- nothing outside this class
    # ever names these rules. `check!` and not `settle!`, because `at` normalizes
    # a {Time} and the four String fields are INTERNED (`-`) rather than merely
    # frozen; both are coercions a settled copy would lose, so the constructor
    # keeps them and this declaration only refuses. Placed below
    # {KINDS}/{NOTE_MAX_BYTES} so those resolve lexically with nothing to defer.
    declare do
      attribute :note
      attribute :kind
      attribute :project_hash
      attribute :session

      validates :note, presence: { message: "must not be blank" }
      validates :kind, inclusion: { in: KINDS, message: "must be one of #{KINDS.inspect}, got %<value>s" }
      validates :project_hash, presence: { message: "must name the project, got nil" }
      validates :session, presence: { message: "must name the session, got nil" }
      validate :note_within_size_budget

      private

      # ActiveModel's `length:` validator counts CHARACTERS; the atomicity budget
      # this protects is a BYTE budget, what `write(2)` actually sees -- hence
      # the hand-rolled `#bytesize` check.
      def note_within_size_budget
        return if note.to_s.bytesize <= NOTE_MAX_BYTES

        errors.add(:note, "must be at most #{NOTE_MAX_BYTES} bytes, got #{note.to_s.bytesize}")
      end
    end

    # The one writer. Opens fresh for every append rather than holding a
    # long-lived fd the way {Journal} does, because the callers here are
    # concurrent PROCESSES (dogfood sessions in separate repos), not fibers in
    # one: a {Journal}-style handle buys in-process Monitor ordering, which does
    # nothing for a sibling process's own fd. `File::APPEND` (O_APPEND) at
    # `open(2)` is what makes them safe -- every writer's single `write(2)`
    # atomically seeks to end-of-file and writes, so lines interleave whole,
    # never torn, as long as each stays under {LINE_MAX_BYTES}.
    class Sink
      def initialize(session:, paths: Paths.new, project_hash: paths.project_hash)
        @paths = paths
        @session = session
        @project_hash = project_hash
      end

      # Returns the record actually written.
      def append(note:, kind:, evidence_digests: [])
        record = Improvement.new(note:, kind:, evidence_digests:, project_hash: @project_hash, session: @session)
        write(record.line)
        record
      end

      private

      def write(line)
        File.open(@paths.improvements_path, File::WRONLY | File::CREAT | File::APPEND, 0o644) do |file|
          file.write(line)
        end
      end
    end
  end
end
