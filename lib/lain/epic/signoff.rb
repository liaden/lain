# frozen_string_literal: true

module Lain
  module Epic
    # Where each sign-off partition stands, folded from its `gate_decision` records so 2 readers of
    # 1 journal agree by construction. A deny or an approve settles a draft, and a deferral parks it.
    # A hold settles nothing: it waits until a later decision answers its draft, unless that draft
    # already stands approved or is still parked when it comes.
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

      Hold = Data.define(:digest) do
        def onto(ledger) = ledger.held_at(digest)
      end

      # One partition: its moves in order, the drafts still parked in park order, the drafts the
      # standing approval superseded, the drafts held in hold order, and the standing.
      Ledger = Data.define(:moves, :parked, :superseded, :held, :standing) do
        def self.empty = new(moves: [], parked: [], superseded: [], held: [], standing: nil)

        def after(move) = move.onto(with(moves: [*moves, move]))

        def parked_again(digest)
          with(parked: parked.include?(digest) ? parked : [*parked, digest], superseded: superseded - [digest],
               held: held - [digest])
        end

        # Judged when the hold comes, so a later approval of another draft cannot bring it back.
        def held_at(digest)
          answered = parked.include?(digest) || (standing&.verdict&.approved? && standing.digest == digest)
          answered ? self : with(held: held | [digest])
        end

        def settled(digest, verdict)
          drafts = with(parked: parked - [digest], superseded: superseded - [digest], held: held - [digest])
          return drafts.approving(digest, verdict, older_than(digest)) if verdict.approved?
          return drafts if superseded.include?(digest)

          drafts.with(standing: Standing.new(digest:, verdict:))
        end

        def approving(digest, verdict, older)
          with(superseded: superseded | older, standing: Standing.new(digest:, verdict:))
        end

        def older_than(digest) = parked.take_while { _1 != digest }
      end
      private_constant :Park, :Settle, :Hold, :Ledger

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

      # @return [Array<SignoffQueue::Item>] every digest a human held, read through each partition's {GateView}
      def held_items
        state.keys.flat_map do |partition|
          view(partition, current: nil).held.map do |digest|
            SignoffQueue::Item.new(artifact_digest: digest, epic_slug: partition.epic_slug, stage: partition.stage,
                                   issue_id: partition.issue_id)
          end
        end
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
      # @param current [#to_s, nil] the artifact's digest as it stands now; nil where it is gone
      # @return [GateView]
      def view(partition, current:)
        ledger = state.fetch(partition, Ledger.empty)
        GateView.new(partition:, standing: ledger.standing, drafts: ledger.parked, superseded: ledger.superseded,
                     held: ledger.held, current:)
      end

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
        partition = partition(fields)
        self.class.new(state.merge(partition => state.fetch(partition, Ledger.empty).after(move)))
      rescue ArgumentError => e
        raise SignoffQueue::UnreadableRecord.for(fields, e)
      end

      def move_in(fields)
        SignoffQueue::Contracts::Decision.check!(type: fields["type"], stage: fields["stage"],
                                                 policy: fields["policy"])
        verdict = GateDecision.verdict_in(fields)
        digest = fields["artifact_digest"].to_s
        SignoffQueue::Contracts::Item.check!(artifact_digest: digest)
        return Hold.new(digest:) if verdict.held?

        GateDecision.deferred?(verdict) ? Park.new(digest:) : Settle.new(digest:, verdict:)
      end

      def partition(fields)
        SignoffQueue::Partition.new(epic_slug: fields["epic_slug"], stage: fields["stage"],
                                    issue_id: fields["issue_id"])
      end
    end
  end
end
