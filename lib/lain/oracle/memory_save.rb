# frozen_string_literal: true

module Lain
  module Oracle
    # T4 (OR-3), second oracle arm: "worth remembering?" -- plugs into
    # {Middleware::RefuseSecretWrites}'s existing `oracle:` seam via {Gate}.
    #
    # UNLIKE {PruneScoring}, this arm sits ON the live tool-dispatch path:
    # `RefuseSecretWrites#call` is a SYNCHRONOUS gate that must decide BEFORE
    # a `memory_write` proceeds -- once a credential (or anything else) is
    # inside the Memory::Index it is readable by every future `memory_read`,
    # so there is no un-writing it after the fact. That constraint means the
    # live gate may only ever be backed by {.heuristic} (or a {Recorded}
    # replay of one): no model round trip may sit on this hot path. A
    # model-tier arm answering this SAME {.definition} is real and useful,
    # but confined to bench/replay comparison (OR-4) -- never constructed as
    # the live gate.
    module MemorySave
      SCHEMA = Class.new(Tool::Input) do
        field :worth_saving, :boolean, required: true,
                                       description: "whether persisting this memory_write is worth doing"
        field :reason, :string, description: "one-line justification, for the journal"
      end

      # The three fields {Tools::MemoryWrite::Input} declares -- id,
      # description, body -- are exactly the slots this question needs.
      TEMPLATE = <<~ERB
        A tool wants to write this item to durable memory:

        id: <%= render("id") %>
        description: <%= render("description") %>
        body: <%= render("body") %>

        Is this worth remembering -- real content, not a secret, not noise?
      ERB

      # @param tier [Symbol] see {PruneScoring.definition} -- same reasoning.
      # @return [Oracle::Definition]
      def self.definition(tier: :heuristic)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end

      # One alphanumeric character anywhere in the body -- the whole test.
      #
      # `[[:alnum:]]` is UNICODE-AWARE, and that is load-bearing: it is the
      # only reason a Japanese, Cyrillic or Greek body saves. Narrowing it to
      # `/[a-zA-Z0-9]/` would silently refuse every non-Latin write, and no
      # existing spec would have caught it -- hence the non-Latin example in
      # the spec.
      #
      # The rule Onigmo actually implements is exactly `Alphabetic | Nd` --
      # an exhaustive 0..0x10FFFF sweep finds zero codepoints where the two
      # disagree. `Alphabetic` is WIDER than "letters": it carries
      # Other_Alphabetic, so 939 `Mn` and 441 `Mc` combining marks match
      # (`ͣͤͥ` is content), as do 130 `So` circled LETTERS (`Ⓐ`) -- alongside
      # the obvious `L*`, `Nl` (`Ⅰ`) and `Nd` (fullwidth `０`). Contentless,
      # and so declined: emoji, math symbols, CJK punctuation, and circled or
      # superscript DIGITS (`①`, `²` -- `No`, not `Nd`). Do not audit this
      # rule by sampling: `U+0301` is a non-Alphabetic `Mn` that declines,
      # and generalizing from it is how this comment previously claimed the
      # opposite of the truth for the other 1379 marks.
      #
      # This replaces an earlier rule (`\A[A-Za-z0-9+/=_.-]{24,}\z`: any
      # unbroken 24+-char run is not worth saving) that refused git SHAs,
      # UUIDs, tracking numbers and base64 -- precisely the identifiers a
      # later `memory_read` exists to surface. The over-refusal is what
      # blocked wiring this gate into the live guard, and the premise behind
      # it was wrong twice over: an opaque identifier IS content, and the one
      # thing it might have caught by accident -- a credential -- is refused
      # by {Middleware::RefuseSecretWrites::PATTERNS}, which can name the
      # shape it matched. This oracle is not a secret detector and must not
      # be read as one; it answers only "is there anything here to save?".
      CONTENT = /[[:alnum:]]/

      # A CONTENTLESSNESS FLOOR, not a quality judgement -- and deliberately
      # nothing more. It sits on the synchronous live write path, where a
      # false refusal is unrecoverable (the write is withheld and the model
      # has nothing to retry differently), so the only thing it is willing to
      # be sure about is that a body with no {CONTENT} at all has nothing to
      # save. Anything more opinionated reinvents the over-refusal this rule
      # was written to undo. As an OR-4 comparison baseline it is near-useless
      # -- almost nothing can lose to it on recall -- and that is the trade
      # accepted here, not an oversight.
      #
      # @return [Oracle::Heuristic]
      def self.heuristic
        Heuristic.new(definition: definition(tier: :heuristic), predicate: lambda do |inputs|
          worth = CONTENT.match?(inputs.fetch(:body).to_s)
          { "worth_saving" => worth, "reason" => worth ? "readable content" : "contentless body" }
        end)
      end

      # Adapts a memory-save oracle tier to {Middleware::RefuseSecretWrites}'s
      # existing binary `#secret?(input)` seam: the richer `worth_saving` +
      # `reason` answer collapses to the one bit that seam asks for.
      class Gate
        # The one field this oracle judges, and the test for whether an input
        # is its business at all. {Middleware::RefuseSecretWrites::GUARDED_TOOLS}
        # sends BOTH `memory_write` and `improvement_write` through the single
        # `oracle:` seam, and an `improvement_write` input is
        # `{note, kind, evidence_digests}` -- no `body`. Reading that missing
        # key as an empty String would judge every improvement note
        # contentless and refuse it. A missing `body` is not a contentless
        # save; it is a question this oracle was never asked.
        JUDGED_FIELD = "body"

        # @param tier [#ask] a live tier answering this module's {.definition}.
        #   Defaults to {.heuristic} -- the only tier safe to construct here,
        #   since {#secret?} runs synchronously on the live write path (see
        #   the module comment). Pass a {Recorded} replay for deterministic
        #   replay of a journaled run; never a {Model} tier here.
        def initialize(tier: MemorySave.heuristic)
          @tier = tier
        end

        # @param input [Hash] a guarded tool effect's raw input (String-keyed)
        # @return [Boolean] true withholds the write. False covers two
        #   different answers on purpose -- "worth saving" and "not mine to
        #   judge" (see {JUDGED_FIELD}) -- because this seam asks for one bit
        #   and abstaining must never read as a refusal.
        def secret?(input)
          input.key?(JUDGED_FIELD) && !worth_saving?(input)
        end

        private

        def worth_saving?(input)
          @tier.ask(id: input["id"], description: input["description"],
                    body: input.fetch(JUDGED_FIELD)).await.worth_saving
        end
      end
    end
  end
end
