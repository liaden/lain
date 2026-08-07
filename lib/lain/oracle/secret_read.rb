# frozen_string_literal: true

module Lain
  module Oracle
    # T17, the secret-read arm: "may this parked read of a file holding
    # sensitive regions be released?" -- asked of a LOCAL model, ahead of the
    # human, about a call that is already blocking.
    #
    # UNLIKE {MemorySave}, whose header forbids a model round trip on the live
    # tool-dispatch path, nothing here sits on that path. Its one caller is
    # {Approval::SecretSurface}, a QUEUE surface: it observes pendings
    # {Approval::Queue} has already parked and races the human for them, exactly
    # as {Approval::AutoSurface} does. A surface that never answers costs
    # nothing and changes nothing, because the fail-closed clock denies whatever
    # nobody decided.
    #
    # == The provider is CONSTRUCTED here, and that is the security property
    #
    # {.tier} builds {Provider::Ollama} directly and takes no seam that could
    # replace it -- not `--provider`, not `--summarizer-provider`, not
    # `--api-base`, and not {Oracle::Router}. `CLI::Backend#summarizer_provider`
    # looks like the reusable precedent and is precisely the wrong one: it
    # resolves a USER-SETTABLE knob over `anthropic, ollama, bedrock`, so a copy
    # of it would let `--summarizer-provider anthropic` ship the candidate
    # secret's PATH to a remote model to be judged -- the disclosure this whole
    # rung exists to prevent. No api_base is passed either, for the same reason
    # one line further on: `Backend#provider` hands `--api-base` straight to the
    # ollama arm, which would redirect the "local" judge at any host a flag
    # names.
    #
    # State the guarantee precisely, because the accurate word is LOOPBACK, not
    # "no api_base": what makes the round trip un-exfiltratable is that the
    # resolved endpoint is `http://localhost:11434`
    # ({Provider::Ollama::Transport::DEFAULT_API_BASE}) and that Ruby's
    # `URI::Generic#find_proxy` exempts loopback from `http_proxy`/`HTTP_PROXY`
    # -- verified live against five proxy variables. An `ollama_api_base` that
    # ever resolved off-loopback would put the question on the wire with the
    # proxy honoured, so the two halves stand or fall together.
    #
    # == What the question may contain
    #
    # The path, the tool, and how MANY regions are outstanding. Never a region's
    # bytes: putting the value in the question would disclose it to the very
    # model the gate exists to withhold it from, which is
    # {Approval::Queue::Outstanding#preamble}'s own rule one surface over. The
    # judgement is therefore a judgement about a PATH, which is what makes a
    # small local model a defensible judge of it at all.
    #
    # The PATH is disclosed, though, and that is a real edge rather than a
    # rounding error: a credential spelled into a FILENAME reaches the judge and
    # the journal in the clear. It is inherent to naming the file at all -- the
    # human prompt, the editor row and the desktop notification all print it
    # too, via `Outstanding#preamble` -- so it is a property of the whole
    # boundary, not of this arm. Read "never a region's bytes" as exactly that
    # and no wider.
    #
    # == Confidence is evidence, not control flow
    #
    # The schema's `confidence` is a local model's SELF-REPORT: a rank, not a
    # probability. It is journaled on every answer ({Recorded::Journaling} wraps
    # the tier, so verdict, confidence, model and wall clock all land as a
    # {Telemetry::OracleAnswer}) so that
    # {Approval::SecretSurface::DEFAULT_THRESHOLD} can be set from measurement
    # rather than asserted. Nothing here reads it; the surface owns the
    # threshold, because routing is the surface's job.
    module SecretRead
      # `verdict` is the one field that decides anything; `confidence` is what a
      # threshold is applied to; `reason` rides along for the journal, like
      # {PruneScoring::SCHEMA}'s own.
      SCHEMA = Class.new(Tool::Input) do
        field :verdict, :string, required: true,
                                 description: "approve, deny, or defer -- defer whenever unsure"
        field :confidence, :float, required: true,
                                   description: "0.0 to 1.0: how certain this verdict is"
        field :reason, :string, description: "one-line justification, for the journal"
      end

      # Three slots, and the absence of a fourth is the point (see the module
      # header). The instruction leans on DEFER twice, because an ambiguous
      # answer here releases a secret rather than merely wasting a turn.
      #
      # THE LAST LINE IS NOT DECORATION. {Oracle::Model::JsonDecoder} demands a
      # JSON object, and a template that asks only for a verdict gets exactly
      # what it asked for: measured against real ollama on {.tier}'s own
      # `DEFAULT_MODEL`, "Answer approve, deny, or defer" returned the bare word
      # `deny` and raised {Oracle::UndecodableAnswer} 4 times out of 4, at 8-10s
      # each. The model was RIGHT and the arm was dead -- every pending fell to
      # the clock, and because a fault journals no {Telemetry::OracleAnswer},
      # the confidence data {SecretSurface::DEFAULT_THRESHOLD} is supposed to be
      # calibrated from never accrued either. No other template in the repo says
      # "JSON"; that no other arm has noticed is a fact about the other arms.
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
        {"verdict": "approve|deny|defer", "confidence": 0.0, "reason": "one line"}
      ERB

      # @param tier [Symbol] folded into the Definition's digest, so the same
      #   question answered by two tiers is two oracles at two addresses (see
      #   {PruneScoring.definition} for the same reasoning).
      # @return [Oracle::Definition]
      def self.definition(tier: :model)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end

      # The one tier this oracle has, and the only construction of it. Every
      # answer is journaled ({Recorded::Journaling}) before it reaches the
      # caller, which is what accrues the calibration data the threshold is set
      # from.
      #
      # The parameter list is deliberately this short, and a spec pins it: a
      # `provider:`, `backend:` or `router:` keyword appearing here is the whole
      # failure this arm exists to prevent, arriving as an innocuous seam.
      #
      # @param model [String] which local model answers
      # @param journal [#<<] where the {Telemetry::OracleAnswer} lands
      # @return [Oracle::Recorded::Journaling]
      def self.tier(model: Provider::Ollama::DEFAULT_MODEL, journal: Channel::Null::INSTANCE)
        oracle = definition(tier: :model)
        Recorded::Journaling.new(definition: oracle, journal:,
                                 inner: Model.new(definition: oracle, provider: Provider::Ollama.new, model:))
      end
    end
  end
end
