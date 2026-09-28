# frozen_string_literal: true

module Lain
  module Oracle
    # The secret-read arm: "may this parked read of a file holding sensitive
    # regions be released?" -- asked of a LOCAL model, ahead of the human, about a
    # call that is already blocking.
    #
    # UNLIKE {MemorySave}, nothing here sits on the live tool-dispatch path. Its
    # one caller is {Approval::SecretSurface}, a QUEUE surface racing the human
    # for pendings {Approval::Queue} has already parked. A surface that never
    # answers costs nothing, because the fail-closed clock denies whatever nobody
    # decided.
    #
    # == The provider is CONSTRUCTED here, and that is the security property
    #
    # {.tier} builds {Provider::Ollama} directly and takes no seam that could
    # replace it -- not `--provider`, not `--summarizer-provider`, not
    # `--api-base`, not {Oracle::Router}. `CLI::Backend#summarizer_provider` looks
    # like the reusable precedent and is precisely the wrong one: it resolves a
    # USER-SETTABLE knob over `anthropic, ollama, ollama-cloud`, so a copy of it would
    # let `--summarizer-provider anthropic` ship the candidate secret's PATH to a
    # remote model. No api_base is passed either: `Backend#provider` hands
    # `--api-base` straight to the ollama arm, which would redirect the "local"
    # judge at any host a flag names.
    #
    # The accurate word is LOOPBACK, not "no api_base". What makes the round trip
    # un-exfiltratable is that the resolved endpoint is `http://localhost:11434`
    # ({Provider::Ollama::Transport::DEFAULT_API_BASE}) and that Ruby's
    # `URI::Generic#find_proxy` exempts loopback from `http_proxy`/`HTTP_PROXY`,
    # verified live against five proxy variables. An `ollama_api_base` resolving
    # off-loopback would put the question on the wire with the proxy honoured, so
    # the two halves stand or fall together.
    #
    # == What the question may contain
    #
    # The path, the tool, and how MANY regions are outstanding. Never a region's
    # bytes: putting the value in the question would disclose it to the very model
    # the gate exists to withhold it from ({Approval::Queue::Outstanding#preamble}
    # states the same rule one surface over). The judgement is therefore about a
    # PATH, which is what makes a small local model a defensible judge at all.
    #
    # The PATH is disclosed, and that is a real edge: a credential spelled into a
    # FILENAME reaches the judge and the journal in the clear. It is inherent to
    # naming the file at all -- the human prompt and the editor row both print
    # it -- so it is a property of the whole boundary, not of this arm. Read
    # "never a region's bytes" as exactly that and no wider.
    #
    # == Confidence is evidence, not control flow
    #
    # The schema's `confidence` is a local model's SELF-REPORT: a rank, not a
    # probability. It is journaled on every answer so
    # {Approval::SecretSurface::DEFAULT_THRESHOLD} can be set from measurement
    # rather than asserted. Nothing here reads it; the surface owns the threshold,
    # because routing is the surface's job.
    module SecretRead
      # The one spelling of the three words a verdict may be. Named once and
      # read by the field description, the inclusion check and the question
      # template below, rather than repeated at each -- three copies of
      # `%w[approve deny defer]` is the shape that drifts.
      VERDICTS = %w[approve deny defer].freeze

      # "approve, deny, or defer", built once from {VERDICTS} for the same
      # reason: the prose in the description, the validator's message and the
      # template all want the Oxford-comma sentence, not the bare Array.
      VERDICT_SENTENCE = "#{VERDICTS[0..-2].join(", ")}, or #{VERDICTS.last}".freeze

      # `verdict` is the one field that decides anything; `confidence` is what a
      # threshold is applied to; `reason` rides along for the journal.
      SCHEMA = Class.new(Tool::Input) do
        field :verdict, :string, required: true,
                                 description: "#{VERDICT_SENTENCE} -- defer whenever unsure"
        field :confidence, :float, required: true,
                                   description: "0.0 to 1.0: how certain this verdict is"
        field :reason, :string, description: "one-line justification, for the journal"

        # A local model has been measured sending schema-valid nonsense past
        # both fields -- a confidence of 90 where the schema means 0.0 to 1.0,
        # and a verdict outside the three words asked for. Nothing downstream
        # re-checks either: {Approval::SecretSurface#confident?} compares
        # `confidence` straight against a threshold, so an unconstrained 90
        # would outrank every real verdict forever, and an unrecognised
        # `verdict` would merely fall through `#settle`'s two `if`s unnoticed
        # rather than say so.
        #
        # `verdict` is normalized -- stripped, downcased -- ON ASSIGNMENT,
        # before the inclusion check below ever runs. Skipping that would put
        # this validator at odds with the comparison it exists to protect:
        # {Approval::SecretSurface#confident?} already tolerates case and
        # whitespace (`answer.verdict.to_s.strip.downcase == verdict`), so an
        # exact inclusion check would hard-reject "Approve" or "approve\n" as
        # an oracle fault even though the surface would have matched either
        # correctly. Normalizing here, not there, is what makes the STORED
        # answer canonical rather than merely tolerated at one call site.
        def verdict=(value)
          super(value.nil? ? value : value.to_s.strip.downcase)
        end

        validates :verdict, inclusion: { in: VERDICTS, message: "must be #{VERDICT_SENTENCE}" }
        validates :confidence, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 },
                               allow_nil: true
      end

      # Three slots, and the absence of a fourth is the point (see the module
      # header). The instruction leans on DEFER twice, because an ambiguous answer
      # here releases a secret rather than merely wasting a turn.
      #
      # THE LAST LINE IS NOT DECORATION. {Oracle::Model::JsonDecoder} demands a
      # JSON object, and a template that asks only for a verdict gets exactly what
      # it asked for: measured against real ollama on {.tier}'s own
      # `DEFAULT_MODEL`, "Answer approve, deny, or defer" returned the bare word
      # `deny` and raised {Oracle::UndecodableAnswer} 4 times out of 4, at 8-10s
      # each. The model was RIGHT and the arm was dead -- every pending fell to
      # the clock, and since a fault journals no {Telemetry::OracleAnswer} the
      # confidence data the threshold is calibrated from never accrued either. No
      # other template in the repo says "JSON".
      TEMPLATE = <<~ERB
        A tool call is parked at an approval gate. Approving it would release
        <%= render("region_count") %> sensitive region(s) found in one file.

        path: <%= render("path") %>
        tool: <%= render("tool") %>

        You are shown the path and the count, never the file's contents. Judge
        from the path alone. Answer approve only if a file at that path plainly
        holds no real secret -- a dependency lockfile, a checksum manifest,
        vendored third-party source. Answer deny if it plainly does -- a private
        key, a credential store, an environment file. Answer defer if you are
        unsure, and prefer defer: a human is already being asked this question,
        and deferring only leaves it to them.

        Reply with a JSON object and nothing else, in exactly this shape:
        {"verdict": "#{VERDICTS.join("|")}", "confidence": 0.0, "reason": "one line"}
      ERB
                 .freeze

      # @param tier [Symbol] folded into the Definition's digest, so the same
      #   question answered by two tiers is two oracles at two addresses (see
      #   {PruneScoring.definition} for the same reasoning).
      # @return [Oracle::Definition]
      def self.definition(tier: :model)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end

      # The one tier this oracle has, and the only construction of it. Every
      # answer is journaled before it reaches the caller, which is what accrues
      # the calibration data the threshold is set from.
      #
      # The parameter list is deliberately this short, and a spec pins it: a
      # `provider:`, `backend:` or `router:` keyword appearing here is the whole
      # failure this arm exists to prevent, arriving as an innocuous seam. The
      # {Provider::Journaled} wrap that records the question is built HERE, around
      # the bare local provider one line away, and takes no keyword of its own --
      # a decorator cannot move an endpoint it is handed, so the loopback
      # guarantee above is untouched.
      #
      # `options:` is the one addition that list has had, and it is not a seam
      # of that kind: a Hash of sampler values rides the request BODY, and
      # nothing in it can name a host, a provider or a model. It exists because
      # a chat running this judge's own model on the same loopback server
      # shares one runner with it, and a judgement sent without the chat's
      # runner knobs reloads that runner twice. The caller resolves it -- empty
      # in the default configuration, where the chat's model is a different one.
      #
      # @param model [String] which local model answers
      # @param journal [#<<] where the {Telemetry::OracleAnswer} and the round
      #   trip's own {Telemetry::RequestSent} land
      # @param options [Hash{String=>Integer}] sampler options for the judge's
      #   request, String-keyed and already scoped to this model on this endpoint
      # @option options [Integer] num_batch the chat runner's prompt batch size
      # @option options [Integer] num_ctx the chat runner's context length
      # @return [Oracle::Recorded::Journaling]
      def self.tier(model: Provider::Ollama::DEFAULT_MODEL, journal: Channel::Null::INSTANCE, options: {})
        oracle = definition(tier: :model)
        provider = Provider::Journaled.new(provider: Provider::Ollama.new, journal:)
        Recorded::Journaling.new(definition: oracle, journal:,
                                 inner: Model.new(definition: oracle, provider:, model:, extra: options))
      end
    end
  end
end
