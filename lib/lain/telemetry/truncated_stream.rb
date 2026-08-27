# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The counts are guarded by numericality rather than by `presence:`,
      # which would reject the zero a stream severed before its first line
      # legitimately reports -- and that stream is the one most worth recording.
      # A nil still fails, because a record whose figures are absent claims a
      # truncation nobody can check.
      #
      # `request_digest` is the one field guarded by presence, because a record
      # nothing can be joined to is not a diagnosis: one Provider serves a whole
      # session's round trips, so several interleave on one channel and NDJSON
      # adjacency cannot name which stream died.
      class TruncatedStream < Declarative::Carrier
        attribute :kind
        attribute :request_digest
        attribute :frames
        attribute :accumulated_bytes
        attribute :tool_calls
        validates :kind, inclusion: { in: %i[unterminated counts_absent],
                                      message: "must be one of unterminated, counts_absent, got %<value>s" }
        validates :request_digest,
                  presence: { message: "must name the round trip this stream answered, got nil" }
        validates :frames,
                  numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                  message: "must be the number of NDJSON frames ingested, got %<value>s" }
        validates :accumulated_bytes,
                  numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                  message: "must be the message bytes accumulated, got %<value>s" }
        validates :tool_calls,
                  numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                  message: "must be the number of tool calls the stream delivered, got %<value>s" }
      end
    end

    # One streamed turn that never said it was finished.
    #
    # Ollama's NDJSON `/api/chat` stream puts `done: true`, `done_reason` and the
    # token counts on its LAST line, and nothing earlier says how many lines to
    # expect. {Provider::Ollama::StreamAssembler#build_body} has to write
    # `"done" => true` regardless, because the non-streaming body it reassembles
    # into always carries one -- so a connection that died mid-answer is
    # shape-identical to a complete turn, decoding to a `:unknown` stop reason
    # and all-zero usage with the prose intact. Every reader above the provider
    # sees a turn that merely stopped oddly.
    #
    # The presence of this record is the whole signal: a stream that terminated
    # with its counts emits nothing, so a healthy session journals none of these
    # and one line in the Journal is the occurrence, already diagnosable.
    #
    # == It reports; it does not repair
    #
    # Nothing here changes what the caller is handed. The failure this was built
    # from was a CONTENT-BEARING turn, and refusing the body -- or rewriting
    # `done` to false and letting the decode collapse -- would trade a silent
    # accounting bug for a lost answer, which is the worse defect. Hardening the
    # readers is separate work; this is the producer saying what happened.
    #
    # `kind` is a closed enum with two readings a human acts on differently:
    #
    # - `:unterminated` -- no terminal frame ever arrived, so the prose is a
    #   fragment and the stop reason is fiction.
    # - `:counts_absent` -- a terminal frame DID arrive, so the prose is whole,
    #   but it carried no `prompt_eval_count`/`eval_count` and the turn will
    #   therefore report as free.
    #
    # == What makes an occurrence checkable
    #
    # `request_digest` is the join key onto the {RequestSent} this stream was
    # answering, the same field and the same purpose {Salvaged} carries. It is
    # required rather than nice-to-have: a Provider is constructed once and
    # reused -- the chat tier and the summarizer tier share one for a whole
    # session -- so more than one round trip is in flight through the same tap
    # and their records interleave. Without the key, `model` and NDJSON
    # adjacency are all a reader has, and neither says WHICH of forty turns
    # died.
    #
    # `frames` is how many NDJSON objects arrived, `accumulated_bytes` how many
    # BYTES of message text (content plus thinking) they added up to -- bytes
    # rather than characters, because the figure is about how far the stream got
    # on the wire. Together they separate "died on the first line" from "died
    # 2.8KB into an answer", which are different diagnoses.
    #
    # `tool_calls` is counted SEPARATELY rather than folded into the bytes, and
    # it is the most dangerous shape this record describes: a tool-call frame
    # carries no message text, so a stream severed with three calls in flight
    # would otherwise journal `accumulated_bytes: 0` and read exactly like three
    # empty keepalives -- while the caller may be holding a half-formed call.
    # The actionable fact is HOW MANY calls arrived, not how much serialized
    # JSON they came to, so a count is the honest shape and folding the bytes in
    # would make one field mean two things.
    #
    # Scoped to the attempt actually RETURNED: `#reset` zeroes every counter on
    # every discard, so a severed attempt that faraday-retry cleanly replaced
    # leaves nothing behind to record. `model` is nil-tolerant, because a stream
    # that died before its first line never named one.
    TruncatedStream = Data.define(:kind, :model, :request_digest, :frames, :accumulated_bytes, :tool_calls) do
      include Journalable

      def initialize(kind:, request_digest:, frames:, accumulated_bytes:, tool_calls:, model: nil)
        # Coerced BEFORE the guard, {MalformedResponse}'s spelling and its
        # reason: `%<value>s` renders a Symbol and a String identically, so an
        # uncoerced String `kind` would be refused with a message naming the
        # rejected value as the wanted one. `&.`, so a nil reaches the guard and
        # is refused BY NAME rather than dying one frame lower.
        kind = kind&.to_sym
        Carriers::TruncatedStream.check!(kind:, request_digest:, frames:, accumulated_bytes:, tool_calls:)

        super(kind:, model: model&.dup&.freeze, request_digest: request_digest.dup.freeze,
              frames: frames.to_i, accumulated_bytes: accumulated_bytes.to_i, tool_calls: tool_calls.to_i)
      end
    end
  end
end
