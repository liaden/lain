# frozen_string_literal: true

module Lain
  module Plan
    # PC-2: the deterministic step-closure record. When a chunk of the plan is
    # done, this is what SURVIVES it -- a frozen value derived entirely from
    # content-addressed sources, so nothing in it is a fresh claim a replay
    # could not reproduce:
    #
    # * step id/title/status/criteria_digest come from the {Plan::Step};
    # * pass/score/why come from the chunk's {Grader::Grade};
    # * files + blob digests come from the {Workspace::Snapshot} event in force
    #   at the seam ({Event::Projection#workspace_at}) -- carried with the
    #   snapshot's OWN write-set-only scope note, so the record names its own
    #   blind spot rather than implying full coverage (bash writes outside the
    #   write-set are an honest gap, W4's persistence follow-up, not this card's);
    # * `elided_digests` are the chunk's turn digests -- the span compaction
    #   drops from the render, kept HERE as attestation. They stay in the Store
    #   un-rendered ({Context::Compact} elides bytes, not objects), so the
    #   closure names them rather than copying them;
    # * `notes_for_future_steps` is empty at the deterministic tier -- the
    #   heuristic floor. A model-tier variant (Oracle-generated, F2-stringified)
    #   fills it later; the floor is what keeps `.build` a zero-model-call fold.
    #
    # A failed step closes RICHER, not poorer: `error_digests` name the erroring
    # tool_result blocks in the chunk (purge-failed-keep-error at plan
    # granularity), addressed by {Canonical.digest} -- pointers into content the
    # elided turns already hold in the Store.
    #
    # Store-borne by #digest (ContentAddressed), so a fork/replay finds it by
    # address. But the Store is in-memory per process, so #record ALSO journals a
    # {Telemetry::ClosureRecord} pointer -- the same Store-pointer-in-the-Journal
    # move {Telemetry::MemoryRoot} makes -- so P5's calibration and any later
    # session recover the closure from the Journal alone.
    # Raised when a `chunk_range` does not land fully within the timeline's
    # turns. An out-of-bounds range would otherwise fold into an attested EMPTY
    # elided span byte-identical to a genuinely-empty chunk, and a negative
    # range would silently reinterpret under slice semantics -- both silent
    # lies about what the chunk actually spanned. Callers pass ABSOLUTE indices.
    class ChunkRangeOutOfBounds < Error; end

    Closure = Data.define(:step_id, :title, :status, :criteria_digest,
                          :passed, :score, :why,
                          :files, :snapshot_scope,
                          :elided_digests, :error_digests, :notes_for_future_steps) do
      include ContentAddressed

      # @param step [Plan::Step] the closed step -- id/title/status/criteria
      # @param timeline [Timeline] the chunk's history; its Store holds every
      #   digest this record names
      # @param chunk_range [Range] integer turn indices into the timeline's
      #   root-first order ({Timeline#to_a}) -- the span this chunk spent
      # @param grade [Grader::Grade] the chunk's verdict
      # @param snapshot [Event, nil] the :snapshot in force at the seam, or nil
      #   before any snapshot landed (files empty, scope note still carried)
      def self.build(step:, timeline:, chunk_range:, grade:, snapshot:)
        turns = chunk_turns(timeline, chunk_range)
        new(step_id: step.id, title: step.title, status: step.status, criteria_digest: step.criteria_digest,
            passed: grade.pass?, score: grade.score, why: grade.why,
            files: snapshot_files(snapshot), snapshot_scope: snapshot_scope(snapshot),
            elided_digests: turns.map(&:digest),
            error_digests: step.failed? ? error_evidence(turns) : [],
            notes_for_future_steps: [])
      end

      # The chunk's turns, root-first. The range is validated against the length
      # BEFORE the slice, so the slice is guaranteed non-nil and a bogus range
      # never becomes a silent empty span (see ChunkRangeOutOfBounds).
      def self.chunk_turns(timeline, chunk_range)
        turns = timeline.to_a
        turns[in_bounds!(chunk_range, turns.length)]
      end
      private_class_method :chunk_turns

      # Refuses any `range` whose endpoints are not absolute (non-negative
      # Integer) positions landing within `0...length`, naming the range and the
      # length. A legitimately empty in-bounds range (e.g. 2..1) is allowed: its
      # endpoints are valid positions, it simply selects nothing. Returns the
      # range unchanged so the caller reads `turns[in_bounds!(range, len)]`.
      def self.in_bounds!(range, length)
        raise ChunkRangeOutOfBounds, absolute_message(range, length) unless absolute?(range)
        raise ChunkRangeOutOfBounds, bounds_message(range, length) unless within?(range, length)

        range
      end
      private_class_method :in_bounds!

      def self.absolute?(range)
        [range.begin, range.end].all? { |index| index.is_a?(Integer) && index >= 0 }
      end
      private_class_method :absolute?

      def self.within?(range, length)
        top = range.exclude_end? ? range.end - 1 : range.end
        range.begin <= length && top < length
      end
      private_class_method :within?

      def self.absolute_message(range, length)
        "chunk_range #{range.inspect} must use absolute non-negative indices " \
          "(the timeline has #{length} turns)"
      end
      private_class_method :absolute_message

      def self.bounds_message(range, length)
        "chunk_range #{range.inspect} does not land within 0...#{length} " \
          "(the timeline has #{length} turns)"
      end
      private_class_method :bounds_message

      def self.snapshot_files(snapshot)
        snapshot ? snapshot.body.fetch("files") : {}
      end
      private_class_method :snapshot_files

      def self.snapshot_scope(snapshot)
        snapshot ? snapshot.body.fetch("snapshot_scope") : Workspace::Snapshot::SCOPE_NOTE
      end
      private_class_method :snapshot_scope

      def self.error_evidence(turns)
        turns.flat_map { |turn| error_blocks(turn) }.map { |block| Canonical.digest(block) }
      end
      private_class_method :error_evidence

      def self.error_blocks(turn)
        Array(turn.content).grep(Hash).select { |block| block["type"] == "tool_result" && block["is_error"] }
      end
      private_class_method :error_blocks

      def initialize(step_id:, title:, status:, criteria_digest:, passed:, score:, why:,
                     files:, snapshot_scope:, elided_digests:, error_digests:, notes_for_future_steps:)
        super(
          step_id: interned(step_id), title: interned(title), status: interned(status),
          criteria_digest: interned(criteria_digest),
          passed: passed ? true : false, score: score.to_f, why: interned(why),
          files: Canonical.normalize(files), snapshot_scope: interned(snapshot_scope),
          elided_digests: freeze_digests(elided_digests),
          error_digests: freeze_digests(error_digests),
          notes_for_future_steps: freeze_digests(notes_for_future_steps)
        )
      end

      # Store-borne AND journal-pointed in one move: put the frozen record into
      # the content-addressed Store, then journal a {Telemetry::ClosureRecord}
      # naming it -- so a later session recovers the closure from the Journal
      # even though the Store did not survive the process.
      #
      # @return [String] the closure's content address
      def record(store:, plan_digest:, journal: Channel::Null::INSTANCE)
        store.put(self)
        journal << Telemetry::ClosureRecord.new(closure_digest: digest, step_id:, plan_digest:,
                                                chunk_turn_digests: elided_digests)
        digest
      end

      def digest
        Canonical.digest(canonical)
      end

      # Plain-hash wire form for {Canonical}; String keys, sorted downstream.
      def canonical
        { "step_id" => step_id, "title" => title, "status" => status, "criteria_digest" => criteria_digest,
          "passed" => passed, "score" => score, "why" => why,
          "files" => files, "snapshot_scope" => snapshot_scope,
          "elided_digests" => elided_digests, "error_digests" => error_digests,
          "notes_for_future_steps" => notes_for_future_steps }
      end

      private

      # A frozen, deduplicated String, or nil preserved -- criteria_digest is
      # optional, and nil is its own value, not the empty string.
      def interned(value)
        value.nil? ? nil : -value.to_s
      end

      def freeze_digests(digests)
        digests.map { |digest| -digest.to_s }.freeze
      end
    end
  end
end
