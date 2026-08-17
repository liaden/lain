# frozen_string_literal: true

module Lain
  module SessionRecord
    # The live session scribe: journals a chat as it runs so the session on disk
    # is loadable at every instant, not only after a clean exit. Attaches to an
    # already-open {Journal} (fsync mode, so a turn is durable before the reply
    # renders) and writes the OPEN header at construction.
    #
    # Two feeds, because two kinds of event reach the record by different paths:
    #
    # * {#catch_up} walks the render chain and appends a `turn` record for every
    #   committed turn not yet written. A Timeline walk sees ONLY render-chain
    #   turns -- that is all it can see -- so that is all this writes.
    # * {#call} is the {Event::ChainWriter} observer duck: :message/:spawn events
    #   never enter any render chain (their causal edges point BACKWARD and the
    #   shared Store has no forward enumerator), so a Timeline walk CANNOT find
    #   them. They arrive here by observation instead, one at a time, as
    #   {Telemetry::Message} records -- a shape the turn-chain loader skips, since
    #   a :message can never survive {Timeline#commit}'s digest re-derivation.
    #   A SPAWNED chain's turns come through this same door, for the same reason
    #   (this record's Timeline walk cannot reach another chain) and land as
    #   {Telemetry::ChildTurn}; the turn-chain loader skips those too. Nothing
    #   about the render chain moves: {#catch_up} still writes exactly the turns
    #   above the append point, and only those are `turn` records. And like
    #   every turn record they stay on the journal rather than the tee -- see
    #   `message_journal:` on {#initialize}.
    #
    # A graceful {#close} anchors the final head; {#interrupted} marks a run that
    # a stop beat. Neither is written on a hard kill, which is precisely what
    # leaves an open session recognizable as open.
    class Scribe
      # A caught-up timeline that does not EXTEND the written chain: rewound, or
      # diverged onto another branch. The record is append-only, so the refusal
      # is write-time loud -- silently appending the diverged tip would produce
      # a file that only fails at load, as {Bench::Session::Corrupt}, far from
      # the bug (panel probe D).
      class Diverged < Error; end

      # What this record has on disk: the turn digests it has written, in chain
      # order, ending at the append point ({#head}). One object because it is
      # one invariant -- *the written digests are an ancestor PREFIX of the
      # chain, so the head is the maximal written ancestor* -- and that
      # invariant was previously hand-maintained across four Scribe methods and
      # seedable inconsistently from outside, which is the shape of a missing
      # object.
      #
      # Mutable on purpose: it tracks a file being appended to, and each move it
      # allows mirrors a record that has already landed.
      #
      # Membership is a linear scan. That is deliberate -- ordered IS the point
      # here. {Scribe#written_target!} asks once per human-driven rewind;
      # {Scribe#recorded_turn?} asks once per observed off-chain turn, which is
      # a spawn's transcript rather than a per-turn cost on the render path.
      class WrittenChain
        def initialize(digests = [])
          @digests = digests.dup
          # Nothing to doubt: an empty seed cannot be out of order or holed.
          @verified = @digests.empty?
        end

        # The append point. nil for a record with no turns yet, which is the
        # honest answer for "append from the empty session".
        def head = @digests.last

        def length = @digests.length

        def include?(digest) = @digests.include?(digest)

        # Has a real chain judged this yet? False only while an unchecked seed
        # is still a claim -- everything this class builds for itself is true by
        # construction, so it starts and stays adjudicated.
        def adjudicated? = @verified

        # One journaled turn, now on disk. The head advances HERE, per turn,
        # rather than once after a batch: a journal that raises mid-catch_up
        # (ENOSPC, EIO) must leave the append point on the last record that
        # actually landed, or the retry -- and there is one, a
        # {Middleware::JournalTurns} failure tears the ask into {CLI::Repl}'s
        # `record_interruption`, which catches up again -- re-writes turns the
        # file already holds. A loader re-committing that file dies as
        # {Bench::Session::Corrupt}, far from the bug.
        def append(digest)
          @digests << digest
          self
        end

        # Drop everything above `to`, an announced rewind's other half. Chain
        # order is insertion order (that is this class's whole claim), so
        # slicing at the target prunes exactly the turns above it.
        def retreat_to(to)
          @digests = to.nil? ? [] : @digests[..@digests.index(to)]
          self
        end

        # Is this really the chain ending at {#head} -- in order, no holes, and
        # nothing unwritten BELOW it?
        #
        # That last clause is why the walk takes one more ancestor than it
        # compares. Matching `length` ancestors below the head proves order and
        # no holes, but a chain SUFFIX passes that too, and a suffix means
        # unwritten turns sit below the head -- so the head is not the maximal
        # written ancestor and the class doc above would be a claim nothing
        # enforces. Demanding the walk RUN OUT at `length` is the whole fix, and
        # it costs one fetch.
        #
        # Only a SEED can be wrong. {#append} extends by a turn the walk just
        # proved is the head's child, and {#retreat_to} keeps a prefix of a
        # prefix, so once true this stays true: hence the memo, and hence the
        # O(length) walk runs at most ONCE per record. Per session, not per
        # ask -- which is the budget the filtered walk this replaced blew.
        #
        # Requires the head to be on `timeline` already; {Scribe} checks that
        # first, and checking out a digest the store lacks would raise the
        # wrong error.
        def prefix_of?(timeline)
          return true if @verified

          walked = timeline.checkout(head).ancestors.take(length + 1)
          @verified = walked.length == length && walked.map(&:digest).reverse == @digests
        end
      end

      # @param journal [#<<] the open session Journal (fsync for durability)
      # @param context [Lain::Context] the context this session renders under
      # @param toolset [#to_schema] the toolset in effect
      # @param workspace [Lain::Workspace] the workspace in effect
      # @param resumed_from [Hash, nil] `{"file" =>, "head" =>}` naming the
      #   prior file this session chains to (T19); header-only, absent when nil
      # @param written [Array<String>] the resumed chain's already-recorded
      #   turn digests, in chain order (root first). Seeding them matters:
      #   they live in the PRIOR file, so catch_up must not re-record them
      #   (that would double every turn a chain loader folds in), and the
      #   extends-check must anchor on the resumed head, not nil. The ORDER is
      #   part of the claim and {WrittenChain} checks it -- see there.
      # @param message_journal [#<<, nil] where {#call}'s message records land
      #   -- the telemetry tee under --nvim (I6), so the live inbox surfaces
      #   (lain://inbox, {StatusFeed}) fold the same Q/A records the file
      #   holds. ROUTED, not duplicated: the tee's journal leg IS `journal`,
      #   so the file still gets each record exactly once. Defaults to the
      #   journal itself; turn records never route -- they are record data,
      #   not live-view telemetry -- and that holds for the {Telemetry::ChildTurn}
      #   records {#call} promotes as much as for {#catch_up}'s own.
      def initialize(journal:, context:, toolset:, workspace: Workspace.empty, resumed_from: nil, written: [],
                     message_journal: nil)
        @journal = journal
        @message_journal = message_journal || journal
        @written = WrittenChain.new(written)
        # The digests {#child_turn} has already recorded. A Set, and membership
        # is the only question asked of it -- unlike {WrittenChain}, where the
        # ORDER is the claim.
        @spawned = Set.new
        @journal << SessionRecord.header(context:, toolset:, workspace:, head: nil, resumed_from:)
      end

      # The {Event::ChainWriter} observer duck: journal an off-render-chain
      # event as its own flat record. A raise here propagates back through the
      # ChainWriter AFTER the Store write has landed (the seam's pinned
      # contract), so a scribe failure is loud, never silent record loss.
      #
      # @param event [Lain::Event]
      # @return [self]
      def call(event)
        event.kind == :turn ? child_turn(event) : message(event)
        self
      end

      # Append a `turn` record for every render-chain turn above the last one
      # written. Idempotent across calls: a caught-up timeline yields nothing, so
      # calling it once per ask writes only that ask's new turns, in root-to-head
      # order. The timeline must EXTEND the written chain -- see {Diverged}.
      #
      # Walk, then both refusals, then write: nothing lands until the timeline
      # and the seed have both been judged, so a refused catch_up leaves the
      # file unchanged past its last good record.
      #
      # @param timeline [Lain::Timeline]
      # @return [self]
      # @raise [Diverged] for a rewound or diverged timeline, or a seed that was
      #   never the chain it claimed to be; nothing is written
      def catch_up(timeline)
        fresh = turns_above_append_point(timeline)
        extends_written_chain!(timeline, fresh)
        written_chain_is_a_prefix!(timeline)
        fresh.each do |turn|
          @journal << SessionRecord.turn(turn)
          @written.append(turn.digest)
        end
        self
      end

      # T15: the ONE sanctioned backward move. Announces a rewind as its own
      # `rewound` record, then retreats the append point so the next
      # {#catch_up} extends from `to` -- the {Diverged} raise keeps guarding
      # every divergence NOT announced through here.
      #
      # The written chain retreats WITH the append point, because it is what
      # {#written_target!} judges a later rewind against: a target ABOVE the
      # append point is a forward move wearing a rewind's name, and only a
      # pruned chain refuses it. That a rewind-and-retry which re-commits
      # identical content -- an identical DIGEST -- still re-lands after this
      # record is {#turns_above_append_point}'s doing: it stops at the append
      # point, never at "some digest already written". Checked BEFORE anything
      # lands, like {#catch_up}.
      #
      # @param to [String, nil] a turn digest this record already wrote
      #   (nil rewinds to the empty session)
      # @return [self]
      # @raise [Diverged] for a target never written; nothing is written
      def rewound(to:)
        written_target!(to)
        @journal << SessionRecord.rewound(from: @written.head, to:)
        @written.retreat_to(to)
        self
      end

      # Graceful close: anchor the final head and the reason. `head:` defaults to
      # the last head {#catch_up} saw, so a caller that caught up first need not
      # repeat it.
      #
      # Deliberately does NOT demand an adjudicated seed, unlike {#rewound}.
      # `lain chat --resume` then quit-without-asking reaches here with the seed
      # still a claim, and refusing would turn a clean quit into a crash --
      # inside chat's `ensure`, where it would also mask whatever error was
      # already unwinding. Nothing is risked by allowing it: this record wrote
      # no turns, so the anchor is the resume's own claim about the PRIOR file
      # and no turn record hangs off it.
      #
      # @param reason [Symbol] one of {Telemetry::SessionClosed::REASONS}
      # @param head [String, nil] the final head anchor
      # @return [self]
      def close(reason:, head: @written.head)
        @journal << Telemetry::SessionClosed.new(head:, reason:)
        self
      end

      # Mark a run stopped before its response committed. `head:` names the last
      # committed turn the interrupted run was generating from. Unguarded for
      # the reason {#close} gives.
      #
      # @param head [String, nil]
      # @return [self]
      def interrupted(head: @written.head)
        @journal << Telemetry::RunInterrupted.new(head:)
        self
      end

      private

      # A :message or :spawn, onto the message journal -- the tee under --nvim,
      # so the live inbox surfaces fold the same Q/A records the file holds.
      def message(event)
        @message_journal << Telemetry::Message.from_event(event)
      end

      # A SPAWNED chain's turn, and the two things that are not obvious about it.
      #
      # It lands on `@journal`, never the tee. Turn records are RECORD DATA, not
      # live-view telemetry -- the invariant #initialize's `message_journal:`
      # note states -- and it is what keeps a {StatusFeed}, whose observe is
      # duck-typed on `#kind`, from retiring an inbox question because a
      # subagent committed a turn. Changing that live surface is a decision for
      # whoever owns the gap `status_feed.rb` records, not a side effect here.
      #
      # And it is written ONCE per digest. Content addressing means equal turns
      # are ONE event, not two, so a record already holding this digest holds
      # this turn: a `:fresh` child seeded with the text the human opened with
      # commits literally the parent's root turn, and a fan-out of siblings on
      # one prompt at temperature 0 commits identical transcripts -- which would
      # otherwise write the whole child transcript once per sibling, multiplying
      # the term that already dominates a spawn-heavy file. Nothing is lost by
      # skipping: {Bench::Session::ChainFold} or an earlier record lands the turn
      # either way, and every citation of the digest resolves.
      #
      # REFUSING a repeat instead was considered and is wrong. There are not two
      # events to tell apart, so no predicate could separate "a spawn collided"
      # from "the observer is mis-wired" -- and since `@written` is empty at the
      # first iteration, such a raise could only ever fire on a LATER spawn,
      # making it contingent on which iteration the model chose to delegate on.
      def child_turn(event)
        return if recorded_turn?(event.digest)

        @journal << Telemetry::ChildTurn.from_event(event)
        @spawned << event.digest
      end

      def recorded_turn?(digest) = @written.include?(digest) || @spawned.include?(digest)

      # The turns above the append point, root-to-head: {Timeline#ancestors}
      # walked head-first and stopped AT the append point, so a catch_up reads
      # the new turns and one more. Filtering a full walk instead cost O(n) per
      # ask -- O(n^2) over a session, on the durability path every ask waits on.
      #
      # Bounded only where there IS an append point, and that is the honest
      # claim: an un-seeded first catch_up has none, so it walks to the root
      # once, and a refusal walks the whole chain before {#extends_written_chain!}
      # turns it down. Both are per session, not per ask.
      #
      # Stopping at the append point rather than at any already-written digest
      # is what keeps {#rewound} correct: a rewind-and-retry that re-commits
      # identical content yields an identical DIGEST, and that turn has to
      # re-land after the `rewound` record, which a stop-at-anything-written
      # walk would eat.
      def turns_above_append_point(timeline)
        timeline.ancestors.take_while { |turn| turn.digest != @written.head }.reverse
      end

      # The append point must BE the last-written head: the first fresh turn's
      # render parent, or -- with nothing new -- the timeline's own head.
      #
      # This is also half of what the walk above depends on. An append point
      # that is not on the walked chain sends the take-while off the root, so
      # `fresh` is the whole chain and its root's nil parent cannot equal a
      # non-nil append point: the mismatch below IS that assertion failing,
      # loudly, instead of turns journaled under a wrong parent. The other half
      # -- that the written chain is a PREFIX and not merely on-chain -- is
      # {WrittenChain#prefix_of?}, checked next.
      def extends_written_chain!(timeline, fresh)
        anchor = fresh.empty? ? timeline.head_digest : fresh.first.parent
        return if anchor == @written.head

        raise Diverged, "timeline #{timeline.head_digest.inspect} does not extend the written chain " \
                        "(last-written head #{@written.head.inspect}); the session record appends, never rewrites"
      end

      # Runs AFTER {#extends_written_chain!}, which is what makes the append
      # point safe to check out here.
      def written_chain_is_a_prefix!(timeline)
        return if @written.prefix_of?(timeline)

        raise Diverged, "the written chain is not a prefix of timeline #{timeline.head_digest.inspect} " \
                        "(#{@written.length} digests ending at #{@written.head.inspect}); a `written:` seed " \
                        "must be the prior file's turns in chain order, root first"
      end

      def written_target!(to)
        adjudicated_seed!
        return if to.nil? || @written.include?(to)

        raise Diverged, "rewind target #{to.inspect} was never written to this record; " \
                        "a rewound record can only name a recorded turn"
      end

      # Only {#catch_up} carries a timeline, so it is the only move that can
      # adjudicate a seed -- which leaves {#rewound} announcing a backward move
      # whose `from:` comes from the unchecked seed, and retreating the chain,
      # both before any catch_up could turn it down. Call order prevents that
      # today ({CLI::Command::Rewind} catches up first, so does the {CLI::Repl}),
      # but call order is a convention, and an unvalidated `written:` seed was a
      # convention too -- which is how this card found it.
      #
      # {#close} and {#interrupted} are deliberately NOT guarded; see #close.
      def adjudicated_seed!
        return if @written.adjudicated?

        raise Diverged, "the `written:` seed was never checked against a timeline; #catch_up is what " \
                        "adjudicates it, and until it has, this record cannot speak for a head of its own"
      end
    end
  end
end
