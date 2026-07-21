# frozen_string_literal: true

require "json"
require "time"

module Lain
  # M2's harness-improver sink: durable notes about lain ITSELF (a knob, a
  # bug, a missing feature, a doc gap) noticed while dogfooding, for M6's
  # offline pass to fold later. Deliberately not a {Telemetry} event riding
  # the per-session {Lain::Journal}: a session's Journal is scoped to ONE
  # project's ONE run, but a note about lain belongs to every project lain
  # has ever run in, so it lands in the cross-project file
  # {Paths#improvements_path} names instead.
  #
  # `Sink` (reopened below) is the one writer; this record only knows how to
  # describe itself -- {#line} is the exact bytes a caller appends, the same
  # split {Memory::Item}/{Memory::Recorder} draw between a record and its
  # writer.
  Improvement = Data.define(:note, :kind, :evidence_digests, :project_hash, :session, :at) do
    include Telemetry::Journalable

    # `Guards`/`LINE_MAX_BYTES` are reached via `self.class::`, not by bare
    # name: this block is lexically scoped to `Lain` (the trap
    # {Request::SYSTEM_PREFIX} documents), not to the reopened `Improvement`
    # below where those constants actually live.
    def initialize(note:, kind:, project_hash:, session:, evidence_digests: [], at: Time.now.utc)
      self.class::Guards::Record.check!(note:, kind:, project_hash:, session:)

      super(**normalized(note:, kind:, project_hash:, session:, evidence_digests:, at:))
      assert_within_line_budget!
    end

    # One NDJSON line, newline included: the exact bytes {Sink#append} writes
    # in its single `write` call.
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
    # line-atomicity budget even with a note under NOTE_MAX_BYTES -- fail
    # construction loudly rather than write a line that risks tearing across
    # two writes (see Sink's header for why a torn line matters).
    def assert_within_line_budget!
      budget = self.class::LINE_MAX_BYTES
      return if line.bytesize <= budget

      raise ArgumentError,
            "record exceeds the #{budget}-byte line budget (#{line.bytesize} bytes) once " \
            "evidence_digests is included -- trim the list"
    end
  end

  # Reopened rather than declared inside the `Data.define(...) do ... end`
  # block above: a `module`/`class` keyword written INSIDE that block is
  # lexically scoped to this file's enclosing module (`Lain`), not to the
  # Data-defined class -- the same trap {Request::SYSTEM_PREFIX} documents.
  # Nested inside the SAME top-level `module Lain` (not a second one) so the
  # file still declares exactly one top-level module.
  class Improvement
    # The closed kind vocabulary the interview settled on: a knob lain's
    # USER could turn, a bug, a feature lain lacks, or a doc gap.
    KINDS = %w[knob bug missing-feature doc].freeze

    # A caller composes `note` freely; everything else in a record is small
    # and structured, so bounding `note` is what keeps an ordinary record
    # well inside {LINE_MAX_BYTES}.
    NOTE_MAX_BYTES = 2048

    # PIPE_BUF, the conservative cross-process line-atomicity bound the
    # interview settled on: a single `write(2)` of at most this many bytes to
    # a file opened O_APPEND cannot interleave with another writer's own
    # single write, on every filesystem this harness runs on. Every record
    # is asserted against it at construction (see #initialize above) rather
    # than hoped to stay under it.
    LINE_MAX_BYTES = 4096

    # {Guard} construction contract for {Improvement}: validate-then-freeze,
    # the same convention every {Telemetry} carrier uses.
    module Guards
      # An improvement record must name a real kind and project/session, and
      # its note must be present and within {NOTE_MAX_BYTES}.
      class Record < Guard
        attribute :note
        attribute :kind
        attribute :project_hash
        attribute :session

        validates :note, presence: { message: "must not be blank" }
        validates :kind, inclusion: { in: KINDS, message: "must be one of #{KINDS.inspect}, got %<value>s" }
        validates :project_hash, presence: { message: "must name the project, got nil" }
        validates :session, presence: { message: "must name the session, got nil" }
        validate :note_within_size_guard

        private

        # ActiveModel's `length:` validator counts characters, not bytes; the
        # atomicity budget this guard protects is a BYTE budget (what
        # `write(2)` actually sees), so the check is hand-rolled over
        # `#bytesize` rather than reached for via `length: { maximum: }`.
        def note_within_size_guard
          return if note.to_s.bytesize <= NOTE_MAX_BYTES

          errors.add(:note, "must be at most #{NOTE_MAX_BYTES} bytes, got #{note.to_s.bytesize}")
        end
      end
    end

    # The one writer. Opens the destination fresh for every append -- never
    # holds a long-lived fd the way {Journal} does -- because the callers
    # this sink actually serves are concurrent PROCESSES (separate dogfood
    # sessions in separate repos), not fibers within one process: a
    # long-lived {Journal}-style handle only buys in-process Monitor
    # ordering, which does nothing for a sibling process's own fd. What DOES
    # make concurrent processes safe is `File::APPEND` (O_APPEND) set at
    # `open(2)` -- every writer's single `write(2)` atomically seeks to
    # end-of-file and writes, so lines from different processes interleave
    # whole, never torn, as long as each write stays under {LINE_MAX_BYTES}
    # (see {Improvement}'s own guard).
    class Sink
      def initialize(session:, paths: Paths.new, project_hash: paths.project_hash)
        @paths = paths
        @session = session
        @project_hash = project_hash
      end

      # Builds one {Improvement} from the given fields and appends its
      # {Improvement#line}. Returns the record actually written.
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
