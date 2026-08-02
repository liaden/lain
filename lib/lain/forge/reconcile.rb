# frozen_string_literal: true

module Lain
  module Forge
    # An intent whose params do not carry the address the world would have to be
    # asked about. Raised where the lookup fails and caught one level out, where
    # the intent is named in {Reconcile::Report#unaddressable}: the fold must
    # never fold this to "not done" (scheduling a retry over an effect that may
    # already have landed is the double-push this tier exists to prevent), and
    # it must never cost the report everything else it knows.
    class Unobservable < Error; end

    # An action nothing here knows how to observe. Unreachable while
    # {Guards::Intent} closes {ACTIONS} to what {Reconcile::Observer} handles --
    # it is the canary for a later card widening one of those and not the other.
    class UnknownAction < Error; end

    # What a journal says happened, joined against what the world says is true.
    #
    # == The pairing law
    #
    # An outcome settles the FIRST unmatched intent carrying its intent_id, in
    # journal order. That is not a tiebreak, it is the whole rule: an intent_id
    # addresses an action-and-params pair ({Intent}), so a second attempt at the
    # same action reuses the id, and pairing by id alone would let one outcome
    # answer both attempts. Positional pairing makes "promoted the same sha
    # twice, heard back once" read as one settled attempt and one still in
    # flight, which is what it is.
    #
    # An outcome that answers no unmatched intent is an ORPHAN: named, never
    # dropped. It means the journal is missing an intent that must have existed
    # -- a truncated file, or a writer that got the ordering backwards -- and
    # silently discarding it would hide precisely that.
    #
    # The pass is single and forward, so an outcome recorded BEFORE its own
    # intent orphans while that intent stays unsettled: both halves of a settled
    # pair are in the file and nothing pairs them. That is corruption, not a
    # race, and reporting it as two unrelated facts would bury it -- so
    # {Report#misordered} names the ids appearing on both sides. A caller seeing
    # a non-empty one must not simply retry the unsettled intent; the action may
    # well have been acknowledged already.
    #
    # == The world is asked, never remembered
    #
    # For every unsettled intent the injected `world` is asked whether the
    # effect is already in place; the verdict is {COMPLETED_EXTERNALLY} or
    # {NEEDS_RETRY}. Nothing is inferred from the journal alone, because the
    # journal's last word before a crash is by definition "we were about to" --
    # the `Handback#preserve` and `Salvage#already_committed?` doctrine that
    # idempotency is a property of the remote, observed each time.
    #
    # The `world` duck, in full (T24 implements it over the gh executor):
    #
    #   #ref_exists?(ref)  -> Boolean
    #   #sha_of(ref)       -> String, the sha the ref stands at
    #   #pr_state(number)  -> String, GitHub's OPEN / CLOSED / MERGED
    #   #pr_for(head:)     -> the PR opened from that head ref, or nil
    #
    # == It is a pure function of the two, as far as the world allows
    #
    # Same entries and same world, same report -- {Report} is a value, so that
    # claim is `==` and a spec pins it. Like {SessionRecord::Salvage}, this class
    # touches no file and opens no socket: it reads the ducks it was handed and
    # answers. Deciding what to DO about a `needs_retry` belongs to the caller
    # that owns the run.
    #
    # What that does NOT promise, and cannot: the world is a remote nobody can
    # hold still. A push landing between two of this fold's questions changes
    # the answer, and two runs over one journal can differ with nothing wrong
    # anywhere. {Observer} memoizes per intent_id, so the fold is at least
    # internally consistent about repeats of ONE action -- it never reports two
    # verdicts for one question -- but a promote still costs a `ref_exists?` and
    # a `sha_of` that are not atomic with each other.
    class Reconcile
      # The two verdicts, spelled out as constants and closed by a guard rather
      # than reached through `method_missing` on a String: the premise here is
      # that an unknown value fails loudly, and a typo'd `.completed_externaly?`
      # must not answer false in silence (CLAUDE.md's rejection of
      # StringInquirer, same reason -- which is why {Unsettled} refuses a
      # verdict outside this set instead of building one that answers false to
      # both predicates).
      COMPLETED_EXTERNALLY = "completed_externally"
      NEEDS_RETRY = "needs_retry"
      VERDICTS = [COMPLETED_EXTERNALLY, NEEDS_RETRY].freeze

      # GitHub's terminal PR state, compared case-insensitively because `gh`
      # answers it upcased and a hand-written fixture rarely does.
      MERGED_STATE = "merged"

      # This class's own construction contract, in the house validate-then-freeze
      # convention. Named {Guards} like {Forge::Guards} and shadowing it inside
      # this lexical scope, which is harmless because nothing here reaches for
      # the record guards directly -- {Intent.from_record} owns that.
      module Guards
        # A verdict must be one of the two this fold can reach. See {VERDICTS}.
        class Verdict < Guard
          attribute :verdict
          validates :verdict, inclusion: { in: VERDICTS,
                                           message: "must be one of #{VERDICTS.join("/")}, got %<value>s" }
        end
      end

      # An intent and the outcome that answered it. Both are carried because a
      # settled step's outcome holds what the next step needs -- the PR number a
      # merge will name -- and re-deriving it from the world would be a second
      # question with a different answer.
      Settled = Data.define(:intent, :outcome)

      # An intent with no outcome, plus the world's word on whether its effect
      # nonetheless landed.
      Unsettled = Data.define(:intent, :verdict) do
        def initialize(intent:, verdict:)
          verdict = -verdict.to_s
          Guards::Verdict.check!(verdict:)

          super
        end

        def completed_externally? = verdict == COMPLETED_EXTERNALLY

        def needs_retry? = verdict == NEEDS_RETRY

        def unaddressable? = false
      end

      # An intent the world could not be asked about at all, and why.
      #
      # Named beside the verdicts rather than folded into them: a third verdict
      # would answer false to both predicates and so read as "do nothing", which
      # is the one response a record this broken must not get. A caller with a
      # non-empty {Report#unaddressable} has a params bug in whatever journaled
      # the intent, and it can only be escalated to a human.
      Unaddressable = Data.define(:intent, :reason) do
        def initialize(intent:, reason:)
          super(intent:, reason: reason.to_s.dup.freeze)
        end

        def unaddressable? = true
      end

      # The whole answer as one frozen value, so "reconcile twice, get the same
      # report" is plain `==` and a caller has one thing to pass along.
      #
      # Four members, but TWO partitions rather than one four-way split, and
      # reading it as the latter is the mistake this note exists to prevent:
      #
      #   over the INTENTS   settled | unsettled | unaddressable   ({#outstanding} is the last two)
      #   over the OUTCOMES  settled | orphans
      #
      # `settled` is the member both partitions share, which is why it is the
      # only one that pairs the two records together.
      Report = Data.define(:settled, :unsettled, :orphans, :unaddressable) do
        # Copied before freezing, so the caller keeps ownership of the arrays it
        # passed; frozen because `Data` freezes the instance and `Array#freeze`
        # is shallow, and this value is only `Ractor.shareable?` if every member
        # is itself deeply frozen.
        def initialize(settled:, unsettled:, orphans:, unaddressable:)
          super(settled: settled.dup.freeze, unsettled: unsettled.dup.freeze,
                orphans: orphans.dup.freeze, unaddressable: unaddressable.dup.freeze)
        end

        # Every intent still waiting for an outcome, whether or not the world
        # could be asked about it. The one question a resuming caller actually
        # has, and the reason the intent-side partition is named above: an
        # unaddressable intent is no less outstanding for being unjudgeable,
        # and a caller unioning the two lists by hand is a caller who will
        # eventually forget one.
        #
        # @return [Array<Unsettled, Unaddressable>]
        def outstanding = unsettled + unaddressable

        # The intent_ids reported BOTH as outstanding and as orphaned -- an
        # outcome that arrived before its own intent (see the class comment).
        # Derived rather than stored, so it cannot disagree with the lists it is
        # a statement about.
        #
        # Over {#outstanding}, not over `unsettled` alone: an intent that is
        # blind AND misordered is corrupt twice over, and the narrower range
        # silently cleared it.
        #
        # @return [Array<String>]
        def misordered = outstanding.map { |item| item.intent.intent_id }.uniq & orphans.map(&:intent_id)
      end

      # Positional pairing, in one pass over the journal.
      #
      # Held apart from {Reconcile} because it is a mutable index built to
      # answer a question, and one ivar of it would cost the report its
      # shareability -- {Epic::Progress}'s Lineage/Refold split, same reason.
      #
      # `seq` rides along because an outcome can land far from the intent it
      # settles, and both lists read best in the order the WORK was attempted:
      # a resuming caller wants the first unsettled step, not the first one
      # whose id happened to be seen first.
      class Pairing
        Placed = Data.define(:seq, :value)
        private_constant :Placed

        def initialize(entries)
          @unmatched = {}
          @settled = []
          @orphans = []
          Journal.records(entries).each_with_index { |record, seq| absorb(record, seq) }
        end

        def settled = ordered(@settled)

        def unsettled = ordered(@unmatched.values.flatten(1))

        def orphans = ordered(@orphans)

        private

        def ordered(placed) = placed.sort_by(&:seq).map(&:value)

        # A line of some other tier's is not ours to read -- {Journal.records}'
        # skip-what-you-do-not-recognize contract, since a session journal's fd
        # is shared. Our OWN records are a different matter: {Intent.from_record}
        # and {Outcome.from_record} re-check the write-side guards, so a
        # malformed forge record aborts the fold rather than vanishing from it.
        # Skipping one would lose exactly the intent nobody would then retry.
        def absorb(record, seq)
          case record["type"].to_s
          when Intent::JOURNAL_TYPE then open_intent(record, seq)
          when Outcome::JOURNAL_TYPE then close_intent(record, seq)
          end
        end

        def open_intent(record, seq)
          intent = Intent.from_record(record)
          (@unmatched[intent.intent_id] ||= []) << Placed.new(seq:, value: intent)
        end

        # `fetch` with a throwaway empty Array rather than `@unmatched[id]` over
        # a default proc: reading the index must not WRITE to it, and under a
        # default proc every orphan left an empty bucket behind in the very
        # structure this one-pass fold depends on. A frozen shared constant
        # cannot stand in here -- `Array#shift` raises FrozenError even on an
        # empty frozen Array -- so the throwaway is the honest empty queue.
        #
        # The settled pair inherits the INTENT's position, so it sorts where the
        # work was attempted rather than where the ack arrived.
        def close_intent(record, seq)
          outcome = Outcome.from_record(record)
          waiting = @unmatched.fetch(outcome.intent_id, []).shift
          if waiting.nil?
            @orphans << Placed.new(seq:, value: outcome)
          else
            @settled << Placed.new(seq: waiting.seq, value: Settled.new(intent: waiting.value, outcome:))
          end
        end
      end
      private_constant :Pairing

      # Asks the world whether an unsettled intent's effect is already in place.
      #
      # One question per action, and each is the CHEAPEST address that survives
      # a crash: a promote is a ref standing at a sha, a merge is a PR number's
      # state. A pr_create is the awkward one -- the number is what the call
      # would have RETURNED, so a crash leaves nothing to look it up by, and the
      # head ref it was opened from is the only address that exists on both
      # sides.
      class Observer
        # A memoized answer, restamped onto each intent that asked for it. Two
        # shapes rather than one nullable one, so the fold picks a list by
        # sending a message instead of testing a type.
        #
        # `#about` rather than `#judge`: judging is asking the world, which
        # happens once per question, and this is the cheap stamping that happens
        # once per intent. One name for both made the delegation read as a loop.
        Answer = Data.define(:verdict) do
          def about(intent) = Unsettled.new(intent:, verdict:)
        end
        private_constant :Answer

        Blocked = Data.define(:reason) do
          def about(intent) = Unaddressable.new(intent:, reason:)
        end
        private_constant :Blocked

        def initialize(world)
          @world = world
          @answers = {}
        end

        # Memoized on the QUESTION -- the action and the params every question
        # below is built from -- so three repeats of one promote cost one
        # `ref_exists?` rather than three subprocesses against a remote that can
        # change under them mid-fold.
        #
        # Deliberately NOT on intent_id, even though the id is that same digest
        # on the write path. {Intent.from_record} keeps the STORED id, which is
        # correct (the pairing joins on it) and means that on the read path --
        # the only path this fold has -- an id is whatever the journal says
        # rather than a fact about the question. Two records sharing an id and
        # naming different actions would then share one answer, and an OPEN pull
        # request would be reported as already merged. The pair below is exact,
        # already frozen, and cannot drift from what is actually asked.
        #
        # The ANSWER is memoized and the intent restamped onto it, never the
        # {Unsettled} itself -- two intents can pose one question and differ in
        # epic_slug (see {Intent.id_for}), and a cached value would report the
        # first one's slug for the second.
        def judge(intent)
          (@answers[[intent.action, intent.params]] ||= ask(intent)).about(intent)
        end

        private

        def ask(intent)
          Answer.new(verdict: happened?(intent) ? COMPLETED_EXTERNALLY : NEEDS_RETRY)
        rescue Unobservable => e
          Blocked.new(reason: e.message)
        end

        def happened?(intent)
          case intent.action
          when PROMOTE then promoted?(intent)
          when PR_CREATE then opened?(intent)
          when PR_MERGE then merged?(intent)
          else raise UnknownAction, "no way to observe a #{intent.action.inspect} intent"
          end
        end

        # BOTH addresses are bound before the world is consulted. Inlining the
        # sha lookup into the `&&` lets it short-circuit past that fetch, so the
        # same malformed record reads as a hard error when the ref exists and as
        # a quiet `needs_retry` when it does not -- an unreadable intent judged
        # by the state of GitHub. It is unreadable either way.
        #
        # A ref standing at some OTHER sha is `needs_retry`, and it is not this
        # class's business to say more: the retry runs through the real
        # promotion, which refuses a diverged remote loudly and never forces.
        def promoted?(intent)
          ref = address(intent, "ref")
          sha = address(intent, "sha")
          @world.ref_exists?(ref) && @world.sha_of(ref).to_s == sha.to_s
        end

        def opened?(intent) = !@world.pr_for(head: address(intent, "head")).nil?

        def merged?(intent) = @world.pr_state(address(intent, "number")).to_s.casecmp?(MERGED_STATE)

        # An address is a non-blank String or a number, and nothing else.
        #
        # A missing key is the obvious case, but it is the least of them:
        # `fetch` succeeds on a nil, and every comparison above ends in `.to_s`,
        # so an intent carrying `"sha" => nil` against a world whose `sha_of`
        # answers nil compares "" to "" and reports the push as confirmed --
        # two absences of knowledge denoted as a confirmation. Booleans are the
        # same bug one type over and slip past a blankness test, since
        # `false.to_s` is a perfectly good String; `Canonical.normalize`
        # preserves both, so nothing upstream filters them out.
        #
        # Stating what an address IS rather than enumerating what it is not is
        # what keeps the next type from being a third round of this.
        # {Guards::Outcome} refuses a missing `ok` on exactly this reasoning; an
        # address owes the same rule.
        def address(intent, key)
          value = intent.params.fetch(key) { raise Unobservable, unaddressed(intent, key, "carries no") }
          raise Unobservable, unaddressed(intent, key, "carries an unusable address in") unless addressable?(value)

          value
        end

        def addressable?(value)
          case value
          when Numeric then true
          when String then !value.strip.empty?
          else false
          end
        end

        def unaddressed(intent, key, fault)
          "a #{intent.action} intent #{fault} params[#{key.inspect}] -- the world cannot be asked whether " \
            "it already happened (intent #{intent.intent_id})"
        end
      end
      private_constant :Observer

      # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck --
      #   journal records or raw NDJSON lines, in file order
      # @param world [#ref_exists?, #sha_of, #pr_state, #pr_for] the observation
      #   seam documented on this class
      def initialize(entries:, world:)
        pairing = Pairing.new(entries)
        observer = Observer.new(world)
        # Partitioned on a message, not a type. An intent the world could not be
        # asked about must neither disappear into a verdict nor take the rest of
        # the report down with it: a resume with one malformed line still has to
        # be able to say what landed.
        unaddressable, unsettled = pairing.unsettled.map { |intent| observer.judge(intent) }
                                                    .partition(&:unaddressable?)
        @report = Report.new(settled: pairing.settled, orphans: pairing.orphans, unsettled:, unaddressable:)
      end

      # @return [Report]
      attr_reader :report

      # @return [Array<Settled>] intents answered by an outcome, in the order
      #   they were attempted
      def settled = report.settled

      # @return [Array<Unsettled>] intents with no outcome, each carrying the
      #   world's verdict
      def unsettled = report.unsettled

      # @return [Array<Outcome>] outcomes answering no unmatched intent
      def orphans = report.orphans

      # @return [Array<Unaddressable>] intents whose params could not address
      #   the effect, so no verdict was reachable
      def unaddressable = report.unaddressable

      # @return [Array<Unsettled, Unaddressable>] every intent with no outcome
      def outstanding = report.outstanding

      # @return [Array<String>] intent_ids reported both outstanding and orphaned
      def misordered = report.misordered
    end
  end
end

# Loaded last: {World} is the observer this class asks, and it reaches for
# {Promotion::Remote} at construction, so the class body above -- and the
# sibling it borrows -- must exist before it is read. The subtree index owns
# its own children (CLAUDE.md, Requires); `forge.rb` names the unit, not the
# unit's insides.
require_relative "reconcile/world"
