# frozen_string_literal: true

module Lain
  module Oracle
    # The second oracle arm: "worth remembering?" -- plugs into
    # {Middleware::RefuseSecretWrites}'s `oracle:` seam via {Gate}.
    #
    # UNLIKE {PruneScoring}, this arm sits ON the live tool-dispatch path:
    # `RefuseSecretWrites#call` is a SYNCHRONOUS gate that must decide BEFORE a
    # `memory_write` proceeds, because once content is inside the Memory::Index
    # every future `memory_read` can see it. So the live gate may only ever be
    # backed by {.heuristic} or a {Recorded} replay of one -- no model round trip
    # may sit on this hot path. A model tier answering this SAME {.definition} is
    # useful, but confined to bench/replay comparison.
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
      # `[[:alnum:]]` is UNICODE-AWARE, and that is load-bearing: it is the only
      # reason a Japanese, Cyrillic or Greek body saves. Narrowing it to
      # `/[a-zA-Z0-9]/` would silently refuse every non-Latin write.
      #
      # The rule Onigmo implements is exactly `Alphabetic | Nd` -- an exhaustive
      # 0..0x10FFFF sweep finds zero codepoints where the two disagree.
      # `Alphabetic` is WIDER than "letters": it carries Other_Alphabetic, so 939
      # `Mn` and 441 `Mc` combining marks match, as do 130 `So` circled LETTERS
      # (`Ⓐ`), alongside the obvious `L*`, `Nl` and `Nd`. Declined as contentless:
      # emoji, math symbols, CJK punctuation, and circled or superscript DIGITS
      # (`①`, `²` -- `No`, not `Nd`). Do not audit this rule by sampling:
      # `U+0301` is a non-Alphabetic `Mn` that declines, and generalizing from it
      # is how this comment once claimed the opposite of the truth for the other
      # 1379 marks.
      #
      # It replaces a rule (`\A[A-Za-z0-9+/=_.-]{24,}\z`) that refused git SHAs,
      # UUIDs, tracking numbers and base64 -- precisely the identifiers a later
      # `memory_read` exists to surface. That over-refusal is what blocked wiring
      # this gate into the live guard. This oracle is not a secret detector and
      # must not be read as one: a credential is refused by
      # {Middleware::RefuseSecretWrites::PATTERNS}, which can name the shape it
      # matched.
      CONTENT = /[[:alnum:]]/

      # A CONTENTLESSNESS FLOOR, not a quality judgement. It sits on the
      # synchronous live write path where a false refusal is unrecoverable, so the
      # only thing it is willing to be sure about is that a body with no {CONTENT}
      # at all has nothing to save; anything more opinionated reinvents the
      # over-refusal this rule was written to undo. As a comparison baseline it is
      # near-useless -- almost nothing can lose to it on recall -- and that is the
      # trade accepted, not an oversight.
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
        # The one field this oracle judges, and the test for whether an input is
        # its business at all. {Middleware::RefuseSecretWrites::GUARDED_TOOLS}
        # sends BOTH `memory_write` and `improvement_write` through the single
        # `oracle:` seam, and an `improvement_write` input carries no `body`.
        # Reading that missing key as an empty String would judge every
        # improvement note contentless and refuse it: a missing `body` is not a
        # contentless save, it is a question this oracle was never asked.
        JUDGED_FIELD = "body"

        # @param tier [#ask] a live tier answering this module's {.definition}.
        #   Defaults to {.heuristic}, the only tier safe to construct here since
        #   {#secret?} runs synchronously on the live write path. Pass a
        #   {Recorded} for deterministic replay; never a {Model} tier.
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
