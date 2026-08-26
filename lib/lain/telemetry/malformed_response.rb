# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A malformed-response record must name the reading it made, the tool the
      # envelope named, and the text it read that from.
      #
      # `excerpt` is guarded on PRESENCE and not merely on nil, because the
      # empty String is the shape a detector that matched nothing would hand
      # over -- a record claiming a finding with no evidence behind it, which is
      # the one misreading this record cannot survive. It reports a model
      # failure to a human who will not have the turn in front of them, so the
      # quote is the whole of what makes it checkable.
      class MalformedResponse < Declarative::Carrier
        attribute :kind
        attribute :tool_name
        attribute :excerpt
        validates :kind, inclusion: { in: %i[prose_tool_call],
                                      message: "must be one of prose_tool_call, got %<value>s" }
        validates :tool_name, presence: { message: "must name the tool the envelope named, got nil" }
        validates :excerpt, presence: { message: "must carry the text the reading was made from, got nil" }
      end
    end

    # One response whose tool call arrived as assistant TEXT rather than as a
    # tool call (MODEL-2). `qwen3-coder:30b` emits `<function=NAME>...</function>`
    # as prose on roughly half of first turns, and a message with no `tool_calls`
    # decodes to `:end_turn` -- so the turn lands on the HEALTHY arm of
    # {Agent::LoopMachine}, nothing is journaled, and the ask is a silent
    # write-off. The presence of this record is the whole signal; a turn that
    # decoded normally emits nothing, the same way {ProviderWait} says nothing
    # about a caller admitted on its first attempt.
    #
    # == It reports; it does not repair
    #
    # Nothing here is a reconstructed call, and nothing downstream may treat it
    # as one. Salvaging the envelope would execute a call the model never
    # properly expressed, and the tier-3 approval gate is no help when the parse
    # itself is what is wrong. So the fields are evidence a reader can check by
    # hand against the turn -- `tool_name` and `excerpt` are what the detector
    # SAW, never what it inferred the model meant.
    #
    # `kind` is the reading, and it is an open place rather than a decoration:
    # "the wire handed us the wrong shape" has more than one form, and a second
    # one belongs here beside the first rather than in a second record type a
    # reader has to know to grep for. `model` is nil-tolerant because it is the
    # one field the wire may genuinely omit -- `/api/chat` carries it on every
    # real response, but a replayed or hand-assembled body need not, and an
    # absence there is not a defect to raise on.
    MalformedResponse = Data.define(:kind, :model, :tool_name, :excerpt) do
      include Journalable

      def initialize(kind:, tool_name:, excerpt:, model: nil)
        # Coerced BEFORE the guard, {ProviderWait}'s own spelling, and for a
        # reason that outlives the tidiness: `%<value>s` renders a Symbol and a
        # String identically, so a String `kind` used to be refused with
        # `got prose_tool_call` -- naming the rejected value as the wanted one.
        # `&.`, where the sibling writes a bare `.to_sym`, so a nil still
        # reaches the guard and is refused BY NAME rather than dying in a
        # NoMethodError one frame lower.
        kind = kind&.to_sym
        Carriers::MalformedResponse.check!(kind:, tool_name:, excerpt:)

        super(kind:, model: model&.dup&.freeze, tool_name: tool_name.dup.freeze,
              # Qualified, not bare: a `def` inside a `Data.define` block keeps
              # the ENCLOSING module's cref, so an unqualified constant would be
              # looked up in Telemetry and raise NameError.
              excerpt: excerpt[0, MalformedResponse::EXCERPT_LIMIT].freeze)
      end
    end

    class MalformedResponse
      # How many CHARACTERS of the envelope the record quotes. A malformed turn
      # is the one turn whose text may be arbitrarily large -- the QA corpus
      # carries a 2,787-character envelope holding a whole Rust source file --
      # and this record is a witness, not a copy: the Journal is NDJSON a human
      # greps, so one line per finding has to stay scannable. The HEAD is kept
      # rather than the tail because the opening envelope is what names the
      # tool, which is the part a reader checks first.
      #
      # CHARACTERS AND NOT BYTES, deliberately: `String#[]` slices by codepoint,
      # so the quote can never be cut mid-character and the record can never
      # journal invalid UTF-8. The cost is that the bound is on length and not
      # on line width -- a multibyte envelope reaches 240 characters at up to
      # ~960 bytes -- which is the right trade for a field whose job is to stay
      # READABLE, and the wrong one to describe in bytes.
      #
      # The reopen is where it can live at all -- a constant assigned inside the
      # `Data.define` block above would land in {Telemetry}, not on this class.
      EXCERPT_LIMIT = 240
    end
  end
end
