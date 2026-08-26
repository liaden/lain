# frozen_string_literal: true

module Lain
  module Approval
    # The artifact gates a {Gate::Policy::Deferred} refused and parked for a
    # human to sign off later.
    #
    # == It is a fold, not a file
    #
    # An item is parked exactly when a `gate_decision` under the `deferred`
    # policy has no LATER terminal decision for the same
    # `(artifact_digest, epic_slug, stage)`. {.from_journal} replays that
    # definition, so a session that dies loses no sign-off and two readers of
    # one journal agree by construction.
    #
    # A deferral therefore journals FIRST and parks second. The invariant that
    # buys is ONE-DIRECTIONAL: nothing is ever parked without a journaled
    # deferral behind it, so the live queue never opens a boundary the record
    # would have kept shut. It can be MORE conservative than the fold -- this is
    # a plain unsynchronized Hash and {Gate#call} awaits between the journal
    # write and the park, so two tasks over one address can interleave such that
    # a park lands after a terminal decision the fold would have drained on.
    # That direction refuses where the fold would have opened, the SAFE
    # direction, so it is documented rather than locked.
    #
    # == It is NOT {Approval::Queue}
    #
    # That class is effect-scoped: it parks ONE tool call and BLOCKS the calling
    # fiber until a surface decides it. Nothing blocks here -- a deferred gate
    # returns at once, having refused -- and what is held is an artifact
    # ADDRESS, not an in-flight effect.
    #
    # == The partition
    #
    # Both members of `(epic_slug, stage)` are required for one reason:
    # {Epic::Stage}'s boundary rule asks whether an EARLIER stage of THIS epic
    # is drained, so a global drain would let one epic's parked research block
    # another's plan.
    class SignoffQueue
      include Enumerable

      # It lives here rather than on the policy because the FOLD is what
      # depends on the string; {Gate::Policy::Deferred::NAME} reads it back, so
      # the two can never drift.
      #
      # `policy` and not `answered_by`: policy names HOW a verdict was reached,
      # exactly the axis "parked" versus "settled" lies on. A later human
      # sign-off journals `policy: "signoff"` with a real surface, and is
      # terminal here.
      DEFERRED_POLICY = "deferred"

      # The record type the fold reads (Journalable's discriminator for
      # {Approval::GateDecision}).
      JOURNAL_TYPE = "gate_decision"

      # SignoffQueue's OWN construction contracts, not {Approval::Contracts}.
      module Contracts
        # An empty partition key is worse than a wrong one: it still constructs,
        # still folds, and can never be matched back by the epic and stage a
        # boundary check asks about. Refused where it is built.
        class Partition < Declarative::Carrier
          attribute :epic_slug
          attribute :stage
          validates :epic_slug, presence: { message: "must name the epic this sign-off belongs to, got nil" }
          validates :stage, presence: { message: "must name the stage it was parked at, got nil" }
        end

        # A parked sign-off is an ADDRESS waiting to be answered; without the
        # digest there is nothing to answer about.
        class Item < Declarative::Carrier
          attribute :artifact_digest
          validates :artifact_digest, presence: { message: "must name the artifact awaiting sign-off, got nil" }
        end

        # What {SignoffQueue#apply} demands before it will act on a record.
        #
        # `policy` is the field the fold BRANCHES on, and it was the one field
        # nothing checked: a record missing it fell to the TERMINAL side and
        # drained a sign-off nobody answered, after which the partition reads
        # drained and {Epic::Stage#ensure_open!} opens the next stage over
        # unreviewed work. `type` is checked for the same reason one step out --
        # {.from_journal} filters on it, but the live one-record-at-a-time path
        # is public and gets no such filter.
        #
        # Refusing is the only answer safe in BOTH directions: skipping an
        # unreadable record loses a DEFERRAL just as quietly as misreading one
        # drains a parked item, and a lost deferral also reads as drained.
        #
        # `approved` is a TRUNCATION CANARY. No producible record is ever
        # rejected by that clause -- the only thing it catches is a line damaged
        # or hand-made -- and a truncation that took `approved` could equally
        # have taken `policy`, so a record missing either cannot be trusted
        # about the other.
        class Decision < Declarative::Carrier
          attribute :type
          attribute :policy
          attribute :approved
          validates :type, inclusion: { in: [JOURNAL_TYPE],
                                        message: "must be #{JOURNAL_TYPE.inspect} for the sign-off fold, " \
                                                 "got %<value>s" }
          validates :policy, presence: { message: "must name how the verdict was reached -- the fold branches " \
                                                  "on it and will not guess, got nil" }
          validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        end
      end

      # The two-member key {#drained?}, {#parked} and {Epic::Stage}'s boundary
      # rule all share -- named because three call sites passing the same pair
      # around is an object, and because `policy` is a different axis that must
      # never be folded into it.
      Partition = Data.define(:epic_slug, :stage) do
        def initialize(epic_slug:, stage:)
          # Interned before the guard, so `presence:` judges the bytes that get
          # COMPARED: a stage whose #to_s is blank passes a presence check on
          # the raw object and then keys a partition nothing can match.
          epic_slug = -epic_slug.to_s
          stage = -stage.to_s
          Contracts::Partition.check!(epic_slug:, stage:)

          super
        end

        def to_s = "#{epic_slug}/#{stage}"
      end

      # One artifact awaiting a human's sign-off.
      #
      # `question` is NULLABLE on purpose: {Approval::GateDecision}'s wire shape
      # is closed, so a rebuilt item has no question to recover. Not a loss --
      # the digest addresses the artifact and the artifact owns its question, so
      # storing prose in the decision record would duplicate what
      # content-addressing already guarantees.
      #
      # `evidence_digest` IS recoverable, because the decision record carries it.
      Item = Data.define(:artifact_digest, :epic_slug, :stage, :question, :evidence_digest) do
        def initialize(artifact_digest:, epic_slug:, stage:, question: nil, evidence_digest: nil)
          # Stringified BEFORE the guard, and before this becomes half of the
          # queue's key: {#drain} reconstructs that key through `to_s`, so an
          # Item holding the raw object would park under an address drain could
          # never rebuild -- the item unwedgeable, its partition never opening
          # again.
          artifact_digest = artifact_digest.to_s
          Contracts::Item.check!(artifact_digest:)
          partition = Partition.new(epic_slug:, stage:)

          # Every member settled into frozen bytes, prose included: deep
          # immutability cannot be conditional on what a caller passed, and one
          # object with a mutable ivar would make the whole value
          # non-`Ractor.shareable?`.
          super(artifact_digest: artifact_digest.dup.freeze, epic_slug: partition.epic_slug,
                stage: partition.stage, question: frozen_text(question),
                evidence_digest: frozen_text(evidence_digest))
        end

        # Derived rather than stored: the members ARE the partition, and a
        # second copy could disagree with the first.
        def partition = Partition.new(epic_slug:, stage:)

        private

        # nil stays nil -- "nothing was carried" is a value here.
        # Dup'd-and-frozen rather than interned: prose is not a repeated key.
        def frozen_text(value) = value && value.to_s.dup.freeze
      end

      # No partition holds anything until something parks in one.
      NOTHING = {}.freeze

      def initialize
        # Indexed the way it is read: {Partition} => digest => {Item}. Every
        # query this class answers names a PARTITION, so a flat map would scan
        # the whole queue and rebuild a Partition per item per call. Both levels
        # are insertion-ordered, so parking one gate twice is one sign-off and
        # enumeration reads oldest-first -- the order a morning review wants.
        @parked = {}
      end

      # Idempotent on `(artifact_digest, epic_slug, stage)`: an artifact
      # deferred twice is still one thing to sign off, and an EDITED artifact
      # hashes differently, so it parks as the separate decision it is.
      #
      # @return [Item] the item now parked
      def park(artifact_digest:, epic_slug:, stage:, question: nil, evidence_digest: nil)
        item = Item.new(artifact_digest:, epic_slug:, stage:, question:, evidence_digest:)
        (@parked[item.partition] ||= {})[item.artifact_digest] = item
      end

      # Remove a parked sign-off by address -- what a terminal decision does to
      # the live view of the fold.
      #
      # @return [Item, nil] the item that was holding, or nil if none was
      def drain(artifact_digest:, epic_slug:, stage:)
        artifact_digest = artifact_digest.to_s
        Contracts::Item.check!(artifact_digest:)

        partition = Partition.new(epic_slug:, stage:)
        # A throwaway Hash rather than the frozen {NOTHING} the read paths get:
        # deleting from an absent partition is a no-op on a hash nobody keeps.
        items = @parked.fetch(partition, {})
        drained = items.delete(artifact_digest)
        # The emptied partition goes too. Every read is correct over a leftover
        # empty one, so the only symptom would be a key space growing for the
        # life of the process -- and an epic run spans days.
        @parked.delete(partition) if items.empty?
        drained
      end

      # Whether nothing awaits sign-off in this `(epic_slug, stage)` partition --
      # the question {Epic::Stage}'s boundary rule asks of every earlier stage.
      def drained?(epic_slug, stage) = items_in(Partition.new(epic_slug:, stage:)).empty?

      # The items in one partition, for a review surface that shows one stage of
      # one epic at a time.
      def parked(epic_slug, stage) = items_in(Partition.new(epic_slug:, stage:)).values

      # Everything parked, oldest first within each partition.
      def each(&block)
        return to_enum(:each) unless block

        @parked.each_value { |items| items.each_value(&block) }
        self
      end

      # Rebuild from journaled decisions: the definition of "parked", executed.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records; foreign
      #   lines are skipped by {Journal.records}, as every reader here does
      def self.from_journal(entries)
        Journal.records(entries, type: JOURNAL_TYPE).each_with_object(new) do |record, queue|
          queue.apply(record)
        end
      end

      # A deferral parks; anything else is terminal and drains the address it
      # answers -- a DENIAL included, since a refused artifact is not awaiting
      # anyone's sign-off either.
      #
      # PUBLIC, and therefore guarded on its own rather than trusting
      # {.from_journal}'s type filter: this is the seam a live session folds its
      # own decisions through, reachable with any Hash at all. Both ways of
      # getting it wrong are unsafe -- misreading one drains a sign-off nobody
      # answered, skipping one loses a deferral just as quietly. Fail closed
      # means the fold REFUSES, not that it guesses.
      #
      # @param decision [Hash{String=>Object}] one journaled record
      # @return [self]
      # @raise [ArgumentError] naming the field that made the record unreadable
      def apply(decision)
        Contracts::Decision.check!(type: decision["type"], policy: decision["policy"],
                                   approved: decision["approved"])
        deferred?(decision) ? park(**parked_attributes(decision)) : drain(**address_attributes(decision))
        self
      end

      private

      def deferred?(decision) = decision["policy"].to_s == DEFERRED_POLICY

      def items_in(partition) = @parked.fetch(partition, NOTHING)

      def address_attributes(decision)
        { artifact_digest: decision["artifact_digest"], epic_slug: decision["epic_slug"],
          stage: decision["stage"] }
      end

      def parked_attributes(decision)
        address_attributes(decision).merge(evidence_digest: decision["evidence_digest"])
      end
    end
  end
end
