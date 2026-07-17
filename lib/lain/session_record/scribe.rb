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

      # @param journal [#<<] the open session Journal (fsync for durability)
      # @param context [Lain::Context] the context this session renders under
      # @param toolset [#to_schema] the toolset in effect
      # @param workspace [Lain::Workspace] the workspace in effect
      # @param resumed_from [Hash, nil] `{"file" =>, "head" =>}` naming the
      #   prior file this session chains to (T19); header-only, absent when nil
      # @param written [Array<String>] the resumed chain's already-recorded
      #   turn digests. Seeding them is load-bearing: they live in the PRIOR
      #   file, so catch_up must skip them (re-recording the whole chain here
      #   would double every turn a chain loader folds in), and the
      #   extends-check must anchor on the resumed head, not nil.
      # @param message_journal [#<<, nil] where {#call}'s message records land
      #   -- the telemetry tee under --nvim (I6), so the live inbox surfaces
      #   (lain://inbox, {StatusFeed}) fold the same Q/A records the file
      #   holds. ROUTED, not duplicated: the tee's journal leg IS `journal`,
      #   so the file still gets each record exactly once. Defaults to the
      #   journal itself; turn records never route -- they are record data,
      #   not live-view telemetry.
      def initialize(journal:, context:, toolset:, workspace: Workspace.empty, resumed_from: nil, written: [],
                     message_journal: nil)
        @journal = journal
        @message_journal = message_journal || journal
        @written = Set.new(written)
        @head = written.last
        @journal << SessionRecord.header(context:, toolset:, workspace:, head: nil, resumed_from:)
      end

      # The {Event::ChainWriter} observer duck: journal a :message/:spawn event
      # as its own {Telemetry::Message} record. A raise here propagates back
      # through the ChainWriter AFTER the Store write has landed (the seam's
      # pinned contract), so a scribe failure is loud, never silent record loss.
      #
      # @param event [Lain::Event]
      # @return [self]
      def call(event)
        @message_journal << Telemetry::Message.from_event(event)
        self
      end

      # Append a `turn` record for every render-chain turn above the last one
      # written. Idempotent across calls: already-written turns are skipped, so
      # calling it once per ask writes only that ask's new turns, in root-to-head
      # order. The timeline must EXTEND the written chain -- see {Diverged}.
      #
      # @param timeline [Lain::Timeline]
      # @return [self]
      # @raise [Diverged] for a rewound or diverged timeline; nothing is written
      def catch_up(timeline)
        fresh = timeline.to_a.reject { |turn| @written.include?(turn.digest) }
        extends_written_chain!(timeline, fresh)
        fresh.each do |turn|
          @journal << SessionRecord.turn(turn)
          @written.add(turn.digest)
        end
        @head = timeline.head_digest
        self
      end

      # Graceful close: anchor the final head and the reason. `head:` defaults to
      # the last head {#catch_up} saw, so a caller that caught up first need not
      # repeat it.
      #
      # @param reason [Symbol] one of {Telemetry::SessionClosed::REASONS}
      # @param head [String, nil] the final head anchor
      # @return [self]
      def close(reason:, head: @head)
        @journal << Telemetry::SessionClosed.new(head:, reason:)
        self
      end

      # Mark a run stopped before its response committed. `head:` names the last
      # committed turn the interrupted run was generating from.
      #
      # @param head [String, nil]
      # @return [self]
      def interrupted(head: @head)
        @journal << Telemetry::RunInterrupted.new(head:)
        self
      end

      private

      # The append point must BE the last-written head: the first fresh turn's
      # render parent, or -- with nothing new -- the timeline's own head. Checked
      # BEFORE anything lands, so a refused catch_up leaves the file unchanged
      # past the last good record.
      def extends_written_chain!(timeline, fresh)
        anchor = fresh.empty? ? timeline.head_digest : fresh.first.parent
        return if anchor == @head

        raise Diverged, "timeline #{timeline.head_digest.inspect} does not extend the written chain " \
                        "(last-written head #{@head.inspect}); the session record appends, never rewrites"
      end
    end
  end
end
