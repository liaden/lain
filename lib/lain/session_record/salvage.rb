# frozen_string_literal: true

module Lain
  module SessionRecord
    # Recovers a paid-for-but-uncommitted response from the response WAL when a
    # session resumes open. {Middleware::JournalRequests} journals a
    # `request_sent` BEFORE the round trip dispatches, and {Agent#commit_and_account}
    # commits the Timeline turn and then writes its `turn` record and its
    # `turn_usage`, in that order, with no stop landing between -- so a process
    # that dies before the turn record has already spent real tokens the session
    # record alone cannot show, and only the {Provider::ResponseWal} might still
    # hold the bytes.
    #
    # == Finding the target
    #
    # The candidate is the session's LAST `request_sent`, but only when nothing
    # SUPERSEDES it later in the file. An assistant `turn` record after it is
    # proof the response was committed -- the first such proof the agent writes,
    # so a kill before its `turn_usage` still has it -- and so is a `turn_usage`.
    # A `rewound` after it is the user explicitly abandoning that branch --
    # committing the "recovered" response onto the post-rewind head would
    # silently reverse the rewind. Either way: {Nothing}, a clean no-op.
    #
    # The one assistant turn that proves nothing is this class's own recovery,
    # which {CLI::Resume::Salvager} writes after its `salvaged` record: a crash
    # before the closing anchor re-resumes onto {#already_committed?} instead.
    #
    # == Frame selection
    #
    # A request can retry at the transport level and {Provider::ResponseWal}
    # rotates a fresh frame per attempt, so several frames can share one request
    # digest -- only the LAST one is real. It is recovered only when it is
    # complete; otherwise it (however torn, or absent entirely) is surfaced as a
    # reviewable {Incomplete} artifact rather than guessed into a commit.
    #
    # An older complete frame followed by an incomplete one is NOT recovered.
    # The render is pure, so a prompt re-asked over the head a rewind restored
    # has the digest the answered one had, and its complete frame is still in
    # the log. When the later round trip failed -- and the ask withdrew its
    # prompt -- that old answer would commit onto a head no longer holding the
    # question.
    #
    # == The prompt the crash lost
    #
    # A prompt's turn record lands only with its answer's, so a kill mid-stream
    # leaves the prompt nowhere but the request_sent payload's tail message.
    # The tail is rebuilt unless the head already holds it; the messages ahead
    # of it may be derived (a handoff document, a compaction summary) and are
    # not turns, except the cancellation a resume commits in memory over a
    # stranded call. The cache breakpoint, the workspace blocks and a folded
    # mailbox note are removed because none was ever part of a turn; the
    # answer's link to that note is not in the payload and is not rebuilt.
    #
    # == Reassembly, and an answer it cannot find
    #
    # The frame is rebuilt by {Provider::Reassembly}, with the decoder of the
    # provider whose wire the frame header names, so a recovered {Response} is
    # what the original call would have produced. A complete frame that
    # reassembles to no content, or cannot be decoded at all, is {Unreadable},
    # never a recovery: an empty assistant turn committed as "recovered" hides
    # the loss it reports.
    #
    # == What this class does not do
    #
    # It never touches a file and never opens a socket: {#call} is a pure
    # function of the four ducks it is handed, and a {Recovered} commits onto
    # the Timeline it was GIVEN, handing the caller a NEW one. Writing that back
    # to disk is {CLI::Resume}'s job.
    class Salvage
      REQUEST_SENT_TYPE = "request_sent"
      TURN_USAGE_TYPE = "turn_usage"
      SALVAGED_TYPE = "salvaged"
      # Record types that, appearing AFTER a request_sent, prove its round
      # trip is settled history rather than a salvage target (see "Finding
      # the target" above). A turn record only when it is an assistant's.
      SUPERSEDING_TYPES = [TURN_USAGE_TYPE, REWOUND_TYPE, TURN_TYPE].freeze
      RELEVANT_TYPES = [REQUEST_SENT_TYPE, *SUPERSEDING_TYPES].freeze

      # Nothing needed recovering. A Null Object (CLAUDE.md's `Sink::Null`
      # idiom) so a caller never has to branch on "did anything happen"
      # before asking for a notice.
      Nothing = Data.define do
        def notice = nil
        def recovered? = false
        def closes_file? = false
      end.new

      # A complete frame, reassembled -- and, ordinarily, freshly committed.
      # `timeline` carries the recovered turn as its head either way;
      # `response` is the {Lain::Response} the reassembly produced, kept
      # alongside so a caller can inspect usage/stop_reason without
      # re-deriving them from the committed content.
      #
      # `newly_committed` is false for the re-resume case (see
      # {#already_committed?}): the given Timeline already ended with this
      # exact content, so `timeline` is the SAME value handed to {Salvage.new}
      # -- no second commit -- and a caller (`CLI::Resume::Salvager`) knows to
      # write only the missing `session_closed` anchor, not a duplicate
      # `salvaged`/`turn` pair.
      #
      # `corruption` is nil unless a mis-slotted region was skipped to reach
      # this frame (a legacy interleaved WAL); it rides the notice so the skip
      # is reported, never silent, even when a clean newer frame recovered fine.
      #
      # `committed` is the turns this recovery added, root to head: the answer,
      # after the prompt it rebuilt when there was one; empty when nothing was
      # newly committed.
      Recovered = Data.define(:request_digest, :response, :timeline, :newly_committed, :corruption, :committed) do
        def recovered? = true
        def closes_file? = true
        def newly_committed? = newly_committed

        def turn = timeline.head

        def notice
          verb = newly_committed? ? "recovered" : "recovery already landed for"
          base = "#{verb} turn #{turn.digest} (request #{request_digest}) from the response log -- no new spend"
          corruption ? "#{base}; #{corruption}" : base
        end
      end

      # A complete frame that yielded no answer: it reassembled to no content,
      # or could not be reassembled at all. Committing it would land an empty
      # assistant turn and call it recovered, and raising would stop the
      # resume that asked, so nothing is committed and the notice names the
      # frame and the `reason` for a reader to inspect.
      Unreadable = Data.define(:request_digest, :wire, :bytes, :reason, :corruption) do
        def recovered? = false
        def closes_file? = true

        def notice
          base = "request #{request_digest}: the response log held no answer (#{frame}: #{reason}); " \
                 "not recovered -- re-ask if you still need it"
          corruption ? "#{base}; #{corruption}" : base
        end

        private

        def frame
          wire.nil? ? "a complete frame of #{bytes} bytes" : "a complete #{wire} frame of #{bytes} bytes"
        end
      end

      # A frame that never finished -- or never arrived at all (`bytes` is 0
      # when nothing matching the digest reached the WAL before the crash).
      # Surfaced as provenance only; a caller must not commit it.
      Incomplete = Data.define(:request_digest, :bytes, :corruption) do
        def recovered? = false
        def closes_file? = true

        def notice
          base = "request #{request_digest} did not finish before the crash (#{bytes} bytes recovered); " \
                 "not recovered -- re-ask if you still need it"
          corruption ? "#{base}; #{corruption}" : base
        end
      end

      # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck --
      #   the session's own journal records, in file order
      # @param frames [Enumerable] every frame in the session's `.wal`, in
      #   write order. Pass the TOLERANT duck ({Provider::ResponseWal#salvageable_frames}):
      #   a corrupt region elsewhere must surface as a {Provider::ResponseWal::Reader::Corrupt}
      #   marker to be reported, never a raise that aborts recovery of a clean
      #   frame beyond it. Real frames answer #request_digest/#bytes/#complete?/#wire;
      #   a Corrupt marker answers #corrupt?.
      # @param timeline [Lain::Ext::Timeline] the loaded session's current head; a
      #   {Recovered} commits onto this without mutating it (Timeline is
      #   already immutable, stated here for the reader)
      # @param reassembly [#call] rebuilds a frame's {Response} given the
      #   frame and the request's ceiling; {Provider::Reassembly}
      def initialize(entries:, frames:, timeline:, reassembly: Provider::Reassembly)
        @records = entries.filter_map { |entry| Journal.parse(entry) }
        @corruptions, @frames = frames.to_a.partition(&:corrupt?)
        @timeline = timeline
        @reassembly = reassembly
      end

      # @return [Nothing, Recovered, Unreadable, Incomplete]
      def call
        sent = unanswered_request
        return Nothing if sent.nil?

        digest = sent.fetch("digest")
        last = @frames.reverse_each.find { |frame| frame.request_digest == digest }
        last&.complete? ? recover(digest, last, sent) : incomplete(digest, last)
      end

      private

      # nil unless the tolerant reader skipped a mis-slotted region on the way
      # to the frames above; a caller renders it as a notice (never a raise).
      def corruption
        return nil if @corruptions.empty?

        "#{@corruptions.size} corrupt region(s) in the response log were skipped during salvage " \
          "(#{@corruptions.map(&:reason).uniq.join("; ")})"
      end

      # The last `request_sent` with nothing superseding it after it in the
      # file -- an assistant `turn` or a `turn_usage` on record is proof of a
      # normal commit, and a `rewound` on record is proof the user moved the
      # head away on purpose.
      def unanswered_request
        last_sent = relevant_records.reverse_each.find { |record, _i| record["type"].to_s == REQUEST_SENT_TYPE }
        return nil if last_sent.nil?

        record, index = last_sent
        superseded_after?(index) ? nil : record
      end

      def relevant_records
        @records.each_with_index.select { |record, _i| relevant?(record) }
      end

      def relevant?(record)
        RELEVANT_TYPES.include?(record["type"].to_s) &&
          (record["type"].to_s != REQUEST_SENT_TYPE || Telemetry::RequestSent.agent?(record))
      end

      def superseded_after?(index)
        relevant_records.any? { |record, i| i > index && superseding?(record) }
      end

      # A spawned child's payment settles the child's request, never the parent's.
      def superseding?(record)
        type = record["type"].to_s
        return false if type == TURN_USAGE_TYPE && record["spawn"]
        return SUPERSEDING_TYPES.include?(type) unless type == TURN_TYPE

        record["role"].to_s == "assistant" && !recovered_turns.include?(record["digest"])
      end

      def recovered_turns
        @recovered_turns ||= @records.select { |record| record["type"].to_s == SALVAGED_TYPE }
                                     .to_set { |record| record["head_after"] }
      end

      # Any failure inside the reassembly is the frame's, whatever its class --
      # rotted bytes raise from a parser, an encoder or a Hash lookup alike --
      # and a resume must not die on the one frame it was asked to read back.
      def recover(digest, frame, sent)
        response = @reassembly.call(frame, ceiling: sent.dig("payload", "max_tokens"))
      rescue StandardError => e
        unreadable(digest, frame, "it could not be reassembled (#{e.class}: #{e.message.lines.first&.strip})")
      else
        return unreadable(digest, frame, "it reassembled to no content") if response.content.empty?
        return already_recovered(digest, response) if already_committed?(response)

        newly_recovered(digest, response, unwritten_prompts(sent))
      end

      def newly_recovered(digest, response, prompts)
        asked = prompts.inject(@timeline) { |timeline, content| timeline.commit(role: :user, content:) }
        timeline = asked.commit(role: :assistant, content: response.content)
        Recovered.new(request_digest: digest, response:, timeline:, newly_committed: true, corruption:,
                      committed: timeline.to_a.last(prompts.size + 1))
      end

      # Only the tail is the agent's own message: a handoff or a compacted
      # render puts derived user messages ahead of it that no turn ever held.
      # The one turn committed in memory ahead of a prompt is a resume's
      # cancellation of a stranded call.
      def unwritten_prompts(sent)
        messages = Array(sent.dig("payload", "messages"))
        return [] if messages.empty?

        prompt = without_folded_note(prompt_of(messages.last["content"]))
        return [] if on_record?(prompt)

        EventLog::Guards.pending_tool_use?(@timeline.head) ? [cancellation(messages[-2]), prompt] : [prompt]
      end

      # A render may reshape the head's message -- a resend edits it, a dedupe
      # drops a duplicate result, a fold reads like a note -- so content cannot
      # say whether the head holds it. Structure can: the agent commits a user
      # turn ahead of its request, and the only one it does not write first is
      # a prompt, asked over tool results or a cancellation.
      def on_record?(prompt)
        head = @timeline.head
        !head.nil? && head.role == "user" && !(tool_results?(head.content) && prompt.all? { |b| b["type"] == "text" })
      end

      def tool_results?(blocks) = blocks.any? { |block| block["type"] == "tool_result" }

      # The message before the prompt is the cancellation only when it answers
      # the stranded calls; a handoff document there means it was folded away,
      # and it is minted the way the resume minted it.
      def cancellation(message)
        minted = Tool::Cancellation.new(@timeline.head, kind: :unknown).blocks
        sent = message && prompt_of(message["content"])
        answers?(sent, minted) ? sent : minted
      end

      def answers?(sent, minted)
        sent.is_a?(Array) && sent.all? { |block| block["type"] == "tool_result" } &&
          sent.map { |block| block["tool_use_id"] } == minted.map { |block| block["tool_use_id"] }
      end

      # A String content is a hand-built request's; a turn is always blocks, and
      # replay reads it as blocks.
      def prompt_of(content)
        return [{ "type" => "text", "text" => content }] if content.is_a?(String)

        Request.strip_cache_markers(content.reject { |block| Workspace.block?(block) })
      end

      # A note has no marker of its own; adding one would move every cached
      # prompt's bytes, so its exact rendering is what names it. It is appended
      # after the prompt, so a sole block is never one.
      def without_folded_note(blocks)
        blocks.size > 1 && Context::Mailbox.note?(blocks.last) ? blocks[0..-2] : blocks
      end

      # Content, never digest: a re-resume commits the SAME response onto a
      # Timeline that already carries it, so the recovered turn's PARENT (and
      # therefore its digest) differs between the two attempts even though the
      # content is identical -- digest equality would never fire and this whole
      # guard would be dead code.
      #
      # It is also the honest reading of "newer than the last committed assistant
      # turn". A literal timestamp compare was never wired (WAL frames carry no
      # comparable `at` past the Reader) and would be redundant besides: a frame
      # can only match `digest` at all when it was spooled for the EXACT
      # conversation prefix that produced the single latest unanswered
      # request_sent, since the digest hashes that whole prefix. "Newest" falls
      # out of the digest join for free; this content check is what keeps a
      # SECOND pass over the SAME frame from reading as newness too.
      def already_committed?(response)
        head = @timeline.head
        !head.nil? && head.role == "assistant" && head.content == response.content
      end

      def already_recovered(digest, response)
        Recovered.new(request_digest: digest, response:, timeline: @timeline, newly_committed: false, corruption:,
                      committed: [])
      end

      def incomplete(digest, frame)
        Incomplete.new(request_digest: digest, bytes: frame.nil? ? 0 : frame.bytes.bytesize, corruption:)
      end

      def unreadable(digest, frame, reason)
        Unreadable.new(request_digest: digest, wire: frame.wire, bytes: frame.bytes.bytesize, reason:, corruption:)
      end
    end
  end
end
