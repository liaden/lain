# frozen_string_literal: true

require "json"
require "event_stream_parser"

module Lain
  module SessionRecord
    # Recovers a paid-for-but-uncommitted response from the response WAL when a
    # session resumes open (T18). {Middleware::JournalRequests} journals a
    # `request_sent` BEFORE the round trip dispatches (see that class's doc
    # comment), and {Agent#commit_and_account} commits the Timeline turn and
    # journals its `turn_usage` as ONE atom, deferred against a stop -- so a
    # process that dies between the two has already spent real tokens the
    # session record alone cannot show, and only the {Provider::ResponseWal}
    # might still hold the bytes.
    #
    # == Finding the target
    #
    # The candidate is the session's LAST `request_sent` record, but only when
    # no `turn_usage` follows it anywhere in the file: a `turn_usage` present
    # is proof the round trip already committed normally (the atom above), so
    # there is nothing to salvage -- {Nothing}, a clean no-op.
    #
    # == Frame selection, per the retry ruling
    #
    # A request can retry at the transport level, and {Provider::ResponseWal}
    # rotates a fresh frame per attempt, so several frames can share one
    # request digest -- only the LAST one is real; earlier ones are aborted
    # attempts, inert history. The last COMPLETE frame for the target digest
    # wins; when none is complete, the most recent matching frame (however
    # torn, or absent entirely) is surfaced as a reviewable {Incomplete}
    # artifact rather than guessed into a commit.
    #
    # == Reassembly reuses the accumulator, not the transport
    #
    # A complete frame holds the EXACT bytes {Provider::AnthropicRaw::Transport}
    # teed off the wire -- raw SSE lines, verbatim (see {Provider::ResponseWal}'s
    # header comment). `EventStreamParser::Parser` is the very parser class the
    # live streaming path drives (`Provider::HTTP::Streaming`); it is pure text
    # -- no socket, no Faraday -- so feeding it one recorded blob in a single
    # `#feed` call is indistinguishable to it from many small chunks off a
    # wire. The events it yields go straight into
    # {Provider::AnthropicRaw::StreamAssembler}, the SAME block-preserving
    # accumulator a live call uses, so a recovered {Response} is exactly what
    # the original call would have produced -- not a second, parallel parser.
    #
    # A frame the Reader marks complete cannot hold an in-band SSE error
    # event: {Provider::HTTP::Streaming::ErrorHandling} raises on one, which
    # unwinds {Provider::AnthropicRaw::Transport#stream} before it ever reaches
    # `frame.close(complete: true)`. So a complete frame is trusted to be a
    # clean, fully-terminated stream, with no error-event branch to reproduce
    # here.
    #
    # == What this class does not do
    #
    # It never touches a file and never opens a socket: {#call} is a pure
    # function of the three ducks it is handed (`entries`, `frames`,
    # `timeline`), and a {Recovered} commits onto the Timeline it was GIVEN,
    # handing the caller a NEW one. Writing that back to disk -- and deciding
    # how the session record reads afterward -- is {CLI::Resume}'s job, the
    # same separation it already keeps from {Bench::Session::Loader}.
    class Salvage
      REQUEST_SENT_TYPE = "request_sent"
      TURN_USAGE_TYPE = "turn_usage"
      RELEVANT_TYPES = [REQUEST_SENT_TYPE, TURN_USAGE_TYPE].freeze

      # Nothing needed recovering. A Null Object (CLAUDE.md's `Sink::Null`
      # idiom) so a caller never has to branch on "did anything happen"
      # before asking for a notice.
      Nothing = Data.define do
        def notice = nil
        def recovered? = false
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
      Recovered = Data.define(:request_digest, :response, :timeline, :newly_committed, :corruption) do
        def recovered? = true
        def newly_committed? = newly_committed

        def turn = timeline.head

        def notice
          verb = newly_committed? ? "recovered" : "recovery already landed for"
          base = "#{verb} turn #{turn.digest} (request #{request_digest}) from the response log -- no new spend"
          corruption ? "#{base}; #{corruption}" : base
        end
      end

      # A frame that never finished -- or never arrived at all (`bytes` is 0
      # when nothing matching the digest reached the WAL before the crash).
      # Surfaced as provenance only; a caller must not commit it.
      Incomplete = Data.define(:request_digest, :bytes, :corruption) do
        def recovered? = false

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
      #   frame beyond it. Real frames answer #request_digest/#bytes/#complete?;
      #   a Corrupt marker answers #corrupt?.
      # @param timeline [Lain::Timeline] the loaded session's current head; a
      #   {Recovered} commits onto this without mutating it (Timeline is
      #   already immutable, stated here for the reader)
      def initialize(entries:, frames:, timeline:)
        @records = entries.filter_map { |entry| Journal.parse(entry) }
        @corruptions, @frames = frames.to_a.partition(&:corrupt?)
        @timeline = timeline
      end

      # @return [Nothing, Recovered, Incomplete]
      def call
        digest = unanswered_request_digest
        return Nothing if digest.nil?

        matching = @frames.select { |frame| frame.request_digest == digest }
        complete = matching.select(&:complete?).last
        complete ? recover(digest, complete) : incomplete(digest, matching.last)
      end

      private

      # nil unless the tolerant reader skipped a mis-slotted region on the way
      # to the frames above; a caller renders it as a notice (never a raise).
      def corruption
        return nil if @corruptions.empty?

        "#{@corruptions.size} corrupt region(s) in the response log were skipped during salvage"
      end

      # The last `request_sent` with no `turn_usage` anywhere after it in the
      # file -- {Agent#commit_and_account}'s atomic commit-then-journal means a
      # `turn_usage` on record is proof of a normal commit, full stop.
      def unanswered_request_digest
        last_sent = relevant_records.reverse_each.find { |record, _i| record["type"].to_s == REQUEST_SENT_TYPE }
        return nil if last_sent.nil?

        record, index = last_sent
        answered_after?(index) ? nil : record.fetch("digest")
      end

      def relevant_records
        @records.each_with_index.select { |record, _i| RELEVANT_TYPES.include?(record["type"].to_s) }
      end

      def answered_after?(index)
        relevant_records.any? { |record, i| i > index && record["type"].to_s == TURN_USAGE_TYPE }
      end

      def recover(digest, frame)
        response = reassemble(frame)
        return already_recovered(digest, response) if already_committed?(response)

        timeline = @timeline.commit(role: :assistant, content: response.content)
        Recovered.new(request_digest: digest, response:, timeline:, newly_committed: true, corruption:)
      end

      # Content, never digest: a re-resume commits the SAME response onto a
      # Timeline that already carries it, so the recovered turn's PARENT (and
      # therefore its digest) differs between the two attempts even though
      # the content is identical -- digest equality would never fire and this
      # whole guard would be dead code.
      #
      # This is also this class's honest reading of the card's stated
      # "newer than the last committed assistant turn" criterion. A literal
      # timestamp compare was never wired -- WAL frames carry no comparable
      # `at` past the Reader (see {Provider::ResponseWal::Entry}) -- and it
      # would be redundant besides: a frame can only match `digest` at all
      # when it was spooled for the EXACT conversation prefix that produced
      # the (single, latest) unanswered request_sent, since the digest hashes
      # that whole prefix. "Newest" falls out of the digest join for free on
      # the first pass; this content check is what keeps a SECOND pass, over
      # the SAME already-applied frame, from reading as newness too.
      def already_committed?(response)
        head = @timeline.head
        !head.nil? && head.role == "assistant" && head.content == response.content
      end

      def already_recovered(digest, response)
        Recovered.new(request_digest: digest, response:, timeline: @timeline, newly_committed: false, corruption:)
      end

      def incomplete(digest, frame)
        Incomplete.new(request_digest: digest, bytes: frame.nil? ? 0 : frame.bytes.bytesize, corruption:)
      end

      # A fresh {Provider::AnthropicRaw::StreamAssembler} for exactly one
      # frame -- the same lifetime a live round trip gives it. Referenced
      # lazily, inside a method body rather than at load time: `session_record.rb`
      # loads before `provider.rb` in `lain.rb`'s topological order, the same
      # lazy cross-unit reach {Replay#memory} already documents for
      # `Bench::Session::MemoryReplay`.
      def reassemble(frame)
        assembler = Provider::AnthropicRaw::StreamAssembler.new
        sse_events(frame.bytes).each { |event| assembler.add(event) }
        build_response(assembler.result)
      end

      # `EventStreamParser::Parser` is pure text -- no socket, no Faraday --
      # so feeding it the WHOLE recorded blob in one #feed call is exactly as
      # sound as many small chunks; it line-buffers internally either way. A
      # `[DONE]` sentinel or an `error` event never reaches a COMPLETE frame
      # (see the class comment), but both are filtered defensively rather than
      # trusted blind. Entry#bytes is ASCII-8BIT (binread); force_encoding
      # here is what makes JSON.parse (and the SSE line scan itself) safe on
      # multibyte content.
      def sse_events(bytes)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        collected = []
        EventStreamParser::Parser.new.feed(text) { |type, data| collected << [type.to_s, data] }
        collected.reject { |type, data| type == "error" || data == "[DONE]" }
                 .map { |_type, data| JSON.parse(data) }
      end

      def build_response(assembled)
        Response.new(id: assembled.id, model: assembled.model, content: assembled.content,
                     stop_reason: assembled.stop_reason, usage: build_usage(assembled.usage), raw: assembled)
      end

      def build_usage(usage)
        Usage.new(input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"],
                  cache_creation_input_tokens: usage["cache_creation_input_tokens"],
                  cache_read_input_tokens: usage["cache_read_input_tokens"])
      end
    end
  end
end
