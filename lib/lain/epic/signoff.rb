# frozen_string_literal: true

module Lain
  module Epic
    # Where each sign-off partition stands, folded from its `gate_decision` records so 2 readers of
    # 1 journal agree by construction. A deny or an approve settles a draft, and a deferral parks it.
    # A hold settles nothing.
    #
    # A deny of a draft that was parked before the approved one does not withdraw the approval:
    # clearing an old queue item must not stall the epic. Whether a deny is that stale one depends on
    # the order drafts were parked in, so each partition keeps its moves as well as where they
    # leave it, and {#combine} replays the newer half's moves on the older half's ledger.
    class Signoff < Journal::Projection
      # @!attribute [r] digest
      #   @return [String] the artifact the verdict was over
      # @!attribute [r] verdict
      #   @return [Approval::Verdict::Approve, Approval::Verdict::Deny]
      Standing = Data.define(:digest, :verdict)

      Park = Data.define(:digest) do
        def onto(ledger) = ledger.parked_again(digest)
      end

      Settle = Data.define(:digest, :verdict) do
        def onto(ledger) = ledger.settled(digest, verdict)
      end

      # One partition: its moves in order, the drafts still parked in park order, the drafts the
      # standing approval superseded, and the standing.
      Ledger = Data.define(:moves, :parked, :superseded, :standing) do
        def self.empty = new(moves: [], parked: [], superseded: [], standing: nil)

        def after(move) = move.onto(with(moves: [*moves, move]))

        def parked_again(digest)
          with(parked: parked.include?(digest) ? parked : [*parked, digest], superseded: superseded - [digest])
        end

        def settled(digest, verdict)
          drafts = with(parked: parked - [digest], superseded: superseded - [digest])
          return drafts.approving(digest, verdict, older_than(digest)) if verdict.approved?
          return drafts if superseded.include?(digest)

          drafts.with(standing: Standing.new(digest:, verdict:))
        end

        def approving(digest, verdict, older)
          with(superseded: superseded | older, standing: Standing.new(digest:, verdict:))
        end

        def older_than(digest) = parked.take_while { _1 != digest }
      end
      private_constant :Park, :Settle, :Ledger

      # @return [Signoff]
      def self.unit = new({})

      # @param entries [Enumerable<Hash, String>] journal lines or parsed records
      # @return [Signoff]
      # @raise [SignoffQueue::UnreadableRecord] for a gate_decision it cannot read
      def self.from_journal(entries)
        over(Journal.records(entries, type: SignoffQueue::JOURNAL_TYPE).map do |record|
          Telemetry::Untyped.new(fields: Journal.payload_of(record))
        end)
      end

      # @param record [Telemetry::Journalable, Telemetry::Untyped]
      # @return [Signoff] self for a record that moves nothing
      # @raise [TypeError] for anything that is not a record, such as a Hash or a journal line
      # @raise [SignoffQueue::UnreadableRecord] for a gate_decision it cannot read
      def step(record)
        fields = fields_of(record)
        return self unless fields["type"] == SignoffQueue::JOURNAL_TYPE

        moved(fields)
      end

      # @param other [Signoff]
      # @return [Signoff] each partition as the newer half's moves leave the older half's ledger
      def combine(other)
        self.class.new(state.merge(other.state) { |_, mine, theirs| theirs.moves.inject(mine, &:after) })
      end

      # @param partition [SignoffQueue::Partition]
      # @return [Standing, nil] nil where no decision has settled the partition
      def standing(partition) = state[partition]&.standing

      # @param partition [SignoffQueue::Partition]
      # @param digest [#to_s] the artifact as it stands now
      # @return [Boolean] whether the partition's standing approval is of exactly these bytes
      def approved?(partition, digest)
        standing = standing(partition)
        !standing.nil? && standing.verdict.approved? && standing.digest == digest.to_s
      end

      private

      def fields_of(record)
        case record
        when Telemetry::Untyped then record.fields
        when GateDecision then record.to_journal
        when Telemetry::Journalable then {}
        else raise TypeError, "#{self.class} steps journal records, got a #{record.class}"
        end
      end

      def moved(fields)
        move = move_in(fields)
        return self if move.nil?

        partition = partition(fields)
        self.class.new(state.merge(partition => state.fetch(partition, Ledger.empty).after(move)))
      rescue ArgumentError => e
        raise SignoffQueue::UnreadableRecord.for(fields, e)
      end

      def move_in(fields)
        SignoffQueue::Contracts::Decision.check!(type: fields["type"], stage: fields["stage"],
                                                 policy: fields["policy"])
        verdict = GateDecision.verdict_in(fields)
        return if verdict.held?

        digest = fields["artifact_digest"].to_s
        SignoffQueue::Contracts::Item.check!(artifact_digest: digest)
        fields["policy"] == SignoffQueue::DEFERRED_POLICY ? Park.new(digest:) : Settle.new(digest:, verdict:)
      end

      def partition(fields)
        SignoffQueue::Partition.new(epic_slug: fields["epic_slug"], stage: fields["stage"],
                                    issue_id: fields["issue_id"])
      end
    end
  end
end
