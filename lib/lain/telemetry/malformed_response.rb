# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `excerpt` is guarded on PRESENCE and not merely on nil, because the
      # empty String is what a detector that matched nothing hands over -- a
      # record claiming a finding with no evidence behind it. It reports a model
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
    # tool call. `qwen3-coder:30b` emits `<function=NAME>...</function>` as prose
    # on roughly half of first turns, and the wire calls that an ordinary end of
    # turn. The provider that notices writes this record AND reads the turn's
    # stop reason as `:malformed`, so the loop fails it by name instead of
    # settling it as an answer. The two travel together because they serve
    # different readers: the stop reason routes the turn, and this record is
    # the evidence a human checks the finding against. A turn that decoded
    # normally emits neither.
    #
    # This is the one consumer point a second producer plugs into -- a new
    # `kind` here, the same stop reason there.
    #
    # == It reports; it does not repair
    #
    # Nothing here is a reconstructed call, and nothing downstream may treat it
    # as one: salvaging the envelope would execute a call the model never
    # properly expressed, and the approval gate is no help when the parse itself
    # is what is wrong. So `tool_name` and `excerpt` are what the detector SAW,
    # never what it inferred the model meant.
    #
    # `kind` is an open place rather than a decoration -- "the wire handed us
    # the wrong shape" has more than one form, and a second belongs here rather
    # than in a record type a reader has to know to grep for. `model` is
    # nil-tolerant because a replayed or hand-assembled body may omit it.
    #
    # == No request_digest, unlike its siblings
    #
    # Deliberate, and not an omission to "fix": the detector runs in the
    # provider's decode, which is handed the response body and never the
    # Request, and reaching for one there would put this decision above the
    # provider that owns its model family's failure modes.
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
