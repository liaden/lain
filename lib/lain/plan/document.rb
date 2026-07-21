# frozen_string_literal: true

module Lain
  # A plan as a deeply frozen value: an ordered list of {Step}s with author-
  # placed SEAMS between adjacent steps. A seam is a chunk boundary -- the steps
  # between two seams are one chunk of work, closed and summarized together
  # (PC-2). Removing a seam merges the two chunks it separated; that is the whole
  # point of seams being author-editable.
  #
  # Sent-not-stored through the {Workspace} like {Arm::LedgerState}: #to_reminder
  # is the live working view the model reads each turn, and every mutation
  # (#advance, #insert_seam, #remove_seam) returns a NEW value rather than
  # touching the old one -- so `Ractor.shareable?` stays true and a fork/replay
  # over the same plan renders byte-identical prompts. #to_markdown is the
  # author-editable artifact (visible seams and sizes) and round-trips back
  # through .parse_markdown to the same #digest -- that round-trip IS the
  # author-review loop. Content-addressed by #digest so the {Store} can hold it
  # and it survives a fork (Session deliberately never carries a plan; see
  # session.rb).
  module Plan
    # A status shown as a one-char mark inside the markdown checkbox, and the
    # exact inverse used to read it back -- one map, both directions, so render
    # and parse cannot drift.
    STATUS_MARKS = { "pending" => " ", "active" => "~", "done" => "x", "failed" => "!" }.freeze
    MARK_STATUSES = STATUS_MARKS.invert.freeze

    # The markdown vocabulary. A seam is a horizontal rule; a step is a task-list
    # item carrying its id in backticks, its S/M/L size in parens, and an
    # optional `{criteria_digest}`. Defined at module scope (not inside the
    # Data.define block, where constants would land on the module anyway -- the
    # documented trap) so parse_markdown reads them by plain lexical lookup.
    SEAM_LINE = "---"
    STEP_LINE = /\A- \[(?<mark>.)\] `(?<id>[^`]+)` \((?<size>[SML])\) (?<title>.*?)(?: \{(?<criteria>[^}]+)\})?\z/

    class UnknownStep < Error; end

    # The ordered steps plus the set of seam boundaries. `seams` names the ids of
    # the steps AFTER which a seam sits; it is normalized to step order with
    # last-step entries (which bound nothing) dropped, so two documents with the
    # same steps and the same boundary set are value-equal and share a #digest
    # regardless of how the seams were built.
    Document = Data.define(:steps, :seams) do
      include Enumerable

      # Parse the author-editable markdown back to a value. Prose, headings, and
      # blank lines around the plan are ignored; a `---` records a seam after the
      # most recent step. The one mutable thing here, held to this method.
      def self.parse_markdown(source)
        steps = []
        seams = []
        source.to_s.each_line do |raw|
          line = raw.rstrip
          if line == SEAM_LINE then seams << steps.last.id unless steps.empty?
          elsif (match = STEP_LINE.match(line)) then steps << step_from(match)
          end
        end
        new(steps:, seams:)
      end

      def self.step_from(match)
        Step.new(id: match[:id], title: match[:title], size: match[:size],
                 status: MARK_STATUSES.fetch(match[:mark]), criteria_digest: match[:criteria])
      end
      private_class_method :step_from

      def initialize(steps:, seams: [])
        # Copy before freezing: the caller keeps ownership of the array it passed,
        # while our member stays immutable. `seams` is built fresh below, so only
        # `steps` needs the dup.
        steps = steps.dup.freeze
        wanted = seams.map(&:to_s)
        ordered = steps[0...-1].map(&:id).select { |id| wanted.include?(id) }.uniq.freeze
        super(steps:, seams: ordered)
      end

      def each(&block)
        steps.each(&block)
      end

      # The steps grouped into chunks: a new chunk begins after every seamed
      # step. `slice_when` splits between `before` and `after` exactly where a
      # seam follows `before`.
      def chunks
        steps.slice_when { |before, _after| seam?(before.id) }.to_a
      end

      def seam?(step_id)
        seams.include?(step_id)
      end

      # Record a step's status. Returns a NEW document; nothing mutates.
      def advance(step_id, status:)
        index = step_index(step_id)
        self.class.new(steps: steps.each_index.map { |i| i == index ? steps[i].with_status(status) : steps[i] },
                       seams:)
      end

      def insert_seam(after:)
        after = after.to_s
        ensure_boundary!(after)
        self.class.new(steps:, seams: seams + [after])
      end

      def remove_seam(after:)
        after = after.to_s
        raise UnknownStep, "no seam after step #{after.inspect}" unless seam?(after)

        self.class.new(steps:, seams: seams - [after])
      end

      def digest
        Canonical.digest(canonical)
      end

      def canonical
        { "steps" => steps.map(&:canonical), "seams" => seams }
      end

      # The live working view carried on the Workspace tail: chunks and each
      # step's status as flat text. The structured truth stays in this value
      # (Store-borne by #digest); the reminder is only the model's read-out, so
      # its being a plain String costs no downstream structure.
      def to_reminder
        ["Plan (#{steps.size} steps, #{chunks.size} chunks)", *chunk_reminders].join("\n")
      end

      # The author-editable artifact: chunks of step lines separated by visible
      # `---` seams. Round-trips through .parse_markdown to the same #digest.
      def to_markdown
        body = chunks.map { |chunk| chunk.map { |step| step_line(step) }.join("\n") }.join("\n\n#{SEAM_LINE}\n\n")
        ["## Plan", body].reject(&:empty?).join("\n\n")
      end

      private

      def step_index(step_id)
        steps.index { |step| step.id == step_id } or raise UnknownStep, "no step #{step_id.inspect} in plan"
      end

      def ensure_boundary!(step_id)
        raise UnknownStep, "no step #{step_id.inspect} in plan" unless steps.any? { |step| step.id == step_id }
        raise ArgumentError, "cannot seam after the last step #{step_id.inspect}" if steps.last&.id == step_id
      end

      def chunk_reminders
        chunks.each_with_index.flat_map do |chunk, i|
          ["Chunk #{i + 1}", *chunk.map { |step| "  #{reminder_line(step)}" }]
        end
      end

      def reminder_line(step)
        criteria = step.criteria_digest ? " [criteria #{step.criteria_digest}]" : ""
        "[#{STATUS_MARKS.fetch(step.status)}] #{step.id} (#{step.size}) #{step.title} -- #{step.status}#{criteria}"
      end

      def step_line(step)
        criteria = step.criteria_digest ? " {#{step.criteria_digest}}" : ""
        "- [#{STATUS_MARKS.fetch(step.status)}] `#{step.id}` (#{step.size}) #{step.title}#{criteria}"
      end
    end
  end
end
