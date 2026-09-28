# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `excerpt` is guarded on PRESENCE and not merely on nil, because the
      # empty String is what a detector that matched nothing hands over -- a
      # record claiming a finding with no evidence behind it. It reports a model
      # failure to a human who will not have the turn in front of them, so the
      # quote is the whole of what makes it checkable.
      #
      # Both quote guards are scoped to the kind that HAS something to quote.
      # An empty answer's finding is the absence itself: no tool was named and
      # no text was written, so demanding either would make the record
      # unconstructible for the very failure it exists to name.
      #
      # `model` is NOT required in their place, though it is the only evidence
      # an empty answer has, and the reason is production rather than tidiness.
      # A 200 that omits `model` is within what the wire may send -- the
      # compat servers this endpoint gets pointed at are not ollama -- and this
      # record is constructed from inside the decode of that 200. The raise
      # would be an `ArgumentError`, which `ErrorWrapping::Wrapping#wrapping_errors`
      # does not catch (it takes `Provider::HTTP::Error` and `Faraday::Error`),
      # so it escapes `#complete` uncaught from inside the held admission slot.
      # The report of a model failure would become a strictly worse model
      # failure than the one it reports, which is this record's thesis
      # inverted. (Corroborating, not the argument: every stand-in body the
      # suite hands a transport is `{}`, which is that shape already.)
      #
      # What is relied on instead is a PRODUCER OBLIGATION held by example:
      # `Ollama::Decoding#note_empty_answer` passes `body["model"]`
      # unconditionally, and `ollama_spec.rb` pins it on the real journal line.
      # So the evidence is a promise the producer keeps and a spec enforces,
      # not an invariant of the type.
      #
      # The shape that leaves is worth saying plainly: `kind` is the only
      # invariant on the whole Data, deliberately, and an `empty_answer` may
      # today carry a nonsense `tool_name` or `excerpt`.
      class MalformedResponse < Declarative::Carrier
        attribute :kind
        attribute :tool_name
        attribute :excerpt
        validates :kind, inclusion: { in: %i[prose_tool_call empty_answer],
                                      message: "must be one of prose_tool_call, empty_answer, got %<value>s" }
        validates :tool_name, presence: { message: "must name the tool the envelope named, got nil" }, if: :quoting?
        validates :excerpt, presence: { message: "must carry the text the reading was made from, got nil" },
                            if: :quoting?

        private

        def quoting? = kind == :prose_tool_call
      end
    end

    # One response the wire called an ordinary end of turn and that carried no
    # usable answer. Two kinds so far, and they are the same shape seen twice:
    #
    #   * `:prose_tool_call` -- `qwen3-coder:30b` emits
    #     `<function=NAME>...</function>` as assistant TEXT on roughly half of
    #     first turns, with no `tool_calls` beside it;
    #   * `:empty_answer` -- HTTP 200 with every field a turn could speak
    #     through left blank, which is what a local model spending its whole
    #     budget on thinking returns.
    #
    # The provider that notices writes this record AND reads the turn's stop
    # reason as `:malformed`, so the loop fails it by name instead of settling
    # it as an answer. The two travel together because they serve different
    # readers: the stop reason routes the turn, and this record is the evidence
    # a human checks the finding against. A turn that decoded normally emits
    # neither.
    #
    # One exception, and it is the reason the record and the stop reason are
    # separate fields at all: a reply that is empty because the model hit its
    # own token ceiling keeps the wire's `:max_tokens`, because a spent ceiling
    # and a model that chose to stop want different answers from a caller. The
    # record is still written, so the silence is on the file either way.
    #
    # This is the one consumer point a further producer plugs into -- a new
    # `kind` here, the same stop reason there.
    #
    # == It reports; it does not repair
    #
    # Nothing here is a reconstructed call, and nothing downstream may treat it
    # as one: salvaging the envelope would execute a call the model never
    # properly expressed, and the approval gate is no help when the parse itself
    # is what is wrong. So `tool_name` and `excerpt` are what the detector SAW,
    # never what it inferred the model meant -- and both are absent on the kind
    # whose finding is that there was nothing to see.
    #
    # `kind` is an open place rather than a decoration -- "the wire handed us
    # the wrong shape" has more than one form. `model` is nil-tolerant because
    # a replayed or hand-assembled body may omit it.
    #
    # == No request_digest, unlike its siblings
    #
    # Deliberate, and not an omission to "fix": the detector runs in the
    # provider's decode, which is handed the response body and never the
    # Request, and reaching for one there would put this decision above the
    # provider that owns its model family's failure modes.
    MalformedResponse = Data.define(:kind, :model, :tool_name, :excerpt) do
      include Journalable

      def initialize(kind:, tool_name: nil, excerpt: nil, model: nil)
        # Coerced BEFORE the guard, {ProviderWait}'s own spelling, and for a
        # reason that outlives the tidiness: `%<value>s` renders a Symbol and a
        # String identically, so a String `kind` used to be refused with
        # `got prose_tool_call` -- naming the rejected value as the wanted one.
        # `&.`, where the sibling writes a bare `.to_sym`, so a nil still
        # reaches the guard and is refused BY NAME rather than dying in a
        # NoMethodError one frame lower.
        kind = kind&.to_sym
        Carriers::MalformedResponse.check!(kind:, tool_name:, excerpt:)

        super(kind:, model: model&.dup&.freeze, tool_name: tool_name&.dup&.freeze,
              # Qualified, not bare: a `def` inside a `Data.define` block keeps
              # the ENCLOSING module's cref, so an unqualified constant would be
              # looked up in Telemetry and raise NameError.
              excerpt: excerpt&.slice(0, MalformedResponse::EXCERPT_LIMIT)&.freeze)
      end
    end

    class MalformedResponse
      # How many CHARACTERS of the envelope the record quotes. A malformed turn
      # is the one turn whose text may be arbitrarily large -- one corpus
      # envelope held a whole Rust source file at 2,787 characters -- and this
      # is a witness, not a copy: the Journal is NDJSON a human greps. The HEAD
      # is kept because the opening envelope is what names the tool.
      #
      # CHARACTERS AND NOT BYTES, deliberately: `String#[]` slices by codepoint,
      # so the quote can never be cut mid-character and the record can never
      # journal invalid UTF-8. The cost is that the bound is on length rather
      # than line width -- 240 characters can reach ~960 bytes.
      #
      # The reopen is where it can live at all -- a constant assigned inside the
      # `Data.define` block above would land in {Telemetry}, not on this class.
      EXCERPT_LIMIT = 240
    end
  end
end
