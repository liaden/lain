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
    # `(epic_slug, stage)` are required for one reason: {Epic::Stage}'s
    # boundary rule asks whether an EARLIER stage of THIS epic is drained, so a
    # global drain would let one epic's parked research block another's plan.
    #
    # `issue_id` is the third member, nil for the epic-wide stages, and the
    # same argument one level down: an issue's plan is that issue's work, so
    # one issue's parked plan must not hold a sibling's implementation shut.
    # A question naming no issue is answered for EVERY issue, and an item
    # naming none is seen by every issue's question -- both the conservative
    # reading, so nothing that could not name its issue ever opens a gate.
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

      # How a human answering from `lain epic queue` reaches a verdict: no
      # configurable policy, so no {Gate::Policies} row names it, and it is
      # terminal here like every policy but {DEFERRED_POLICY}.
      SIGNOFF_POLICY = "signoff"

      # The record type the fold reads (Journalable's discriminator for
      # {Approval::GateDecision}).
      JOURNAL_TYPE = "gate_decision"

      # The closed set a journaled `policy` is read against: every configurable
      # gate policy, plus the human sign-off this queue is the queue for.
      # DERIVED from {Gate::Policies}, never restated, so a policy added there
      # is in this set without a second edit that could be missed.
      #
      # @return [Array<String>] every configurable policy, and the human sign-off
      def self.policies = [*Gate::Policies.names, SIGNOFF_POLICY]

      # A journaled record the fold could not read as a decision. Named, and a
      # {Lain::Error}, because the carriers below refuse with ArgumentError --
      # right for a caller that built the value wrong, a backtrace for a human
      # whose journal holds a damaged line.
      #
      # {Approval::Gate.from_journal} folds the same record type and refuses it
      # through {.for} too, so one damaged line reads the same whichever fold
      # reaches it first.
      class UnreadableRecord < Error
        include RefusedBeforeActing
        include JournalUnreadable

        # @param record [Hash{String=>Object}] the damaged journal record
        # @param cause [ArgumentError] the carrier's refusal of it
        # @return [UnreadableRecord] one line, naming the record by digest and partition
        def self.for(record, cause)
          address = record.values_at("epic_slug", "stage", "issue_id").compact.join("/")
          new("the #{JOURNAL_TYPE} record for #{record["artifact_digest"].inspect} in #{address.inspect} cannot " \
              "be read (#{cause.message}) -- repair the line or move its session file aside; nothing was decided")
        end
      end

      # SignoffQueue's OWN construction contracts, not {Approval::Contracts}.
      module Contracts
        # An empty partition key is worse than a wrong one: it still constructs,
        # still folds, and can never be matched back by the epic and stage a
        # boundary check asks about. Refused where it is built.
        class Partition < Declarative::Carrier
          attribute :epic_slug
          attribute :stage
          attribute :issue_id
          validates :epic_slug, presence: { message: "must name the epic this sign-off belongs to, got nil" }
          validates :stage, presence: { message: "must name the stage it was parked at, got nil" }
          validates :issue_id, presence: { message: "must name the issue when it names one at all, got a blank id" },
                               allow_nil: true
        end

        # A parked sign-off is an ADDRESS waiting to be answered; without the
        # digest there is nothing to answer about.
        class Item < Declarative::Carrier
          attribute :artifact_digest
          validates :artifact_digest, presence: { message: "must name the artifact awaiting sign-off, got nil" }
        end

        # What {SignoffQueue#apply} demands before it will act on a record.
        #
        # `policy` is what the fold BRANCHES on: a missing or misspelt one is
        # not `deferred`, so it fell to the terminal side and drained a sign-off
        # nobody answered. `stage` outside the pipeline parks where no boundary
        # asks. Both read as drained, so both are CLOSED sets -- checked here at
        # the fold, never on the write-side carrier, which builds test stages
        # freely. `type` is checked because the public live path gets none of
        # {.from_journal}'s filtering.
        #
        # Refusing is the only answer safe in BOTH directions: skipping a record
        # loses a deferral as quietly as misreading one drains a parked item.
        # `approved` is a TRUNCATION CANARY -- no producible record trips it,
        # and a truncation that took it could as well have taken `policy`.
        class Decision < Declarative::Carrier
          # Read when a record is refused, never at load: both sets belong to
          # units that load after this one.
          STAGES = ->(*) { Lain::Epic::STAGES }
          POLICIES = ->(*) { SignoffQueue.policies }
          private_constant :STAGES, :POLICIES

          def self.one_of(set, reason = "") = ->(*) { "must be one of #{set.call.join(", ")}#{reason}, got %<value>p" }
          private_class_method :one_of

          attribute :type
          attribute :stage
          attribute :policy
          attribute :approved
          validates :type, inclusion: { in: [JOURNAL_TYPE],
                                        message: "must be #{JOURNAL_TYPE.inspect} for the sign-off fold, " \
                                                 "got %<value>s" }
          validates :stage, inclusion: { in: STAGES, message: one_of(STAGES) }
          validates :policy, inclusion: { in: POLICIES,
                                          message: one_of(POLICIES, " -- the fold branches on it and will not guess") }
          validates :approved, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        end
      end

      # An issue id as it arrives off a record: nil for an epic-wide stage,
      # otherwise the issue's name as text. Anything else is a damaged line,
      # refused BEFORE `to_s` -- a stringified Array names an issue nobody has,
      # parks where no issue's question looks, and reads as drained for every
      # real one. {Approval::GateDecision} reads its own through this too.
      module IssueId
        def self.read(value)
          return value if value.nil?
          raise ArgumentError, "issue_id must be text naming the issue, got #{value.inspect}" unless value.is_a?(String)

          -value
        end
      end

      # The three-member key {#drained?}, {#parked} and {Epic::Stage}'s boundary
      # rule all share -- named because three call sites passing the same triple
      # around is an object, and because `policy` is a different axis that must
      # never be folded into it.
      Partition = Data.define(:epic_slug, :stage, :issue_id) do
        def initialize(epic_slug:, stage:, issue_id: nil)
          # Interned before the guard, so `presence:` judges the bytes that get
          # COMPARED: a stage whose #to_s is blank passes a presence check on
          # the raw object and then keys a partition nothing can match.
          epic_slug = -epic_slug.to_s
          stage = -stage.to_s
          issue_id = IssueId.read(issue_id)
          Contracts::Partition.check!(epic_slug:, stage:, issue_id:)

          super
        end

        # Whether a question asked of this partition must see what is parked
        # in `other`. A nil issue on EITHER side overlaps every issue -- the
        # class header's conservative reading.
        def overlaps?(other)
          epic_slug == other.epic_slug && stage == other.stage &&
            (issue_id.nil? || other.issue_id.nil? || issue_id == other.issue_id)
        end

        def to_s = [epic_slug, stage, issue_id].compact.join("/")
      end

      # One artifact awaiting a human's sign-off.
      #
      # `question` is NULLABLE on purpose: {Approval::GateDecision}'s wire shape
      # is closed, so a rebuilt item has no question to recover. Not a loss --
      # the digest addresses the artifact and the artifact owns its question, so
      # storing prose in the decision record would duplicate what
      # content-addressing already guarantees.
      #
      # `evidence_digest` and `criteria_digest` ARE recoverable, because the
      # decision record carries them -- so a later sign-off can carry the
      # criteria the parked plan was submitted with.
      Item = Data.define(:artifact_digest, :epic_slug, :stage, :issue_id, :question, :evidence_digest,
                         :criteria_digest) do
        def initialize(artifact_digest:, epic_slug:, stage:, issue_id: nil, question: nil, evidence_digest: nil,
                       criteria_digest: nil)
          # Stringified BEFORE the guard, and before this becomes half of the
          # queue's key: {#drain} reconstructs that key through `to_s`, so an
          # Item holding the raw object would park under an address drain could
          # never rebuild -- the item unwedgeable, its partition never opening
          # again.
          artifact_digest = artifact_digest.to_s
          Contracts::Item.check!(artifact_digest:)
          partition = Partition.new(epic_slug:, stage:, issue_id:)

          # Every member settled into frozen bytes, prose included: deep
          # immutability cannot be conditional on what a caller passed, and one
          # object with a mutable ivar would make the whole value
          # non-`Ractor.shareable?`.
          super(artifact_digest: artifact_digest.dup.freeze, epic_slug: partition.epic_slug,
                stage: partition.stage, issue_id: partition.issue_id, question: frozen_text(question),
                evidence_digest: frozen_text(evidence_digest), criteria_digest: frozen_text(criteria_digest))
        end

        # Derived rather than stored: the members ARE the partition, and a
        # second copy could disagree with the first.
        def partition = Partition.new(epic_slug:, stage:, issue_id:)

        private

        # nil stays nil -- "nothing was carried" is a value here.
        # Dup'd-and-frozen rather than interned: prose is not a repeated key.
        def frozen_text(value) = value && value.to_s.dup.freeze
      end

      def initialize
        # Indexed {Partition} => digest => {Item}, so a drain finds its item
        # without a scan. A QUESTION scans the partition keys -- never the
        # items -- because a question naming no issue must see every issue's
        # partition. Both levels are insertion-ordered, so parking one gate
        # twice is one sign-off and enumeration reads oldest-first -- the order
        # a morning review wants.
        @parked = {}
        # {Partition} => the digest its newest terminal verdict approved.
        @approved = {}
      end

      # Idempotent on `(artifact_digest, epic_slug, stage, issue_id)`: an
      # artifact deferred twice is still one thing to sign off, and an EDITED
      # artifact hashes differently, so it parks as the separate decision it is.
      #
      # @param artifact_digest [#to_s] the artifact awaiting sign-off
      # @param epic_slug [#to_s] the epic it belongs to
      # @param stage [#to_s] the stage it was parked at
      # @param issue_id [String, nil] the issue, for an issue-scoped stage
      # @param question [#to_s, nil] the gate's question, for the review surface
      # @param evidence_digest [#to_s, nil] the evidence gathered, if any
      # @param criteria_digest [#to_s, nil] the criteria a parked plan carries
      # @return [Item] the item now parked
      def park(artifact_digest:, epic_slug:, stage:, issue_id: nil, question: nil, evidence_digest: nil,
               criteria_digest: nil)
        item = Item.new(artifact_digest:, epic_slug:, stage:, issue_id:, question:, evidence_digest:,
                        criteria_digest:)
        (@parked[item.partition] ||= {})[item.artifact_digest] = item
      end

      # Remove a parked sign-off by address -- what a terminal decision does to
      # the live view of the fold. The address is EXACT, issue included: a
      # decision drains only the partition it was made in.
      #
      # @return [Item, nil] the item that was holding, or nil if none was
      def drain(artifact_digest:, epic_slug:, stage:, issue_id: nil)
        artifact_digest = artifact_digest.to_s
        Contracts::Item.check!(artifact_digest:)

        partition = Partition.new(epic_slug:, stage:, issue_id:)
        # Deleting from an absent partition is a no-op, so a throwaway Hash
        # nobody keeps is enough here.
        items = @parked.fetch(partition, {})
        drained = items.delete(artifact_digest)
        # The emptied partition goes too. Every read is correct over a leftover
        # empty one, so the only symptom would be a key space growing for the
        # life of the process -- and an epic run spans days.
        @parked.delete(partition) if items.empty?
        drained
      end

      # Whether nothing awaits sign-off where this question reaches -- the
      # question {Epic::Stage}'s boundary rule asks of every earlier stage.
      #
      # @param epic_slug [#to_s] the epic asked about
      # @param stage [#to_s] the stage asked about
      # @param issue_id [String, nil] one issue's partition; nil asks for every issue's
      def drained?(epic_slug, stage, issue_id: nil) = parked(epic_slug, stage, issue_id:).empty?

      # Whether the NEWEST terminal decision folded for exactly this partition
      # approved -- the positive evidence {Epic::Stage}'s boundary rule asks
      # for beside {#drained?}, which a partition nothing ever wrote to also
      # answers true. The newest, so a denied resubmission withdraws what its
      # first draft's approval vouched for; a deferral is no verdict and moves
      # nothing here. Exact, never overlapping: an approval of one issue's plan
      # is no evidence about a sibling's, and a question naming no issue is
      # answered only by an approval that named none. Only {#apply} records a
      # verdict, because one exists only as a journaled decision.
      #
      # @param epic_slug [#to_s] the epic asked about
      # @param stage [#to_s] the stage asked about
      # @param issue_id [String, nil] the issue, for an issue-scoped stage
      def approved?(epic_slug, stage, issue_id: nil) = @approved.key?(Partition.new(epic_slug:, stage:, issue_id:))

      # Whether that newest approving verdict was of exactly these bytes -- what
      # "already approved" means to a submit and to an issue's plan check, so
      # neither calls a digest approved while the boundary calls its stage not.
      #
      # @param artifact_digest [#to_s] the artifact as it stands now
      # @param epic_slug [#to_s] the epic asked about
      # @param stage [#to_s] the stage asked about
      # @param issue_id [String, nil] the issue, for an issue-scoped stage
      def standing?(artifact_digest, epic_slug, stage, issue_id: nil)
        @approved[Partition.new(epic_slug:, stage:, issue_id:)] == artifact_digest.to_s
      end

      # The items this question reaches, for a review surface that shows one
      # stage of one epic at a time.
      #
      # @param epic_slug [#to_s] the epic asked about
      # @param stage [#to_s] the stage asked about
      # @param issue_id [String, nil] one issue's partition; nil asks for every issue's
      # @return [Array<Item>]
      def parked(epic_slug, stage, issue_id: nil)
        asked = Partition.new(epic_slug:, stage:, issue_id:)
        @parked.select { |partition, _| asked.overlaps?(partition) }.flat_map { |_, items| items.values }
      end

      # Everything parked, oldest first within each partition.
      def each(&block)
        return to_enum(:each) unless block

        @parked.each_value { |items| items.each_value(&block) }
        self
      end

      # Rebuild from journaled decisions: the definition of "parked", executed.
      #
      # The fold is where a record becomes a decision, so it is where a
      # record's refusal becomes the reader's: {#apply} keeps its ArgumentError
      # for a live caller, and a journal gets one line naming the record.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records; foreign
      #   lines are skipped by {Journal.records}, as every reader here does
      # @raise [UnreadableRecord] naming the record and the field it lacks
      def self.from_journal(entries)
        Journal.records(entries, type: JOURNAL_TYPE).each_with_object(new) do |record, queue|
          queue.apply(record)
        rescue ArgumentError => e
          raise UnreadableRecord.for(record, e)
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
        Contracts::Decision.check!(type: decision["type"], stage: decision["stage"], policy: decision["policy"],
                                   approved: decision["approved"])
        deferred?(decision) ? park(**parked_attributes(decision)) : settle(decision)
        self
      end

      private

      def settle(decision)
        address = address_attributes(decision)
        drain(**address)
        partition = Partition.new(**address.except(:artifact_digest))
        decision["approved"] ? @approved[partition] = -address[:artifact_digest].to_s : @approved.delete(partition)
      end

      def deferred?(decision) = decision["policy"].to_s == DEFERRED_POLICY

      # A record written before decisions named their issue has no key at all,
      # which reads as nil -- the epic-wide reading, which is what it was.
      def address_attributes(decision)
        { artifact_digest: decision["artifact_digest"], epic_slug: decision["epic_slug"],
          stage: decision["stage"], issue_id: decision["issue_id"] }
      end

      def parked_attributes(decision)
        address_attributes(decision).merge(evidence_digest: decision["evidence_digest"],
                                           criteria_digest: decision["criteria_digest"])
      end
    end
  end
end
